import 'dart:convert';

import 'package:flutter/foundation.dart' show VoidCallback, compute;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/util/prompt_tokens.dart';
import 'suggestions.dart';

/// 顶层函数(compute 要求):在后台 isolate 解析整份 TSV。
/// 行格式 `tag<TAB>post_count<TAB>中文<TAB>alias1,alias2<TAB>category`。
///
/// 第 5 列 category 用 Danbooru 的类目编号,**目前只填了 4(角色)**,其余留空
/// (= 未定类,不是「普通标签」)。建库时的来源与覆盖见 [LocalTagDb] 的类注释。
List<_Entry> _parseTsv(String raw) {
  final list = <_Entry>[];
  for (final line in const LineSplitter().convert(raw)) {
    if (line.isEmpty) continue;
    final f = line.split('\t');
    if (f.length < 2) continue;
    final count = int.tryParse(f[1]) ?? 0;
    if (count < 50) continue; // 滤冷门,减内存(与 web <50 剔除一致)
    final zh = LocalTagDb.firstZh(
      (f.length > 2 && f[2].isNotEmpty) ? f[2] : null,
      tag: f[0],
    );
    final aliases = (f.length > 3 && f[3].isNotEmpty)
        ? [
            for (final s in f[3].split(','))
              if (s.isNotEmpty && !s.startsWith('/')) s, // 去掉 /lh 之类快捷别名
          ]
        : const <String>[];
    // 角色的反查键在这里(isolate 里)就算好:提示词侧走同一个 [cleanPromptToken],
    // 双边同归一才对得上(`ganyu_(genshin_impact)` 与 `ganyu (genshin impact)`
    // 都归到 `ganyu genshin impact`)。非角色行不算 —— 九万行的正则不白跑。
    final isChar = f.length > 4 && f[4] == '4';
    list.add(
      _Entry(
        f[0],
        count,
        zh,
        aliases,
        charKey: isChar ? cleanPromptToken(f[0]) : null,
      ),
    );
  }
  return list;
}

/// 离线 Danbooru 标签库(`assets/danbooru.tsv`,**含中文翻译**,已按热度降序)。
/// 用户在设置里显式选了「离线词库」时的英文补全走这里——**完全离线**,不碰网络,
/// 天然绕开 Cloudflare。(2026-08-25 前它还是「未授权模式」的兜底,门禁解除后不再是。)
/// 行格式(tab 分隔):`tag<TAB>post_count<TAB>中文<TAB>alias1,alias2<TAB>category`;
/// tag 用下划线,app 内展示/插入转空格;中文来自社区词库(ChinaGPT 10w + byzod 精选合并)。
///
/// **category 列(2026-09-05 补)**:Danbooru 类目编号,目前只填 4(角色),
/// 共 26,083 行(count≥50 的目标集里 23,983 行,占 26.3%)。来源是后端两份建库
/// 产物的并集 —— `tags_enhanced.csv` 的 category=4(20,169)+
/// `role_tag_mapping.json` 的 role_en(28,335);两者交叉验证 19,263 条**完全一致**,
/// 所以并集可直接用。画师(类目 1)与 meta(5)**上游没有**,要另跑 Danbooru
/// `tags.json?search[category]=1` 采集,本轮没做;作品(3)只有 `tags_enhanced`
/// 那 5,225 条可信 —— `role_tag_mapping.origin_en` 抽样只有 71% 真是作品
/// (19.7% 其实是普通标签、9.2% 是角色,`kantoku`/`rella` 这种画师限定符被误提升),
/// 故未采用。空 category = **未定类**,不等于「普通标签」。
class LocalTagDb {
  List<_Entry>? _entries;
  Future<void>? _loading;
  Future<void>? _warming;

  Future<void> _ensureLoaded() {
    if (_entries != null) return Future.value();
    return _loading ??= _load();
  }

  /// 把全库中文/热度灌进 suggestions 反查缓存(注音层/词条栏 sync 查询用)。
  /// 不灌的话翻译只在补全命中时零星回填——手打/带入的既有 prompt 都显示不出。
  /// 分片让帧;进编辑器时触发,幂等。
  ///
  /// [onChunk]:灌到前几片时各调一次,让调用方**提前刷一次**,不必干等整轮。
  /// 整轮不便宜 —— 桌面实测读 asset + isolate 解析 195ms、灌注 427ms,手机上
  /// 一两秒;而词库按热度降序,拿真实提示词量过:前 8000 条(灌注进度 8%)就已经
  /// 覆盖其中约七成的词。所以头三片各刷一次、剩下的到货再补,首屏观感差很多。
  ///
  /// 刷太勤会让注音层反复重排,所以只在 [_warmNotifyAt] 那几个点刷,不是每片都刷。
  ///
  /// 多个调用者(编辑器 + 同屏若干 `PromptChips`)各自的 [onChunk] **都会收到** ——
  /// 灌注本身仍只跑一轮。记忆化写成 `_warming ??=` 的话只有头一个调用者的回调能生效,
  /// 后来的只能干等整轮,所以回调单独存一份。已经灌完时不再登记(直接 await 那个
  /// 完成的 future 即可)。
  Future<void> warmTagMeta({VoidCallback? onChunk}) {
    if (onChunk != null && !_warmDone) _warmListeners.add(onChunk);
    return _warming ??= _warmTagMeta();
  }

