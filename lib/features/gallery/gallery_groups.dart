/// 图库展开页的分组:把结果列表切成若干「堆」。
///
/// 三个维度,归属各有各的出处,但都**全程离线**、不联网也不看登录态:
///   - 按时间 —— 沿用 [galleryDayKey];
///   - 按角色 —— 灵感库的角色条目(自建的 + 收藏的 OC)按加权覆盖率匹配(见 [OcMatcher]),
///     再并上离线词库 `assets/danbooru.tsv` 第 5 列标出的角色标签(见 [galleryCharTagsProvider]);
///   - 按画风 —— 灵感库的画风条目,判据是画师整组都在(见 [StyleMatcher])。
///
/// 分组本身是纯函数(可测);归属计算各由一个 provider 现算,**不烤进检索索引**
/// —— 词库和灵感库都是活的,今天新建一个画风条目,老图该立刻归进去。
///
/// 两张命中表的判据和门槛是拿真实数据量出来的(公共 OC 库、画师串库、社区法典;
/// 评测脚本 `test/eval/match_eval_test.dart`),动之前先重跑一遍。
library;

import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/util/prompt_tokens.dart';
import '../editor/data/local_tag_db.dart';
import '../inspiration/public_tags.dart';
import '../inspiration/tag_library.dart';
import '../inspiration/tag_models.dart';
import 'gallery_dates.dart';
import 'gallery_search.dart';
import 'models.dart';

/// 分组维度。存进 UiPrefs 的是 [name],加成员不会动到已存的值。
enum GalleryGroupBy { day, character, style }

extension GalleryGroupByX on GalleryGroupBy {
  String get label => switch (this) {
    GalleryGroupBy.day => '按时间',
    GalleryGroupBy.character => '按角色',
    GalleryGroupBy.style => '按画风',
  };

  /// 时间是分段列表(和以前一样),归属类的是堆叠封面墙。
  bool get stacked => this != GalleryGroupBy.day;
}

/// 一张图的一条归属:[key] 用于聚合(稳定,角色取词库正名),[label] 给人看。
typedef GroupTag = ({String key, String label});

/// 一堆图。[key] 空串 = 未归类。
typedef GalleryGroup = ({String key, String label, List<ResultImage> items});

/// 未归类堆的键。恒排最后 —— 它不是一个「组」,是「剩下的」。
const kGalleryUngroupedKey = '';

/// OC 命中门槛:图里对上的词的**分量**占条目总分量的比例(分量见 [ocTokenWeight])。
///
/// 按枚数算两头都漏:OC 的标签组里服装配饰中位占四分之一强,缺四分之一就不认的话,
/// 换身衣服基本必掉;而「长发、红瞳」和独有特征一样算一票,只和 OC 共享大众词的
/// 别的角色又会被错归进来。按分量算,换装后剩下的独有特征撑得住,大众词凑得再多
/// 也凑不够。0.55 是拿真实数据扫出来的平衡点。
const kOcMatchCover = .55;

/// 至少要对上这么多枚(条目本身不足这么多枚时要求全中)。挡住「几枚的小条目蹭上
/// 一两个独有词就归类」。
const kOcMinKeep = 4;

/// 同一张图命中的几个 OC 条目彼此重合过这个比例(标签集的 Jaccard 相似度),
/// 就当成同一个角色的几个版本,只留覆盖最全的那个。
const kOcOverlap = .5;

/// 画风条目里帖子数到这个量级的词算通用词,不参与判定。画师里最高产的也就几千帖,
/// 画师串里夹带的 `realistic`、`monochrome` 这类词动辄上万到几百万。
const kStyleGenericPosts = 10000;

/// OC 条目里一个词的分量:`(1 / log10(10 + 帖子数))²`。
///
/// 词库没收的(多半是这个 OC 独有的描述)分量 1,「long hair」一百多万帖压到 0.03。
/// 不取平方的话大众词压得不够狠,长得像的另一个角色仍会漏进来一些。
double ocTokenWeight(int posts) {
  final l = math.log(10 + posts) / math.ln10;
  return 1 / (l * l);
}

