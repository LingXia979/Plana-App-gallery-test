/// 由上游社区词库生成离线词库的源数据 `assets/danbooru.tsv`,之后再跑
/// `dart run tool/build_tag_index.dart` 编进包的索引。
///
///     dart run tool/import_tag_dict.dart          # 下载钉死的上游版本(校验 SHA-256)
///     dart run tool/import_tag_dict.dart <csv>    # 用本地文件(同样校验)
///
/// 上游:zhulinyv/Auto-NovelAI-Refactor 的 `assets/danbooru_tags_full_zh.csv`
/// (GPL-3.0,与本项目同许可)。列序 `tag,category,count,aliases,zh`,32.7 万行,
/// 每行都有中文,带完整的 Danbooru 类目(0 一般 / 1 画师 / 3 作品 / 4 角色 /
/// 5 meta)。它在 2026-08-28 取代了旧离线库的出处 `danbooru_e621_merged_with_zh.csv`。
///
/// 合并口径:
///  - **以上游为主体**:热度 ≥50 的行全收,译名、热度、别名、类目都用上游的;
///  - 旧 TSV 里上游既没有这个名字、也不拿它当别名的行照旧保留 —— 多是 Danbooru
///    删掉或改名后没挂别名的旧 tag(`floating_earring`、`three_quarter_view`),
///    提示词里还常见旧写法;名字里带 `"` 的是当年 CSV 没解转义的残渣,丢掉;
///  - **角色取并集**:旧 TSV 标了角色、上游却标成一般 tag 的(五十来条,多是
///    罗小黑、赛马娘的衣装变体)仍按角色算 —— 图库按角色归类靠它。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;
import 'package:plana_app/features/editor/data/suggestions.dart' show metaKey;
import 'package:plana_app/features/editor/data/tag_index.dart' show kTagTsv;

const _url =
    'https://raw.githubusercontent.com/zhulinyv/Auto-NovelAI-Refactor/'
    '7b2aa9d3394ef821c52577f33972ce8922a31512/assets/danbooru_tags_full_zh.csv';
const _sha256 =
    '7ca87ff044f27b6efb49abe39915ca1445a33f095128092ae091cf91cf5097a2';

/// 与建库口径一致([TagIndexSpec] 也滤掉 <50),更冷门的不进 TSV。
const _minCount = 50;

typedef _Row = ({
  String tag,
  int count,
  String zh,
  String aliases,
  String category,
});

Future<void> main(List<String> args) async {
  final bytes = args.isEmpty
      ? await _download(_url)
      : await File(args.first).readAsBytes();
  final digest = sha256.convert(bytes).toString();
  if (digest != _sha256) {
    stderr.writeln('SHA-256 不符:$digest(期望 $_sha256)');
    exit(1);
  }

  final upstream = <_Row>[];
  var skipped = 0;
  for (final line in const LineSplitter().convert(utf8.decode(bytes))) {
    if (line.isEmpty) continue;
    final f = _csvFields(line);
    final count = f.length == 5 ? int.tryParse(f[2]) : null;
    if (count == null || f[0].isEmpty) {
      skipped++;
      continue;
    }
    upstream.add((
      tag: f[0],
      count: count,
      zh: f[4].trim(),
      aliases: f[3],
      category: f[1],
    ));
  }

  // 上游认得的写法(正名 + 别名),旧行只在两边都对不上时保留
  final known = <String>{};
  for (final r in upstream) {
    known.add(metaKey(r.tag));
    for (final a in r.aliases.split(',')) {
      if (a.isNotEmpty && !a.startsWith('/')) known.add(metaKey(a));
    }
  }
  final oldChars = <String>{};
  final kept = <_Row>[];
  for (final line in const LineSplitter().convert(
    File(kTagTsv).readAsStringSync(),
  )) {
    final f = line.split('\t');
    if (f.length < 2) continue;
    final count = int.tryParse(f[1]) ?? 0;
    if (f.length > 4 && f[4] == '4') oldChars.add(metaKey(f[0]));
    if (count < _minCount ||
        f[0].contains('"') ||
        known.contains(metaKey(f[0]))) {
      continue;
    }
    kept.add((
      tag: f[0],
      count: count,
      zh: f.length > 2 ? f[2] : '',
      aliases: f.length > 3 ? f[3] : '',
      category: f.length > 4 ? f[4] : '',
    ));
  }

  final rows = [
    for (final r in upstream)
      if (r.count >= _minCount)
        r.category == '0' && oldChars.contains(metaKey(r.tag))
            ? (
                tag: r.tag,
                count: r.count,
                zh: r.zh,
                aliases: r.aliases,
                category: '4',
              )
            : r,
    ...kept,
  ];
  // 按热度降序(索引的补全排序与撞键先到先得都靠它);同热度保持原有先后
  final order = [for (var i = 0; i < rows.length; i++) i]
    ..sort((a, b) {
      final c = rows[b].count.compareTo(rows[a].count);
      return c != 0 ? c : a.compareTo(b);
    });

  final out = StringBuffer();
  for (final i in order) {
    final r = rows[i];
    out
      ..write(r.tag)
      ..write('\t')
      ..write(r.count)
      ..write('\t')
      ..write(r.zh)
      ..write('\t')
      ..write(r.aliases)
      ..write('\t')
      ..write(r.category)
      ..write('\n');
  }
  File(kTagTsv).writeAsStringSync(out.toString());
  stdout.writeln(
    '$kTagTsv  ${rows.length} 行(上游 ${rows.length - kept.length} + '
    '保留旧行 ${kept.length});上游跳过 $skipped 行。'
    '接着跑 dart run tool/build_tag_index.dart',
  );
}

Future<List<int>> _download(String url) async {
  // 认 HTTP(S)_PROXY:Dart 的 HttpClient 默认直连,不读环境变量
  final client = HttpClient()
    ..findProxy = HttpClient.findProxyFromEnvironment;
  try {
    final resp = await (await client.getUrl(Uri.parse(url))).close();
    if (resp.statusCode != 200) {
      stderr.writeln('下载失败:HTTP ${resp.statusCode}');
      exit(1);
    }
    final bytes = <int>[];
    await for (final chunk in resp) {
      bytes.addAll(chunk);
    }
    return bytes;
  } finally {
    client.close();
  }
}

/// 一行 CSV → 字段(RFC 4180:双引号包裹、`""` 转义)。上游没有跨行字段,
/// 逐行解析即可。
List<String> _csvFields(String line) {
  final out = <String>[];
  final sb = StringBuffer();
  var quoted = false;
  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (quoted) {
      if (c != '"') {
        sb.write(c);
      } else if (i + 1 < line.length && line[i + 1] == '"') {
        sb.write('"');
        i++;
      } else {
        quoted = false;
      }
    } else if (c == '"') {
      quoted = true;
    } else if (c == ',') {
      out.add(sb.toString());
      sb.clear();
    } else {
      sb.write(c);
    }
  }
  out.add(sb.toString());
  return out;
}