  final _warmListeners = <VoidCallback>[];
  bool _warmDone = false;

  /// 一片最多占主线程多久 —— **也就是这轮灌注最多能让哪一帧晚多久**。
  ///
  /// 分片一直都有,但早先是按**条数**切(8000 条一片)。条数和耗时不是一回事:
  /// 同样 8000 条,在这台机器上十几毫秒,一帧就整个没了 —— 于是"开机灌注"变成
  /// 十来帧连着丢,撞上切页面就是一口气卡那么一下。改按**时间**切,片长在哪台
  /// 机器上都是这个数,一帧最多被推迟 2ms,挤得进 16ms 的预算。
  ///
  /// 让帧用零延时 Timer 就够:同一时刻只挂着**一个**待跑的片,vsync 一到就排在
  /// 它后面,最多等这一片跑完。(必须是 `Future.delayed`,不能 `await null` ——
  /// 后者只让微任务,事件循环根本不喘气,vsync 进不来。)
  static const _warmSliceUs = 2000;

  /// 在这几个进度点回调 [warmTagMeta] 的 `onChunk`。都落在正名那一遍里
  /// (别名遍从 9 万多开始),因为热度降序的收益全在前面。
  static const _warmNotifyAt = {8000, 16000, 32000};

  void _notifyWarm() {
    for (final f in _warmListeners) {
      f();
    }
  }

  Future<void> _warmTagMeta() async {
    await _ensureLoaded();
    final entries = _entries;
    if (entries == null) return;
    var i = 0;
    // 这一片已经占了主线程多久;到点就让一帧,让完清零。
    //
    // 写成同步判定、由调用处 await,而不是包一个 `Future<void> yieldIfDue()`:
    // 那样每一条都要 await 一次,即便立刻返回也得建一个 Future、走一轮微任务
    // —— 十一万条,光这一下就够把省下来的钱花回去。
    final slice = Stopwatch()..start();
    var since = 0; // 距上次看表又过了多少条:看表也要钱,64 条问一次够细了
    bool sliceDue() {
      if (++since < 64) return false;
      since = 0;
      if (slice.elapsedMicroseconds < _warmSliceUs) return false;
      slice.reset();
      return true;
    }

    final taken = <String>{};
    for (final e in entries) {
      final name = e.tag.replaceAll('_', ' ');
      taken.add(metaKey(name));
      if (e.zh != null || e.count > 0) {
        cacheTagMeta(name, trans: e.zh, count: e.count);
      }
      // 进度回调按**条数**走(热度降序,前几片的收益最大),让帧按**时间**走,
      // 两者不再互相绑定 —— 早先合在一条 if 里,分片一改这几个点就再也对不上。
      if (_warmNotifyAt.contains(++i)) _notifyWarm();
      if (sliceDue()) await Future<void>.delayed(Duration.zero);
    }
    // 第二遍:别名(第 4 列)。Danbooru 的别名就是同一个标签的另一种写法 ——
    // 旧名、拼写变体、俗称(`hires`/`high res`→highres、`1girls`→1girl、
    // `longhair`→long hair、`oppai`/`tits`→breasts),译名和热度都该跟着正名走。
    // 这些写法在真实提示词里极常见,不认的话整词注音空白,还会被白送去后端问。
    // 全库能这么捡回 20,966 条,且头部全是百万热度的词。
    //
    // 正名优先:与正式标签同名的别名跳过(`taken` 里已有)。别名之间撞车时先到
    // 先得 —— 词库按热度降序,所以赢的是更热门那个标签,这正是想要的。
    for (final e in entries) {
      if (e.zh == null && e.count <= 0) continue;
      for (final a in e.aliases) {
        if (!taken.add(metaKey(a))) continue;
        cacheTagMeta(a, trans: e.zh, count: e.count);
      }
      if (sliceDue()) await Future<void>.delayed(Duration.zero);
    }
    _warmDone = true;
    _warmListeners.clear(); // 灌完就不再需要,别攥着已 dispose 的 State 的闭包
  }

