/// 补全数据源(占位词库)。
/// v1 = 内置精选词库 + Danbooru 公共 API(后续接);v2 再上 AI 推荐与画师串。
/// 此文件不依赖任何编辑器模型,避免循环引用。
library;

enum SuggestionKind { tag, character, oc, work, artist }

class Suggestion {
  const Suggestion({
    required this.text,
    required this.kind,
    this.trans,
    this.source,
    this.note,
    this.count = 0,
    this.insertText,
    this.natural = false,
  });

  /// 英文标签 / 实体名
  final String text;
  final SuggestionKind kind;

  /// 实际插入 prompt 的载荷(为空则用 [text])。画师=artist_string、OC=tag_group;
  /// 作品**不用**这个字段(默认插作品 tag 本身),随机角色见 [randomPick]。
  final String? insertText;

  /// 「翻译为英文」自然语言行:选中时才把 [text](中文)整句翻成英文再替换。
  final bool natural;

  /// 中文翻译
  final String? trans;

  /// 来源作品(角色用)
  final String? source;

  /// 附注(OC/作品的插入说明)
  final String? note;

  /// 热度(0 = 不显示)
  final int count;

  Suggestion copyWith({
    String? text,
    SuggestionKind? kind,
    String? trans,
    String? source,
    String? note,
    int? count,
    String? insertText,
    bool? natural,
  }) => Suggestion(
    text: text ?? this.text,
    kind: kind ?? this.kind,
    trans: trans ?? this.trans,
    source: source ?? this.source,
    note: note ?? this.note,
    count: count ?? this.count,
    insertText: insertText ?? this.insertText,
    natural: natural ?? this.natural,
  );
}

// ---- 网络回填缓存(注音/热度)----
// 补全引擎每查到一个标签的中文名/热度就写入这里,注音层([translationOf])与
// 词条栏([countOf])随后同步反查,免得网络来源的译名/热度显示不出来。

final Map<String, String> _transCache = {};
final Map<String, int> _countCache = {};

/// 反查缓存的版本号:每次回填自增。注音层据此判断「文本没变但翻译到了」
/// 需要重绘(painter 的 shouldRepaint 只比文本,不比缓存内容)。
int _transRev = 0;
int get transCacheRev => _transRev;

/// 多译合一的字符串只留第一段——注音层单行绘制,太长只会画成省略号。
/// 各来源(离线库/wiki 中文名 join/共享翻译库/LLM)在此统一兜底,
/// 离线词库建索引(`TagIndexSpec`)也走这里,免得名单改一处漏一处。
///
/// **只在括号外切**。原先无脑取各分隔符的最小下标,而 Fate 系的作品名自带斜杠,
/// 于是「玉藻前（命运/额外）」被切成「玉藻前（命运」——83 条角色名就这么断在
/// 半括号上。竖线是离线库里 byzod 那半边词表的分隔符,也在名单里。
/// [tag] 给出时用来判断斜杠的身份:标签自身带 `/`(`fate/zero`、`ranma_1/2`、
/// `22/7`、`k/da_(league_of_legends)`)时,译名里的 `/` 是名字的一部分,不是
/// 多译分隔符 —— 照切会把「Fate/Zero」削成「命运」,而 `fate_(series)` 也叫
/// 这个,两个标签的注音就撞了。这类共 135 条。
String? firstTransSegment(String? zh, {String? tag}) {
  if (zh == null) return null;
  final sep = tag != null && tag.contains('/') ? ',，、;；|｜' : ',，、/;；|｜';
  const open = '(（[［【';
  const close = ')）]］】';
  var depth = 0;
  var cut = zh.length;
  for (var i = 0; i < zh.length; i++) {
    final c = zh[i];
    if (open.contains(c)) {
      depth++;
    } else if (close.contains(c)) {
      if (depth > 0) depth--;
    } else if (depth == 0 && sep.contains(c)) {
      cut = i;
      break;
    }
  }
  final first = zh.substring(0, cut).trim();
  return first.isEmpty ? null : first;
}

/// 反查缓存上限。这里只装网络回填 —— 离线词库不进缓存,直接查索引(见
/// [offlineTagMeta])。一次会话回填不过几十上百条,满了整表清空也只是回头再问。
const _metaCap = 20000;

