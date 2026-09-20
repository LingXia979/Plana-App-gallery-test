import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show compute;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'codex_models.dart';
import 'codex_tag_zh.dart';

/// 法典数据源接入:官网 CDN 取 index / media / 每部 JSON,以及原站的 tag 中文对照。
/// 每部 JSON 大(最大 ~11MB),按 `id@版本` 落盘缓存(版本不变即命中不重拉),
/// 解析放 isolate(compute),主线程不卡。图片不缓存(交给 Flutter 图缓存 + CDN 强缓存)。
class CodexService {
  CodexService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;
  Directory? _cacheDir;
  bool _cacheResolved = false;

  /// 官网(数据 JSON 的规范来源,Cloudflare CDN;非 GitHub raw)。
  static const site = 'https://novelai.quicktagcloud.com';
  static const _timeout = Duration(seconds: 30);

  /// 对照表比法典正文小一个量级(core 压缩后 400KB 上下),等不了那么久:
  /// 等待期间缺译名的芯片在转圈。
  static const _tagZhTimeout = Duration(seconds: 15);

  Future<Directory?> _dir() async {
    if (_cacheResolved) return _cacheDir;
    _cacheResolved = true;
    try {
      final sup = await getApplicationSupportDirectory();
      final d = Directory('${sup.path}/codex_cache');
      await d.create(recursive: true);
      _cacheDir = d;
    } catch (_) {
      _cacheDir = null; // 缓存目录不可用:只影响命中率,不影响功能
    }
    return _cacheDir;
  }

  Future<String> _get(String url, {Duration timeout = _timeout}) async {
    final resp = await _client.get(Uri.parse(url)).timeout(timeout);
    if (resp.statusCode != 200) {
      throw CodexException('HTTP ${resp.statusCode}');
    }
    return utf8.decode(resp.bodyBytes);
  }

  /// 图床配置:拉 media.json,失败退回已知常量(即使拉不到也能出图)。
  Future<CodexMedia> fetchMedia() async {
    try {
      final j = jsonDecode(await _get('$site/data/media.json'));
      if (j is Map<String, dynamic>) return CodexMedia.fromJson(j);
    } catch (_) {}
    return CodexMedia.fallback;
  }

  /// 法典索引(codexes.json)。
  Future<List<CodexMeta>> fetchIndex() async {
    final j = jsonDecode(await _get('$site/data/codexes.json'));
    if (j is! List) throw const CodexException('法典索引格式异常');
    return [
      for (final e in j)
        if (e is Map<String, dynamic>) CodexMeta.fromJson(e),
    ].where((m) => m.id.isNotEmpty).toList();
  }

  /// 一部法典的完整数据:命中缓存读盘;否则拉网 → 落盘 → 淘汰旧版本。
  Future<CodexData> fetchCodex(CodexMeta meta) async {
    final raw = await _loadRaw(meta);
    return compute(codexParsePayload, <Object?>[raw, meta.raw]);
  }

  Future<String> _loadRaw(CodexMeta meta) async {
    final dir = await _dir();
    final cacheName = _cacheName(meta);

    if (dir != null && cacheName != null) {
      final f = File('${dir.path}/$cacheName');
      if (await f.exists()) {
        try {
          final s = await f.readAsString();
          if (s.isNotEmpty) return s;
        } catch (_) {}
      }
    }

    // 拉网:主 URL(dataUrl 或 data/<id>.json)→ 失败退兜底(本地快照)
    String raw;
    try {
      raw = await _get(_dataUrl(meta));
    } catch (e) {
      final fb = meta.fallbackDataUrl;
      if (fb == null) rethrow;
      raw = await _get(fb.startsWith('http') ? fb : '$site/$fb');
    }

    if (dir != null && cacheName != null) {
      try {
        await for (final ent in dir.list()) {
          if (ent is File &&
              ent.uri.pathSegments.last.startsWith('${meta.id}@')) {
            try {
              await ent.delete(); // 淘汰同 id 的旧版本快照
            } catch (_) {}
          }
        }
        await File('${dir.path}/$cacheName').writeAsString(raw);
      } catch (_) {}
    }
    return raw;
  }