  /// 社区词库常一格多译,注音只取第一段。实现在 [firstTransSegment] ——
  /// 网络回填那一路(`cacheTagMeta`)用的是同一个,两边分头维护过一次名单,
  /// 结果 `|` 只补了一处。非私有:后台解析的顶层函数 [_parseTsv] 要用。
  static String? firstZh(String? zh, {String? tag}) =>
      firstTransSegment(zh, tag: tag);

  Future<void> _load() async {
    // rootBundle 是平台通道,只能在主 isolate 读;解析(9 万行、几十万次字符串
    // 分配)扔进后台 isolate。原先整段在主 isolate 同步跑完、一帧都不让,
    // 而触发时机正是用户在编辑器里打字 —— 最在意流畅的场景。见 S3-02。
    final raw = await rootBundle.loadString('assets/danbooru.tsv');
    _entries = await compute(_parseTsv, raw);
  }

  /// 前缀匹配:标签名命中优先、别名命中次之(各自因源已按热度降序)。取前 [limit] 条。
  Future<List<Suggestion>> search(String query, {int limit = 15}) async {
    await _ensureLoaded();
    final entries = _entries;
    if (entries == null) return const [];
    final q = query.trim().toLowerCase().replaceAll(' ', '_');
    if (q.length < 2) return const [];

    final primary = <_Entry>[]; // 标签名前缀命中
    final secondary = <_Entry>[]; // 仅别名前缀命中
    final seen = <String>{};
    for (final e in entries) {
      if (e.tag.startsWith(q)) {
        if (seen.add(e.tag)) primary.add(e);
        if (primary.length >= limit) break; // 已按热度,够了就停
      } else if (secondary.length < limit &&
          e.aliases.any((a) => a.startsWith(q))) {
        if (seen.add(e.tag)) secondary.add(e);
      }
    }
    final out = <Suggestion>[];
    for (final e in [...primary, ...secondary].take(limit)) {
      final text = e.tag.replaceAll('_', ' ');
      cacheTagMeta(text, trans: e.zh, count: e.count); // 回填注音/热度
      out.add(
        Suggestion(
          text: text,
          kind: SuggestionKind.tag,
          trans: e.zh,
          count: e.count,
        ),
      );
    }
    return out;
  }

  // ---- 角色反查(离线) ----

  /// 归一化键 → 角色行。正名与别名同表,**正名优先**;别名之间撞车先到先得 ——
  /// 词库按热度降序,赢的是更热门那个,与 [_warmTagMeta] 的口径一致。
  Map<String, _Entry>? _charIdx;

  Map<String, _Entry> _ensureCharIdx(List<_Entry> entries) {
    final idx = _charIdx;
    if (idx != null) return idx;
    final out = <String, _Entry>{};
    for (final e in entries) {
      if (e.charKey != null) out[e.charKey!] = e;
    }
    // 别名遍:`reimu_hakurei` 也该认出博丽灵梦。正名已占的键不覆盖。
    for (final e in entries) {
      if (e.charKey == null) continue;
      for (final a in e.aliases) {
        out.putIfAbsent(cleanPromptToken(a), () => e);
      }
    }
    return _charIdx = out;
  }

  /// 提示词分词集合 → 命中的角色标签,**按热度降序**(库本身即热度序)。
  ///
  /// 分词用 [tokenizeSet],与本表的键同走 [cleanPromptToken],下划线/括号/权重
  /// 记号两边同归一。词库没加载好(读 asset 失败)时得空表,调用方按「没有角色」
  /// 处理即可,不必区分。
  Future<List<CharacterTag>> charactersIn(Set<String> tokens) async {
    if (tokens.isEmpty) return const [];
    try {
      await _ensureLoaded();
    } catch (_) {
      return const [];
    }
    final entries = _entries;
    if (entries == null) return const [];
    final idx = _ensureCharIdx(entries);
    // 遍历 tokens(几十个)查表,而不是遍历两万多个角色行
    final hit = <_Entry>{};
    for (final t in tokens) {
      final e = idx[t];
      if (e != null) hit.add(e);
    }
    if (hit.isEmpty) return const [];
    final out = [
      for (final e in hit) (tag: e.tag, zh: e.zh, count: e.count),
    ];
    out.sort((a, b) => b.count.compareTo(a.count));
    return out;
  }
}

/// 一枚命中的角色标签。[tag] 是词库正名(下划线形式),[zh] 可空。
typedef CharacterTag = ({String tag, String? zh, int count});

class _Entry {
  _Entry(this.tag, this.count, this.zh, this.aliases, {this.charKey});
  final String tag;
  final int count;
  final String? zh; // 中文翻译(可空)
  final List<String> aliases;

  /// 角色行的反查键(= `cleanPromptToken(tag)`);非角色为 null。
  final String? charKey;
}

/// 全局单例(懒加载一次,常驻内存)。
final localTagDbProvider = Provider<LocalTagDb>((ref) => LocalTagDb());