/// 反查缓存的规范键:小写 + 下划线归空格 + 连续空白压成一个。
///
/// **Danbooru 的 `_` 就是空格**,同一个标签两种写法都常见:app 自己的补全插入的是
/// 空格形态(`Suggestion.text` = `tag.replaceAll('_', ' ')`,离线索引建库也走这条),而从
/// Danbooru 复制、或从别处导入的提示词绝大多数是**下划线形态**。
///
/// 2026-08-28 之前这里只做 `trim().toLowerCase()` —— 于是灌进缓存的是
/// `long hair`、查的是 `long_hair`,**下划线写法的提示词一条都命中不了**:
/// 注音层整条空白、词条栏没热度,还会把这些词全都白送去后端问一遍。
/// 连续空白同理(`long   hair` 也查不到)。
String metaKey(String text) => text
    .trim()
    .toLowerCase()
    .replaceAll('_', ' ')
    .replaceAll(RegExp(r'\s+'), ' ');

/// 回填某标签的中文名/热度(键见 [metaKey])。由 `TagCompletion` 与 `TagTranslationService` 调用。
/// 上限防无界增长(清空只影响反查显示,重查询即回填)。
void cacheTagMeta(String text, {String? trans, int? count}) {
  final k = metaKey(text);
  var t = firstTransSegment(trans, tag: k);
  // 译名跟标签**一字不差**就是没翻译,收下等于占坑:`translationOf` 从此返回
  // 非 null,`TagTranslationService.request` 便直接跳过,后端那条路再也够不着
  // 它们。离线库里这样的有 2221 条(`:<`→`:<`、`rwby`→`rwby`、`+++`→`+++`)。
  //
  // 比较**大小写敏感**,别顺手改成 toLowerCase:另有 211 条是刻意排版过的专有
  // 名词——`vocaloid`→`VOCALOID`、`iphone`→`iPhone`、`muv-luv`→`Muv-Luv`,
  // 它们没有中文名,保持原文就是正确答案,忽略大小写会把这批一起误杀。
  if (t != null && t == k) t = null; // k 已是空格形态,见 [metaKey]
  if (t != null) {
    if (_transCache.length > _metaCap) _transCache.clear();
    _transCache[k] = t;
    _transRev++;
  }
  if (count != null && count > 0) {
    if (_countCache.length > _metaCap) _countCache.clear();
    _countCache[k] = count;
  }
}

/// 一次查询的分类结果
class SuggestResult {
  const SuggestResult({
    this.characters = const [],
    this.ocs = const [],
    this.works = const [],
    this.artists = const [],
    this.tags = const [],
  });

  final List<Suggestion> characters;
  final List<Suggestion> ocs;
  final List<Suggestion> works;
  final List<Suggestion> artists;
  final List<Suggestion> tags;

  bool get hasEntities =>
      characters.isNotEmpty ||
      ocs.isNotEmpty ||
      works.isNotEmpty ||
      artists.isNotEmpty;

  bool get isEmpty => tags.isEmpty && !hasEntities;

  int get total =>
      characters.length +
      ocs.length +
      works.length +
      artists.length +
      tags.length;

  /// 横向态排列:实体(画师/角色/OC/作品)优先,后接标签
  /// 全部建议,与两个补全界面同序(自有库在前,见 completion_bar)。
  List<Suggestion> get flat => [
    ...artists,
    ...ocs,
    ...characters,
    ...works,
    ...tags,
  ];
}

/// 热度缩写:1200 → 1.2k,320000 → 320k;<1000 不显示(返回 null)
String? formatCount(int n) {
  if (n < 1000) return null;
  if (n < 10000) return '${(n / 1000).toStringAsFixed(1)}k';
  return '${(n / 1000).round()}k';
}

// ---- 内置词库(占位) ----