/// 按天分堆。列表天然新→旧,键的首现序即堆序。
List<GalleryGroup> groupByDay(List<ResultImage> items, DateTime now) {
  final by = <int, List<ResultImage>>{};
  for (final r in items) {
    by.putIfAbsent(galleryDayKey(r.createdAt), () => []).add(r);
  }
  return [
    for (final e in by.entries)
      (key: '${e.key}', label: galleryDayLabel(e.key, now), items: e.value),
  ];
}

/// 按归属分堆。
///
/// 一张图有几条归属就进几堆 —— 一张甘雨 + 刻晴的双人图,在「甘雨」和「刻晴」
/// 里都该看得到;只归其中一边的话,另一边的合集就是缺的,而用户根本不知道缺了。
/// 代价是各堆张数之和会大于总数,所以顶栏读数仍报**去重后**的总数。
///
/// 堆序 = 堆内最新一张的时间降序(与整页新→旧同口径),未归类恒垫底。
/// 堆内保持传入顺序,故也天然新→旧。
List<GalleryGroup> groupByTags(
  List<ResultImage> items,
  Map<String, List<GroupTag>> tagsById,
) {
  final buckets = <String, List<ResultImage>>{};
  final labels = <String, String>{};
  final rest = <ResultImage>[];
  for (final r in items) {
    final tags = tagsById[r.id];
    if (tags == null || tags.isEmpty) {
      rest.add(r);
      continue;
    }
    for (final t in tags) {
      buckets.putIfAbsent(t.key, () => []).add(r);
      // 同一个键的显示名以先到的为准(词库对同一标签只有一个译名,撞不上)
      labels.putIfAbsent(t.key, () => t.label);
    }
  }
  final out = [
    for (final e in buckets.entries)
      (key: e.key, label: labels[e.key] ?? e.key, items: e.value),
  ];
  // 堆内已是新→旧,首张即最新
  out.sort(
    (a, b) => b.items.first.createdAt.compareTo(a.items.first.createdAt),
  );
  if (rest.isNotEmpty) {
    out.add((key: kGalleryUngroupedKey, label: '未归类', items: rest));
  }
  return out;
}

/// 一个分类下可用于归类的条目 = 本地库(自建 + 收藏)∪ **自己发布**的公共条目。
///
/// 后者是必须的:「我的画风 / 我的角色」里有一部分只存在服务端,本地一点副本都
/// 没有(灵感页的「我的」是本地条目 + 公共库里 `createdBy` 是自己的那些拼出来的,
/// 见 `_mergeMine`)。那本来就是用户自己的东西,理应在本地留一份 ——
/// 见 [myPublicTagsProvider]。
///
/// **不含别人发布的**。归类看的是你的提示词里有没有条目的标签,别人的串只要被你
/// 的提示词盖住就会命中,整个公共库都拿来匹配的话会凭空冒出一堆从没选过的堆名。
///
/// 本地的排前面 —— [OcMatcher] / [StyleMatcher] 同名只出一条、平手时排前面的赢,
/// 用户自己起的名该赢。
List<TagEntry> _entriesOf(Ref ref, TagCategory cat) => [
  ...?ref.watch(tagLibraryProvider).value?.of(cat),
  ...?ref.watch(myPublicTagsProvider).value?[cat],
];

/// 图库角色归属:id → 该图命中的角色。两个来源并起来:
///
///   1. **灵感库的角色条目**(`TagCategory.character`)—— 自建的、以及从公共库
///      **收藏**的 OC 都在这里,判据见 [OcMatcher]。OC 的 tag_group 是一串外观
///      标签,Danbooru 词库里根本没有这号角色,不走这一路就永远归不了类。
///   2. **离线 Danbooru 词库**里标了角色类目的标签(见 [LocalTagDb.charactersIn])。
///
/// 同名的只留一条:一个叫「甘雨」的条目,其正向里往往就带着 `ganyu_(genshin_impact)`,
/// 两路都会命中,不去重就会分成两堆一样名字的。库条目优先 —— 那是用户自己起的名。
///
/// **不做增量**:它依赖活的灵感库,用户改一次条目全库归属都要重算,留 memo 只会
/// 给出过期答案。整轮成本 = 图数 × (分词 + 两次查表),几百张是毫秒级;条目里的词
/// 要先去词库查一轮帖子数([LocalTagDb.postCountsOf]),查过的有缓存。
final galleryCharTagsProvider =
    AsyncNotifierProvider<GalleryCharTags, Map<String, List<GroupTag>>>(
      GalleryCharTags.new,
    );