  String _dataUrl(CodexMeta meta) =>
      meta.dataUrl ?? '$site/data/${meta.id}.json';

  /// 缓存文件名 `id@版本.json`;无版本则不缓存(对不上号,每次重拉)。
  String? _cacheName(CodexMeta meta) {
    if (meta.version.isEmpty) return null;
    final safe = meta.version.replaceAll(RegExp(r'[^0-9A-Za-z._-]'), '_');
    return '${meta.id}@$safe.json';
  }

  /// 原站的 tag 中文对照(`data/tag_zh/<name>.json`,name = `core` 或法典 id)。
  /// 按 [stamp](见 [codexIndexStamp])落盘到 `codex_cache/tag_zh/`,戳不变即命中
  /// 不重拉;解析放 isolate。
  ///
  /// **从不抛错**:这层只是给芯片补译名,拉不到、格式不认一律返回 null,调用方
  /// 退回 app 自己的译名。抛出去的话 Riverpod 会自动重试半分钟以上,缺译名的
  /// 芯片就一直转圈。
  Future<TagZhShard?> fetchTagZh(String name, String stamp) async {
    final dir = await _tagZhDir();
    final safe = name.replaceAll(RegExp(r'[^0-9A-Za-z._-]'), '_');
    final file = dir == null ? null : File('${dir.path}/$safe@$stamp.json');
    try {
      if (file != null && await file.exists()) {
        final hit = await compute(tagZhParsePayload, await file.readAsString());
        if (hit != null) return hit;
      }
    } catch (_) {}

    try {
      final raw = await _get(
        '$site/data/tag_zh/${Uri.encodeComponent(name)}.json',
        timeout: _tagZhTimeout,
      );
      final parsed = await compute(tagZhParsePayload, raw);
      if (parsed == null || dir == null || file == null) return parsed;
      try {
        await for (final ent in dir.list()) {
          if (ent is File && ent.uri.pathSegments.last.startsWith('$safe@')) {
            try {
              await ent.delete(); // 淘汰同名旧戳
            } catch (_) {}
          }
        }
        await file.writeAsString(raw);
      } catch (_) {}
      return parsed;
    } catch (_) {
      return null;
    }
  }

  Future<Directory?> _tagZhDir() async {
    final base = await _dir();
    if (base == null) return null;
    try {
      final d = Directory('${base.path}/tag_zh');
      await d.create(recursive: true);
      return d;
    } catch (_) {
      return null;
    }
  }

  /// 清空落盘缓存(存储管理用),连同 `tag_zh/` 子目录。
  Future<void> clearCache() async {
    final dir = await _dir();
    if (dir == null) return;
    try {
      await for (final ent in dir.list()) {
        try {
          await ent.delete(recursive: true);
        } catch (_) {}
      }
    } catch (_) {}
  }

  void dispose() => _client.close();
}

/// isolate 里解析:jsonDecode(最重的一步)+ 建词条 + 与索引 meta 合并。
/// 顶层函数(compute 要求),入参/出参必须可跨 isolate 传送 —— [CodexData] 全是
/// 纯数据(含 record),往返无损,由 [codex_test.dart] 真跑一次 isolate 钉死。
CodexData codexParsePayload(List<Object?> args) {
  final raw = args[0] as String;
  final indexRaw = args[1] as Map<String, dynamic>?;
  final j = jsonDecode(raw);
  if (j is! Map<String, dynamic>) {
    throw const CodexException('法典数据格式异常');
  }
  final idx = (indexRaw != null && indexRaw.isNotEmpty)
      ? CodexMeta.fromJson(indexRaw)
      : null;
  return CodexData.parse(j, indexMeta: idx);
}

class CodexException implements Exception {
  const CodexException(this.message);
  final String message;
  @override
  String toString() => message;
}