/// 离线库查不到时的兜底译名。**只放离线库(`assets/danbooru.tsv`)没有的词** ——
/// `translationOf` 是先查缓存与离线库、都没有才线性扫这里,与库重复的条目永远
/// 轮不到,白扫。(离线库还要开机灌注的年代,与库不一致的会在灌注完成那一刻让注音
/// **跳字**,2026-08-28 清理前实测有 6 条:`red eyes` 红眼→红眼睛、
/// `bad anatomy` 解剖错误→身体结构崩坏、`yuuki asuna` 结城明日奈→亚丝娜…)
/// 留下的这几条是 NAI/SD 的质量词与描述词 —— 它们不是 Danbooru 标签,
/// 词库里天生没有,而几乎每条提示词都会带。
const _tags = <Suggestion>[
  Suggestion(
    text: 'silver hair',
    kind: SuggestionKind.tag,
    trans: '银发',
    count: 210000,
  ),
  Suggestion(
    text: 'silver long hair',
    kind: SuggestionKind.tag,
    trans: '银色长发',
    count: 34000,
  ),
  Suggestion(
    text: 'gothic dress',
    kind: SuggestionKind.tag,
    trans: '哥特连衣裙',
    count: 12000,
  ),
  Suggestion(
    text: 'moonlit rooftop',
    kind: SuggestionKind.tag,
    trans: '月夜屋顶',
    count: 640,
  ),
  Suggestion(
    text: 'cinematic lighting',
    kind: SuggestionKind.tag,
    trans: '电影感光照',
    count: 38000,
  ),
  Suggestion(
    text: 'highly detailed',
    kind: SuggestionKind.tag,
    trans: '高度精细',
    count: 260000,
  ),
  Suggestion(
    text: 'best quality',
    kind: SuggestionKind.tag,
    trans: '最佳画质',
    count: 990000,
  ),
  Suggestion(
    text: 'masterpiece',
    kind: SuggestionKind.tag,
    trans: '杰作',
    count: 1200000,
  ),
];

/// 同 [_tags] 的不变式:只放离线库没有的。库里有 2 万角色,这里只补
/// 词序不同的写法(Danbooru 是 `nagato_yuki`,用户常写 `yuki nagato`)。
const _characters = <Suggestion>[
  Suggestion(
    text: 'yuki nagato',
    kind: SuggestionKind.character,
    trans: '长门有希',
    source: '凉宫春日的忧郁',
    count: 28000,
  ),
];

const _ocs = <Suggestion>[
  Suggestion(
    text: '雪莉',
    kind: SuggestionKind.oc,
    note: '插入为角色配置(正/负两段)',
    trans: '我的 OC',
  ),
];

const _works = <Suggestion>[
  Suggestion(
    text: 'yuru yuri',
    kind: SuggestionKind.work,
    trans: '摇曳百合',
    note: '12 个角色 · 点骰子随机抽取',
    count: 15000,
  ),
  Suggestion(
    text: 'sword art online',
    kind: SuggestionKind.work,
    trans: '刀剑神域',
    note: '48 个角色 · 点骰子随机抽取',
    count: 88000,
  ),
];

bool _hasCjk(String s) => s.runes.any((r) => r >= 0x4E00 && r <= 0x9FFF);

/// 匹配:英文按前缀/子串,中文按译名/来源子串;返回排序权重(越小越靠前,-1=不匹配)
int _rank(Suggestion s, String qLower, String qRaw, bool cjk) {
  if (cjk) {
    if ((s.trans?.contains(qRaw) ?? false)) return 0;
    if ((s.source?.contains(qRaw) ?? false)) return 1;
    return -1;
  }
  final en = s.text.toLowerCase();
  if (en.startsWith(qLower)) return 0;
  if (en.split(' ').any((w) => w.startsWith(qLower))) return 1;
  if (en.contains(qLower)) return 2;
  if (s.trans?.contains(qRaw) ?? false) return 3;
  return -1;
}

List<Suggestion> _filter(List<Suggestion> src, String q) {
  final cjk = _hasCjk(q);
  final qLower = q.toLowerCase();
  final scored = <(int, Suggestion)>[];
  for (final s in src) {
    final r = _rank(s, qLower, q, cjk);
    if (r >= 0) scored.add((r, s));
  }
  scored.sort((a, b) {
    if (a.$1 != b.$1) return a.$1.compareTo(b.$1);
    return b.$2.count.compareTo(a.$2.count); // 同档按热度
  });
  return [for (final e in scored) e.$2];
}

/// 主查询:按四类分别过滤排序。alphabetical=true 时标签改按字母序。
SuggestResult querySuggestions(String query, {bool alphabetical = false}) {
  final q = query.trim();
  if (q.isEmpty) return const SuggestResult();
  var tags = _filter(_tags, q);
  if (alphabetical) {
    tags = [...tags]..sort((a, b) => a.text.compareTo(b.text));
  }
  return SuggestResult(
    characters: _filter(_characters, q),
    ocs: _filter(_ocs, q),
    works: _filter(_works, q),
    tags: tags,
  );
}

