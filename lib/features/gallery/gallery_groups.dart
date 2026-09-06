/// 图库展开页的分组:把结果列表切成若干「堆」。
///
/// 三个维度,归属各有各的出处,但都**全程离线**、不联网也不看登录态:
///   - 按时间 —— 沿用 [galleryDayKey];
///   - 按角色 —— 离线词库 `assets/danbooru.tsv` 第 5 列 category 标出了角色标签,
///     拿检索索引那份归一化提示词一分词就能反查(见 [LocalTagDb.charactersIn]);
///   - 按画风 —— 灵感库的画风条目,判据是**标签集包含**(见 [galleryStyleTagsProvider])。
///
/// 分组本身是纯函数(可测);归属计算各由一个 provider 现算,**不烤进检索索引**
/// —— 词库和灵感库都是活的,今天新建一个画风条目,老图该立刻归进去。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/util/prompt_tokens.dart';
import '../editor/data/local_tag_db.dart';
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

/// 按天分堆。列表天然新→旧,键的首现序即堆序。
List<GalleryGroup> groupByDay(List<ResultImage> items, DateTime now) {
  final by = <int, List<ResultImage>>{};
  for (final r in items) {
    by.putIfAbsent(galleryDayKey(r.createdAt), () => []).add(r);
  }
  return [
    for (final e in by.entries)
      (
        key: '${e.key}',
        label: galleryDayLabel(e.key, now),
        items: e.value,
      ),
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
  out.sort((a, b) => b.items.first.createdAt.compareTo(a.items.first.createdAt));
  if (rest.isNotEmpty) {
    out.add((key: kGalleryUngroupedKey, label: '未归类', items: rest));
  }
  return out;
}

/// 图库角色归属:id → 该图命中的角色(热度降序)。
///
/// 纯派生自 [gallerySearchProvider] 的归一化文本 —— 那份索引本身可重建,
/// 这里再存一份盘上副本没有意义,重启现算即可。
///
/// **增量**:算过的 id 留在实例里,新图进来只算新的那几张。检索索引每收一张
/// 新图就变一次,不增量的话每次出图都要重扫全库。图被删/被裁时顺手清掉陈条。
final galleryCharTagsProvider =
    AsyncNotifierProvider<GalleryCharTags, Map<String, List<GroupTag>>>(
      GalleryCharTags.new,
    );

class GalleryCharTags extends AsyncNotifier<Map<String, List<GroupTag>>> {
  final _memo = <String, List<GroupTag>>{};

  /// 每算这么多张让一帧。分词是正则活,几百张连着跑够卡出一下 ——
  /// 而这活儿发生在用户刚点开「全部作品」的那一刻,最不该卡的时候。
  static const _sliceSize = 60;

  @override
  Future<Map<String, List<GroupTag>>> build() async {
    final byId = ref.watch(gallerySearchProvider).byId;
    final db = ref.watch(localTagDbProvider);

    var since = 0;
    for (final e in byId.entries) {
      if (_memo.containsKey(e.key)) continue;
      final hits = await db.charactersIn(tokenizeSet(e.value.text));
      _memo[e.key] = [
        for (final h in hits)
          (key: h.tag, label: h.zh ?? h.tag.replaceAll('_', ' ')),
      ];
      if (++since >= _sliceSize) {
        since = 0;
        await Future<void>.delayed(Duration.zero);
      }
    }
    _memo.removeWhere((id, _) => !byId.containsKey(id));
    return Map.unmodifiable(_memo);
  }
}

/// 图库画风归属:id → 用到的画风条目(灵感库 [TagCategory.artist])。
///
/// 判据是**标签集包含**:条目的正向标签**全都**在这张图的提示词里,才算用了它。
/// 画风条目多是几枚画师标签的组合,少一枚就不是那个画风 —— 只命中一枚就归组的话,
/// 凡是共用某个画师的条目会互相串味。
///
/// 不认折叠名。折叠 `<#名字: …>` 是**仅编辑期**语法,提示词被编辑器之外改过一次
/// (导入、清空、权重工具)草稿就判过期,名字跟着没;而标签本身跑不掉。
///
/// 也**不做增量**:这里依赖的是活的灵感库,用户改一次条目全库归属都要重算,
/// 留 memo 只会给出过期答案。整轮成本 = 图数 × 命中的候选条目数,几百张是毫秒级。
final galleryStyleTagsProvider =
    AsyncNotifierProvider<GalleryStyleTags, Map<String, List<GroupTag>>>(
      GalleryStyleTags.new,
    );

class GalleryStyleTags extends AsyncNotifier<Map<String, List<GroupTag>>> {
  static const _sliceSize = 60;

  @override
  Future<Map<String, List<GroupTag>>> build() async {
    final byId = ref.watch(gallerySearchProvider).byId;
    final lib = ref.watch(tagLibraryProvider).value;
    if (lib == null || byId.isEmpty) return const {};

    final matcher = StyleMatcher(lib.of(TagCategory.artist));
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

/// 画风判定表:灵感库画风条目建一次,逐图查。
///
/// 判据是**标签集包含**:条目的正向标签全都在图里才算命中。画风条目多是几枚
/// 画师标签的组合,少一枚就不是那个画风 —— 只命中一枚就归组的话,凡是共用某个
/// 画师的条目会互相串味。
class StyleMatcher {
  StyleMatcher(Iterable<TagEntry> artistEntries) {
    for (final e in artistEntries) {
      final toks = tokenizeSet(e.positive);
      final name = e.name.trim();
      // 空标签集会被 containsAll 判成「人人都用了」,直接剔掉
      if (toks.isEmpty || name.isEmpty) continue;
      _entries.add((name: name, toks: toks));
    }
    // 倒排:锚点标签 → 候选条目。没有它就得逐图逐条目做包含判定(条目一多就是
    // 几十万次集合比对);有了它每张图只验撞上锚点的那几条。
    for (var i = 0; i < _entries.length; i++) {
      _byAnchor.putIfAbsent(_entries[i].toks.first, () => []).add(i);
    }
  }

  final _entries = <({String name, Set<String> toks})>[];
  final _byAnchor = <String, List<int>>{};

  bool get isEmpty => _entries.isEmpty;

  /// 一张图的画风归属。同名条目(本地一份 + 收藏的公共一份)只出一条 ——
  /// 用户眼里那就是同一个画风,分成两堆纯属实现细节漏出来。
  List<GroupTag> match(Set<String> imageTokens) {
    final seen = <String>{};
    final hits = <GroupTag>[];
    for (final t in imageTokens) {
      for (final i in _byAnchor[t] ?? const <int>[]) {
        final e = _entries[i];
        // 只跳**已经命中过**的名字。写成 `!seen.add(name) continue` 的话,
        // 同名条目里先撞上的那个没通过包含判定,后一个就再也没机会验了。
        if (seen.contains(e.name)) continue;
        if (!imageTokens.containsAll(e.toks)) continue;
        seen.add(e.name);
        hits.add((key: e.name, label: e.name));
      }
    }
    return hits;
  }
}