class GalleryCharTags extends AsyncNotifier<Map<String, List<GroupTag>>> {
  /// 每算这么多张让一帧。分词是正则活,几百张连着跑够卡出一下 ——
  /// 而这活儿发生在用户刚点开「全部作品」的那一刻,最不该卡的时候。
  static const _sliceSize = 60;

  @override
  Future<Map<String, List<GroupTag>>> build() async {
    final byId = ref.watch(gallerySearchProvider).byId;
    final db = ref.watch(localTagDbProvider);
    if (byId.isEmpty) return const {};

    final entries = _entriesOf(ref, TagCategory.character);
    final posts = await db.postCountsOf({
      for (final e in entries) ...tokenizeSet(e.positive),
    });
    final matcher = OcMatcher(entries, postCount: (t) => posts[t] ?? 0);

    final out = <String, List<GroupTag>>{};
    var since = 0;
    for (final e in byId.entries) {
      final toks = tokenizeSet(e.value.text);
      // 拷一份再往里加:一个 OC 条目都没有时 match 回的是常量空表,直接加会抛
      final hits = [...matcher.match(toks)];
      final seen = {for (final h in hits) h.label};
      for (final h in await db.charactersIn(toks)) {
        final label = h.zh ?? h.tag.replaceAll('_', ' ');
        if (seen.add(label)) hits.add((key: h.tag, label: label));
      }
      if (hits.isNotEmpty) out[e.key] = hits;
      if (++since >= _sliceSize) {
        since = 0;
        await Future<void>.delayed(Duration.zero);
      }
    }
    return Map.unmodifiable(out);
  }
}

/// 图库画风归属:id → 用到的画风条目(灵感库 [TagCategory.artist])。判据见
/// [StyleMatcher] —— 只比对画师标签,不拿画师串里夹带的质量词/构图词参与判定。
///
/// 不认折叠名。折叠 `<#名字: …>` 是**仅编辑期**语法,提示词被编辑器之外改过一次
/// (导入、清空、权重工具)草稿就判过期,名字跟着没;而标签本身跑不掉。
///
/// **不做增量**:这里依赖的是活的灵感库,用户改一次条目全库归属都要重算,
/// 留 memo 只会给出过期答案。
final galleryStyleTagsProvider =
    AsyncNotifierProvider<GalleryStyleTags, Map<String, List<GroupTag>>>(
      GalleryStyleTags.new,
    );

class GalleryStyleTags extends AsyncNotifier<Map<String, List<GroupTag>>> {
  static const _sliceSize = 60;

  @override
  Future<Map<String, List<GroupTag>>> build() async {
    final byId = ref.watch(gallerySearchProvider).byId;
    final db = ref.watch(localTagDbProvider);
    if (byId.isEmpty) return const {};

    final entries = _entriesOf(ref, TagCategory.artist);
    if (entries.isEmpty) return const {};
    final posts = await db.postCountsOf({
      for (final e in entries) ...tokenizeSet(e.positive),
    });
    final matcher = StyleMatcher(entries, postCount: (t) => posts[t] ?? 0);
    if (matcher.isEmpty) return const {};

    final out = <String, List<GroupTag>>{};
    var since = 0;
    for (final e in byId.entries) {
      final hits = matcher.match(tokenizeSet(e.value.text));
      if (hits.isNotEmpty) out[e.key] = hits;
      if (++since >= _sliceSize) {
        since = 0;
        await Future<void>.delayed(Duration.zero);
      }
    }
    return Map.unmodifiable(out);
  }
}