// ---- 离线词库 ----

/// 离线词库的同步反查,键是 [metaKey] 形态。由 `LocalTagDb.install` 在开机
/// runApp 之前装上;读不出来时为 null,只剩网络回填与内置兜底。
abstract interface class OfflineTagMeta {
  String? transOf(String key);
  int? countOf(String key);
}

OfflineTagMeta? offlineTagMeta;

/// 补全行要显示的中文:优先用结果自带的译名,缺则反查
/// (wiki/共享库/LLM 的网络回填 + 离线词库)。
///
/// D 站来的行只有 `/api/tags/wiki` 那一路译名,wiki 没写中文别名就一直空着 ——
/// 而同一个标签在离线词库里往往是有中文的,只是没人去查。
/// 反查还捡到 [TagTranslationService] 后来补上的那批:那是异步到货的,
/// 结果快照里不可能有,只能显示时现查。
String? transOf(Suggestion s) {
  final t = s.trans;
  if (t != null && t.isNotEmpty) return t;
  return switch (s.kind) {
    // 画师串 / OC 是本地库实体,名字不是 Danbooru 标签,反查只会串味
    SuggestionKind.artist || SuggestionKind.oc => null,
    _ => translationOf(s.text),
  };
}

/// 供注音流反查某个已确定标签的中文翻译(网络回填缓存 → 离线词库 → 内置兜底)
String? translationOf(String text) {
  final t = metaKey(text);
  final cached = _transCache[t] ?? offlineTagMeta?.transOf(t);
  if (cached != null) return cached;
  for (final s in _tags) {
    if (metaKey(s.text) == t) return s.trans;
  }
  for (final s in _characters) {
    if (metaKey(s.text) == t) return s.trans;
  }
  return null;
}

/// 反查某标签热度(词条栏用),<1000 或未知返回 null
int? countOf(String text) {
  final t = metaKey(text);
  final cached = _countCache[t] ?? offlineTagMeta?.countOf(t);
  if (cached != null && cached >= 1000) return cached;
  for (final s in [..._tags, ..._characters]) {
    if (metaKey(s.text) == t) return s.count >= 1000 ? s.count : null;
  }
  return null;
}

/// 关联标签(占位:静态共现表;正式版接 tagRelated 服务)
const _related = <String, List<String>>{
  'moonlit rooftop': ['full moon', 'city lights', 'night'],
  'silver long hair': ['red eyes', 'hair between eyes', 'sidelocks'],
  'gothic dress': ['frills', 'lace trim', 'ribbon'],
  '1girl': ['solo', 'looking at viewer', 'cowboy shot'],
  'best quality': ['masterpiece', 'highly detailed', 'ultra-detailed'],
  'full moon': ['night sky', 'starry sky', 'cloud'],
  'red eyes': ['glowing eyes', 'slit pupils'],
};

List<String> relatedTags(String text) =>
    _related[text.trim().toLowerCase()] ?? const [];

/// 标签 Wiki 摘要(占位:静态表;正式版接 Danbooru wiki API)
const _wiki = <String, String>{
  'yukata': '日式夏季传统单层和服,窄袖束以 obi 腰带,常与 festival、fireworks、summer 共现。',
  'gothic dress': '哥特风连衣裙,多为黑色蕾丝、荷叶边与束身剪裁,常搭 choker 与十字架。',
  '1girl': '画面中恰有一名女性角色,Danbooru 最核心的人数标签之一。',
  'silver long hair': '银白色过肩长发,常与 red eyes、hair between eyes、sidelocks 搭配。',
  'full moon': '完整满月,多用于夜景 / 星空 / 屋顶等构图。',
};

/// 标签 Wiki 摘要(占位),未知返回 null
String? wikiSummary(String text) => _wiki[text.trim().toLowerCase()];

/// Danbooru wiki 外链(占位跳转用)
String danbooruWikiUrl(String text) =>
    'https://danbooru.donmai.us/wiki_pages/'
    '${text.trim().toLowerCase().replaceAll(' ', '_')}';