/// 倒排:标签 → 含它的条目下标。逐图逐条目做集合比对的话,条目一多就是几十万次;
/// 有了它一趟遍历就把「每个条目与这张图共有几枚」全数出来。
class _Inverted {
  _Inverted(List<Set<String>> rows) {
    for (var i = 0; i < rows.length; i++) {
      for (final t in rows[i]) {
        _by.putIfAbsent(t, () => []).add(i);
      }
    }
  }

  final _by = <String, List<int>>{};

  /// 条目下标 → 与 [img] 共有几枚;一枚都不共有的条目不在结果里。
  Map<int, int> shared(Set<String> img) {
    final out = <int, int>{};
    for (final t in img) {
      for (final i in _by[t] ?? const <int>[]) {
        out[i] = (out[i] ?? 0) + 1;
      }
    }
    return out;
  }
}

/// 灵感库 OC / 角色条目的命中表:一组条目建一次,逐图查。
///
/// 判据是**加权覆盖率**:条目里每个词按 [ocTokenWeight] 定分量,图里对上的分量
/// 占条目总分量过 [kOcMatchCover]、且至少对上 [kOcMinKeep] 枚,就算用了这个 OC。
///
///   - **不看顺序**。按序比过,顺序几乎没挡住误判,却让两种常见写法直接归零:
///     外观放角色槽、服装留主提示词(检索文本是主提示词在前、角色槽在后拼起来的),
///     以及出图前把几枚标签挪了位置。
///   - **同一个角色的几个版本只留一个**:几个命中条目彼此重合过 [kOcOverlap],
///     只留覆盖最全的。「小夜」和「小夜·泳装」都在库里时,泳装图只进后者、
///     日常图只进前者。覆盖一样时排前面的赢 —— 调用方把本地条目排在前面。
///   - 同名的(本地一份 + 收藏的公共副本)只出一条,取覆盖最全的那份。
class OcMatcher {
  OcMatcher(
    Iterable<TagEntry> entries, {
    required int Function(String token) postCount,
    this.cover = kOcMatchCover,
  }) {
    for (final e in entries) {
      final toks = tokenizeSet(e.positive);
      final name = e.name.trim();
      // 空标签集会被判成「人人都用了」,直接剔掉
      if (toks.isEmpty || name.isEmpty) continue;
      final weight = {for (final t in toks) t: ocTokenWeight(postCount(t))};
      _rows.add((
        name: name,
        toks: toks,
        weight: weight,
        total: weight.values.fold(0.0, (a, b) => a + b),
        need: math.min(toks.length, kOcMinKeep),
      ));
    }
    _inv = _Inverted([for (final r in _rows) r.toks]);
  }

  final _rows =
      <
        ({
          String name,
          Set<String> toks,
          Map<String, double> weight,
          double total,
          int need,
        })
      >[];
  late final _Inverted _inv;

  /// 命中门槛,默认 [kOcMatchCover];评测脚本扫门槛时才传别的值。
  final double cover;

  bool get isEmpty => _rows.isEmpty;

  /// 一张图命中的条目;[img] 是这张图提示词的 [tokenizeSet]。
  List<GroupTag> match(Set<String> img) {
    if (_rows.isEmpty || img.isEmpty) return const [];
    // 名字 → 这个名字下覆盖最全的那一行
    final best = <String, ({int row, double cover})>{};
    _inv.shared(img).forEach((i, n) {
      final r = _rows[i];
      if (n < r.need) return;
      var got = 0.0;
      for (final t in r.toks) {
        if (img.contains(t)) got += r.weight[t]!;
      }
      final share = got / r.total;
      if (share < cover) return;
      final prev = best[r.name];
      if (prev == null || _ahead((row: i, cover: share), prev)) {
        best[r.name] = (row: i, cover: share);
      }
    });
    final hits = best.values.toList()..sort((a, b) => a.row - b.row);
    return [
      for (final a in hits)
        if (!hits.any(
          (b) =>
              b.row != a.row &&
              _ahead(b, a) &&
              _jaccard(_rows[a.row].toks, _rows[b.row].toks) >= kOcOverlap,
        ))
          (key: _rows[a.row].name, label: _rows[a.row].name),
    ];
  }

  /// [a] 比 [b] 更该留下:覆盖更全,一样全时排得更前。
  static bool _ahead(
    ({int row, double cover}) a,
    ({int row, double cover}) b,
  ) => a.cover > b.cover || (a.cover == b.cover && a.row < b.row);
}

double _jaccard(Set<String> a, Set<String> b) {
  final both = a.intersection(b).length;
  return both / (a.length + b.length - both);
}

/// NAI 专有的质量 / 年份 / 美学 / 控制词。Danbooru 词库里没有,帖子数筛不出来,
/// 得单列 —— 名单取自公共画师串库里实际夹带的词。
final _styleExtraRe = RegExp(
  r'^(year ?\d{4}|masterpiece|best quality|amazing quality|great quality|'
  r'good quality|normal quality|bad quality|worst quality|very aesthetic|'
  r'aesthetic|very awa|incredibly absurdres|artist collaboration|no text|'
  r'highly finished|ultra-detailed|ultra detailed|detailed|4k|8k|sfw|nsfw|'
  r'location|cinematic lighting|volumetric lighting|soft shadows)$',
);

/// 灵感库画风条目的命中表:一组条目建一次,逐图查。
///
/// 判据是**画师整组都在**,不看顺序,权重记号不算:
///   - **只认画师**。画师串里常夹着 `masterpiece`、`year 2025`、`no text`、
///     `realistic`,这些词出图时顺手就改,要求一枚不差的话改个年份整组就对不上。
///     NAI 专有的质量 / 年份词按名单剔,其余按词库帖子数,过 [kStyleGenericPosts]
///     的算通用词。一个画师都没剩的条目(纯质量词串)退回全部标签。
///   - **少一个画师就不算**:共用某个画师的两个画风不能互相串味。
///   - **被包含的让位**:A 的画师是 B 的真子集、图里 B 整组都在时,那是 B,
///     不是「A 加一个画师」。
///   - 带不带 `artist:` 前缀是同一个画师(见 [cleanPromptToken])。
///   - 同名的只出一条。只跳**已经命中过**的名字:先撞上的同名条目没过判定时,
///     后一个还要有机会。
class StyleMatcher {
  StyleMatcher(
    Iterable<TagEntry> entries, {
    required int Function(String token) postCount,
  }) {
    for (final e in entries) {
      final all = tokenizeSet(e.positive);
      final name = e.name.trim();
      // 空标签集会被判成「人人都用了」,直接剔掉
      if (all.isEmpty || name.isEmpty) continue;
      final core = {
        for (final t in all)
          if (!_styleExtraRe.hasMatch(t) && postCount(t) < kStyleGenericPosts)
            t,
      };
      _rows.add((name: name, toks: core.isEmpty ? all : core));
    }
    _inv = _Inverted([for (final r in _rows) r.toks]);
  }

  final _rows = <({String name, Set<String> toks})>[];
  late final _Inverted _inv;

  bool get isEmpty => _rows.isEmpty;

  /// 一张图命中的条目;[img] 是这张图提示词的 [tokenizeSet]。
  List<GroupTag> match(Set<String> img) {
    if (_rows.isEmpty || img.isEmpty) return const [];
    final shared = _inv.shared(img);
    final names = <String>{};
    final hit = <int>[];
    for (final i in shared.keys.toList()..sort()) {
      final r = _rows[i];
      if (shared[i] != r.toks.length || !names.add(r.name)) continue;
      hit.add(i);
    }
    return [
      for (final a in hit)
        if (!hit.any(
          (b) =>
              _rows[b].toks.length > _rows[a].toks.length &&
              _rows[b].toks.containsAll(_rows[a].toks),
        ))
          (key: _rows[a].name, label: _rows[a].name),
    ];
  }
}
