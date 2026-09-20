/// 自定义接口那条的**本地资料**:你自己那份画师串库 / OC 库的预匹配、资料块、
/// 画师串占位符、资源账本,以及查这两个库的工具。
///
/// **全在手机上做,库的内容不出本机。** 原先整库随每轮请求发到 Plana 后端,由后端
/// 匹配、记账、代查 —— 模型用的是你自己的接口,库却传到了云端,这事从没问过用户。
/// 服务端自己的数据(角色索引、tag 百科、公共库)照旧去后端查,发过去的只有查询词,
/// 见 direct_agent.dart。
///
/// 判据与服务端逐条对齐 —— 走后端那条用的是服务端那份,同一句话两条路给的块得一样:
///   · 预匹配   router._build_web_prequery_context 的画师串 / OC 两段
///   · 占位符   artist_placeholder.py(declare_block / expand_text / names_in_reply)
///   · 账本     router.merge_resources、_resource_still_in_use、_heal_remembered_artists
///   · 条件段   router.detect_prompt_modes
///   · 工具     tools/knowledge.py 的 search_artist、random_artist,search_character 的 OC 那半
/// 改一边记得改另一边。
library;

import 'dart:collection';
import 'dart:math';

import 'package:unorm_dart/unorm_dart.dart' as unorm;

// ---- 规范化 ----

final _punctOrSpace = RegExp(r'[\p{P}\s]', unicode: true);

/// 名字比对用的规范化:NFKC、小写、去掉标点和空白(服务端 `normalize_oc_text`)。
/// 库里存 DeepSeek,用户写 deepseek、deep seek 都要对得上。
String normalizeName(String s) =>
    unorm.nfkc(s).toLowerCase().replaceAll(_punctOrSpace, '');

/// 按码点数长度 —— 与服务端 `len()` 同口径,名字里带表情时和 UTF-16 长度不一样。
int _len(String s) => s.runes.length;

/// 按 [key] 从大到小排,一样大的保持原来的先后(Dart 的 sort 不保证稳定)。
List<T> _largestFirst<T>(List<T> items, int Function(T) key) {
  final indexed = [for (var i = 0; i < items.length; i++) (i, items[i])];
  indexed.sort((a, b) {
    final c = key(b.$2).compareTo(key(a.$2));
    return c != 0 ? c : a.$1.compareTo(b.$1);
  });
  return [for (final e in indexed) e.$2];
}

// ---- 库条目 ----

/// 本地库里的一条画师串。
class LibArtist {
  const LibArtist({required this.id, required this.name, required this.prompt});

  final String id;
  final String name;

  /// 完整画师串。
  final String prompt;

  /// 块里、占位符里用的名字:有编号用编号。
  String get label => id.isNotEmpty ? id : name;
}

/// 本地库里的一个 OC。
class LibOc {
  const LibOc({
    required this.enName,
    required this.zhName,
    required this.aliases,
    required this.tagGroup,
  });

  final String enName;
  final String zhName;
  final List<String> aliases;
  final String tagGroup;
}

String _field(Map<String, dynamic> m, List<String> keys) {
  for (final k in keys) {
    final v = m[k];
    if (v != null && '$v'.isNotEmpty) return '$v'.trim();
  }
  return '';
}

/// 助手页拼好的画师串库(`{'id','name','prompt'}`)→ 条目。没内容的丢掉、重复的去掉
/// (服务端 `_load_artists_from_web` + `_dedupe_artists`)。
List<LibArtist> libArtistsOf(List<Map<String, dynamic>> raw) {
  final seen = <String>{};
  final out = <LibArtist>[];
  for (final m in raw) {
    final id = _field(m, const ['id', 'name']);
    final name = _field(m, const ['name']);
    final prompt = _field(m, const ['prompt', 'artist_string']);
    if ((id.isEmpty && name.isEmpty) || prompt.isEmpty) continue;
    final a = LibArtist(
      id: id.isNotEmpty ? id : name,
      name: name.isNotEmpty ? name : id,
      prompt: prompt,
    );
    if (seen.add(
      '${a.id.toUpperCase()}|${a.name.toUpperCase()}|${a.prompt}',
    )) {
      out.add(a);
    }
  }
  return out;
}

/// 助手页拼好的 OC 库(`{'en_name','zh_name','zh_aliases','tag_group'}`)→ 条目
/// (服务端 `_load_ocs_from_web` + `_dedupe_ocs`)。
List<LibOc> libOcsOf(List<Map<String, dynamic>> raw) {
  final seen = <String>{};
  final out = <LibOc>[];
  for (final m in raw) {
    final name = _field(m, const ['name', 'zh_name', 'id']);
    final en = _field(m, const ['en_name', 'id']);
    final zh = _field(m, const ['zh_name', 'zhName']);
    final tags = _field(m, const ['tag_group', 'positive']);
    final enName = en.isNotEmpty ? en : name;
    final zhName = zh.isNotEmpty ? zh : name;
    if ((enName.isEmpty && zhName.isEmpty) || tags.isEmpty) continue;
    final rawAliases = m['zh_aliases'] ?? m['aliases'];
    final oc = LibOc(
      enName: enName,
      zhName: zhName,
      aliases: [
        if (rawAliases is List)
          for (final a in rawAliases)
            if (a != null && '$a'.trim().isNotEmpty) '$a',
      ],
      tagGroup: tags,
    );
    if (seen.add('${oc.enName.toLowerCase()}|${oc.zhName}|${oc.tagGroup}')) {
      out.add(oc);
    }
  }
  return out;
}

// ---- 预匹配 ----

final _artistIdRe = RegExp(r'(?<![A-Za-z])([A-Za-z])(\d{1,2})(?!\d)');

/// 一块最多几条。
const _kBlockMax = 10;

/// 这句话点到的画师串 → [(块里的名字, 完整串)],按块里的顺序。
///
/// 三条路,与服务端同序:编号(A1 / b12)、名字(规范化后至少 2 个字,越长越靠前)、
/// 「随机画师串」。最多 10 条。
List<(String, String)> matchArtists(
  String text,
  List<LibArtist> artists, {
  Random? random,
}) {
  final out = <(String, String)>[];
  final seen = <String>{};
  for (final m in _artistIdRe.allMatches(text)) {
    final id = '${m[1]!.toUpperCase()}${m[2]}';
    for (final a in artists) {
      if (a.id.toUpperCase() != id && a.name.toUpperCase() != id) continue;
      if (!seen.add(a.label.toUpperCase())) continue;
      out.add((a.label, a.prompt));
      break;
    }
  }
  final textNorm = normalizeName(text);
  final byName = <(int, String, String)>[];
  for (final a in artists) {
    if (a.name.isEmpty || seen.contains(a.label.toUpperCase())) continue;
    final n = normalizeName(a.name);
    if (_len(n) < 2 || !textNorm.contains(n)) continue;
    seen.add(a.label.toUpperCase());
    byName.add((_len(n), a.name, a.prompt));
  }
  for (final (_, name, prompt) in _largestFirst(byName, (e) => e.$1)) {
    out.add((name, prompt));
  }
  if (text.contains('随机画师串') && artists.isNotEmpty) {
    final a = artists[(random ?? Random()).nextInt(artists.length)];
    if (!seen.contains(a.label.toUpperCase())) out.add((a.label, a.prompt));
  }
  return out.take(_kBlockMax).toList();
}

/// 这句话点到的 OC → [(命中的名字、以顿号连起来, tag 组)]。中文名、别名、去掉 `OC_`
/// 的键名都认,命中的名字越长越靠前,最多 10 个。
List<(String, String)> matchOcs(String text, List<LibOc> ocs) {
  final textNorm = normalizeName(text);
  final hits = <(int, String, String)>[];
  for (final oc in ocs) {
    final bare = oc.enName.toLowerCase().startsWith('oc_')
        ? oc.enName.substring(3)
        : oc.enName;
    final names = [
      for (final n in [oc.zhName, ...oc.aliases, bare])
        if (n.trim().isNotEmpty) n.trim(),
    ];
    final hit = [
      for (final n in names)
        if (normalizeName(n) case final k when k.isNotEmpty && textNorm.contains(k))
          n,
    ];
    if (hit.isEmpty) continue;
    hits.add((
      hit.map(_len).reduce(max),
      LinkedHashSet.of(hit).join('、'),
      oc.tagGroup,
    ));
  }
  return [
    for (final (_, label, tags) in _largestFirst(
      hits,
      (e) => e.$1,
    ).take(_kBlockMax))
      (label, tags),
  ];
}

// ---- 资料块 ----

const kArtistBlock = '[画师串]';
const kOcBlock = '[OC 角色]';
const kRoleBlock = '[角色候选]';

/// [画师串] 块头下面那行说明,与服务端 `artist_placeholder.BLOCK_NOTE` 逐字一致。
const kArtistBlockNote =
    '直接写占位符，放在 positive 最前面，出图时换成完整画师串；'
    '除非用户要求调整或询问画师串内容，不要调 search_artist 查它';

/// 环境块里的某一块(带块头),没有就是空串。只按三个块头切,块里的空行不算分界
/// (服务端 `env_blocks.split_blocks`)。
String pickBlock(String env, String header) {
  final out = <String>[];
  var inside = false;
  for (final line in env.split('\n')) {
    final t = line.trim();
    if (t == kArtistBlock || t == kOcBlock || t == kRoleBlock) {
      inside = t == header;
      if (inside) out.add(t);
    } else if (inside) {
      out.add(line);
    }
  }
  return out.join('\n').trimRight();
}

// ---- 画师串占位符 ----

/// 画师串占位符 `__ARTIST_A1__`。写歪了也认:大小写、两头多了空格。
final artistTokenRe = RegExp(
  r'__\s*ARTIST\s*_\s*([^\s,，_]+(?:_[^\s,，_]+)*)\s*__',
  caseSensitive: false,
);

/// 名字 → 占位符主体:全角半角统一,空白和逗号换成下划线,连续下划线并成一个。
String artistTokenBody(String name) => unorm
    .nfkc(name)
    .trim()
    .replaceAll(RegExp(r'[\s,，]+'), '_')
    .replaceAll(RegExp(r'_{2,}'), '_')
    .replaceAll(RegExp(r'^_+|_+$'), '');

String artistPlaceholder(String name) => '__ARTIST_${artistTokenBody(name)}__';

String _tokenKey(String body) => artistTokenBody(body).toLowerCase();

typedef ArtistHit = ({String name, String content});

/// 这一轮的占位符映射:主体 → (显示名, 完整画师串)。同名先到先得。
class ArtistPlan {
  final _entries = <String, ArtistHit>{};

  bool get isEmpty => _entries.isEmpty;

  /// 记一条,返回它的占位符。
  String add(String name, String content) {
    final hit = _entries.putIfAbsent(
      _tokenKey(name),
      () => (name: name, content: content),
    );
    return artistPlaceholder(hit.name);
  }

  ArtistHit? get(String body) => _entries[_tokenKey(body)];

  /// 占位符 → 完整内容。折历史和画布用,调试记录里也记这份。
  Map<String, String> get tokens => {
    for (final e in _entries.values) artistPlaceholder(e.name): e.content,
  };
}

/// 工具查到的画师串记进映射:模型照着返回的 placeholder 写,出图前要认得出来。
void rememberToolArtists(ArtistPlan plan, Object? result) {
  if (result is! List) return;
  for (final r in result) {
    if (r is! Map) continue;
    final prompt = '${r['prompt'] ?? ''}';
    final id = '${r['id'] ?? ''}'.trim();
    final name = id.isNotEmpty ? id : '${r['name'] ?? ''}'.trim();
    if (name.isNotEmpty && prompt.trim().isNotEmpty) plan.add(name, prompt);
  }
}

// ---- 一轮的预匹配 ----

/// 这一轮的本地预匹配结果。
class LocalPrequery {
  const LocalPrequery({
    required this.block,
    required this.thisTurn,
    required this.plan,
  });

  /// 附在用户消息后面的资料块:画师串是占位符,OC 是完整 tag 组,角色候选是服务端给的。
  final String block;

  /// 本轮命中的(完整内容)。收尾记账只收里面的画师串(见 [mergeLedger])。
  final Map<String, Map<String, String>> thisTurn;

  final ArtistPlan plan;
}

/// 拼这一轮的资料块。
///
/// 本轮没点到画师串,把账本里记着的补上(预匹配逐条消息做,用户这轮没再提「A1」块就不出现,
/// 出处断在那儿)。OC 不记账,只出本轮点到的。[useLibrary] 为 false(资料库范围「不使用」)
/// 时不匹配也不补,但记着的画师串照样进映射 —— 历史里的完整串还得折回占位符。
///
/// [publicArtists] / [publicOcs] 是服务端公共库命中的,排在本地的后面、同名以本地为准;
/// [roleBlock] 是服务端给的 [角色候选] 块,原样接在最后。
LocalPrequery buildLocalPrequery({
  required String text,
  required List<LibArtist> artists,
  required List<LibOc> ocs,
  required Map<String, Map<String, String>> remembered,
  bool useLibrary = true,
  Map<String, String> publicArtists = const {},
  Map<String, String> publicOcs = const {},
  String roleBlock = '',
  Random? random,
}) {
  final artistHits = <String, String>{};
  final ocHits = <String, String>{};
  if (useLibrary) {
    for (final (name, content) in [
      ...matchArtists(text, artists, random: random),
      for (final e in publicArtists.entries) (e.key, e.value),
    ]) {
      if (artistHits.length >= _kBlockMax) break;
      final upper = name.toUpperCase();
      if (artistHits.keys.any((k) => k.toUpperCase() == upper)) continue;
      artistHits[name] = content;
    }
    for (final (label, tags) in [
      ...matchOcs(text, ocs),
      for (final e in publicOcs.entries) (e.key, e.value),
    ]) {
      if (ocHits.length >= _kBlockMax) break;
      ocHits.putIfAbsent(label, () => tags);
    }
  }
  final artistEntries = artistHits.isEmpty && useLibrary
      ? remembered['artist'] ?? const <String, String>{}
      : artistHits;

  final plan = ArtistPlan();
  final artistLines = [
    for (final e in artistEntries.entries)
      if (e.key.isNotEmpty && e.value.isNotEmpty)
        '${e.key} → ${plan.add(e.key, e.value)}',
  ];
  for (final e in (remembered['artist'] ?? const <String, String>{}).entries) {
    if (e.key.isNotEmpty && e.value.isNotEmpty) plan.add(e.key, e.value);
  }
  final ocLines = [
    for (final e in ocHits.entries)
      if (e.key.isNotEmpty && e.value.isNotEmpty) '${e.key} → ${e.value}',
  ];
  return LocalPrequery(
    block: [
      if (artistLines.isNotEmpty)
        [kArtistBlock, kArtistBlockNote, ...artistLines].join('\n'),
      if (ocLines.isNotEmpty) [kOcBlock, ...ocLines].join('\n'),
      if (roleBlock.trim().isNotEmpty) roleBlock.trim(),
    ].join('\n\n'),
    thisTurn: {'artist': artistHits, 'oc': ocHits},
    plan: plan,
  );
}

/// 账本里只记下了第一行的多行画师串,按本地库里同名那条补全
/// (服务端 `_heal_remembered_artists`,那边以前按行解析,`<artist>` 起头的只记下了第一行)。
Map<String, Map<String, String>> healRememberedArtists(
  Map<String, Map<String, String>> remembered,
  List<LibArtist> artists,
) {
  final slot = remembered['artist'];
  if (slot == null || slot.isEmpty) return remembered;
  final library = <String, String>{};
  for (final a in artists) {
    if (!a.prompt.contains('\n')) continue;
    for (final n in [a.id, a.name]) {
      if (n.trim().isNotEmpty) {
        library.putIfAbsent(n.trim().toUpperCase(), () => a.prompt);
      }
    }
  }
  if (library.isEmpty) return remembered;
  return {
    ...remembered,
    'artist': {
      for (final e in slot.entries)
        e.key: switch (library[e.key.trim().toUpperCase()]) {
          final full?
              when e.value.isNotEmpty &&
                  full.split('\n').first.trim() == e.value.trim() =>
            full,
          _ => e.value,
        },
    },
  };
}

// ---- 条件段 ----

final _comicRe = RegExp(
  r'漫画|分镜|条漫|连环画|格漫|分格|多格|[两二三四五六七八九十\d]+\s*格'
  r'|4koma|koma|storyboard|comic'
  r'|the page is divided into|\bpanels?\b',
  caseSensitive: false,
);

/// 本轮命中的条件段模式(服务端 `detect_prompt_modes`):任一段文字像在画漫画就是 comic。
/// 宁松勿严 —— 漏判是把漫画画成单图,误判只是多发一段。
List<String> detectPromptModes(Iterable<String> texts) =>
    texts.any(_comicRe.hasMatch) ? const ['comic'] : const [];

// ---- 还原 ----

typedef ArtistResolver = ArtistHit? Function(String body);

/// 占位符主体 → (显示名, 完整串)。先查本轮映射,查不到再查本地库;库里查到的顺手记进映射。
ArtistResolver artistResolver(ArtistPlan plan, List<LibArtist> artists) {
  Map<String, ArtistHit>? library;
  return (body) {
    final hit = plan.get(body);
    if (hit != null) return hit;
    if (library == null) {
      final lib = <String, ArtistHit>{};
      for (final a in artists) {
        for (final n in [a.id, a.name]) {
          if (n.trim().isEmpty) continue;
          lib.putIfAbsent(
            _tokenKey(n),
            () => (name: a.name.isNotEmpty ? a.name : n, content: a.prompt),
          );
        }
      }
      library = lib;
    }
    final found = library![_tokenKey(body)];
    if (found != null) plan.add(found.name, found.content);
    return found;
  };
}

const _keep = '\u0000'; // 占位:这里要填回第 n 条完整内容
const _drop = '\u0001'; // 占位:这里删掉了一个占位符
final _dropRe = RegExp(r'\s*\x01\s*,\s*|\s*,\s*\x01|\x01');
final _keepRe = RegExp(r'\x00(\d+)\x00');

/// 占位符删掉之后留下的空壳:`1.2::::`、`{}`、`[]`
final _emptyWrap = RegExp(r'-?\d*\.?\d+::\s*::|\{\s*\}|\[\s*\]');

String _dropMarks(String s) {
  final cleaned = s.replaceAll(_dropRe, '');
  final wrapped = cleaned.replaceAll(_emptyWrap, _drop);
  return wrapped != cleaned ? wrapped.replaceAll(_dropRe, '') : cleaned;
}

/// 一段 tag 里的占位符 → 完整画师串(服务端 `expand_text`)。
///
///   · 认不出的删掉(编号是模型编的,或者库里已经没有了);
///   · 同一个占位符写了两遍,第二遍起删掉;
///   · 完整内容已经在这段里了(模型自己又抄了一遍)只删占位符。
///
/// 填回去的内容**逐字**不动:先删、收拾删出来的逗号和空壳,最后才把内容填进去。
({String text, List<String> used, List<String> notes}) expandArtistText(
  String text,
  ArtistResolver resolve,
) {
  if (text.isEmpty || !artistTokenRe.hasMatch(text)) {
    return (text: text, used: const [], notes: const []);
  }
  final used = <String>[];
  final notes = <String>[];
  final seen = <String>{};
  final fills = <String>[];
  var out = text.replaceAllMapped(artistTokenRe, (m) {
    final body = m[1]!;
    final hit = resolve(body);
    if (hit == null) {
      notes.add('${m[0]} 在资料库里找不到，已删掉');
      return _drop;
    }
    if (!seen.add(_tokenKey(body))) return _drop;
    if (text.contains(hit.content)) {
      notes.add('${m[0]} 的完整内容已经写在里面了，占位符删掉');
      return _drop;
    }
    used.add(hit.name);
    fills.add(hit.content);
    return '$_keep${fills.length - 1}$_keep';
  });
  if (out.contains(_drop)) out = _dropMarks(out).trim();
  out = out.replaceAllMapped(_keepRe, (m) => fills[int.parse(m[1]!)]);
  return (text: out, used: used, notes: notes);
}

/// 画面里要换占位符的那几段文字:正负向词,以及每个角色的正负向词。
Iterable<String> drawTexts(Map<String, dynamic> draw) sync* {
  for (final k in const ['positive', 'negative']) {
    if (draw[k] != null) yield '${draw[k]}';
  }
  if (draw['characters'] case final List chars) {
    for (final c in chars) {
      if (c is! Map) continue;
      for (final k in const ['positive', 'negative']) {
        if (c[k] != null) yield '${c[k]}';
      }
    }
  }
}

/// 画面里各处的占位符都换回完整画师串。没有占位符原样返回(同一个对象)。
Map<String, dynamic>? expandDraw(
  Map<String, dynamic>? draw,
  ArtistResolver resolve,
) {
  if (draw == null || !drawTexts(draw).any(artistTokenRe.hasMatch)) {
    return draw;
  }
  String fix(Object? v) => expandArtistText('$v', resolve).text;
  return {
    ...draw,
    if (draw['positive'] != null) 'positive': fix(draw['positive']),
    if (draw['negative'] != null) 'negative': fix(draw['negative']),
    if (draw['characters'] is List)
      'characters': [
        for (final c in draw['characters'] as List)
          c is Map<String, dynamic>
              ? {
                  ...c,
                  if (c['positive'] != null) 'positive': fix(c['positive']),
                  if (c['negative'] != null) 'negative': fix(c['negative']),
                }
              : c,
      ],
  };
}

/// 给用户看的正文里出现的占位符换成名字(`A1`),不换成一长串 tag。
String namesInReply(String text, ArtistResolver resolve) => text.replaceAllMapped(
  artistTokenRe,
  (m) => resolve(m[1]!)?.name ?? m[1]!,
);

// ---- 账本 ----

final _wPrefix = RegExp(r'^\s*-?\d*\.?\d+\s*::'); // 1.2::tag:: / -1::tag:: / .8::tag::
final _wSuffix = RegExp(r':\s*-?\d*\.?\d+\s*\)?$'); // (tag:1.2)
final _spaces = RegExp(r'\s+');

// 切 tag:英文 / 中文逗号、换行,以及句末标点后面跟空白(「artist:a. A girl…」)
final _tagSplit = RegExp(r'[,，\n\r]|(?<=[.!?。！？])\s+');
final _wAny = RegExp(r'-?\d*\.?\d+\s*::');
final _wSd = RegExp(r':\s*-?\d*\.?\d+\s*\)');
final _artistPrefix = RegExp(r'^artist\s*:\s*');
const _tagEdges = '{}[]() \t.。!?！？';

String _stripChars(String s, String chars) {
  var start = 0;
  var end = s.length;
  while (start < end && chars.contains(s[start])) {
    start++;
  }
  while (end > start && chars.contains(s[end - 1])) {
    end--;
  }
  return s.substring(start, end);
}

/// 一枚 tag 规范化成比较用的样子(服务端 `_norm_tag`):权重语法、全角半角、大小写、
/// 下划线和空格、转义括号、`artist:` 前缀、句末标点,这些差别都不算换了一枚 tag。
String _normTag(String raw) {
  var t = unorm.nfkc(raw).trim();
  t = t.replaceAll(r'\(', '(').replaceAll(r'\)', ')');
  t = t.replaceFirst(_wPrefix, '').replaceAll('::', '');
  t = t.replaceFirst(_wSuffix, '');
  t = _stripChars(t, _tagEdges).replaceAll('_', ' ');
  t = t.replaceAll(_spaces, ' ').trim().toLowerCase();
  return t.replaceFirst(_artistPrefix, '');
}

Set<String> _bareTags(String text) => {
  for (final raw in text.split(_tagSplit))
    if (_normTag(raw) case final t when t.isNotEmpty) t,
};

/// 整段提示词规范化,给 [_phraseIn] 用:权重语法抹掉,括号本身留着(服务端 `_norm_text`)。
String _normText(String text) {
  var t = unorm.nfkc(text);
  t = t.replaceAll(r'\(', '(').replaceAll(r'\)', ')');
  t = t.replaceAll(_wAny, ' ').replaceAll('::', ' ');
  t = t.replaceAll(_wSd, ')');
  t = t.replaceAll(RegExp(r'[{}\[\]]'), ' ').replaceAll('_', ' ');
  return t.replaceAll(_spaces, ' ').toLowerCase();
}

/// 规范化后的 tag 作为完整词组出现在整段文字里。英文按词边界认,中文照子串认。
bool _phraseIn(String tag, String text) {
  if (tag.isEmpty) return false;
  if (tag.codeUnits.every((c) => c < 128)) {
    return RegExp(
      '(?<![a-z0-9])${RegExp.escape(tag)}(?![a-z0-9])',
    ).hasMatch(text);
  }
  return text.contains(tag);
}

/// 这轮实际发出的画面里还有没有这份资源(服务端 `_resource_still_in_use`)。
///
/// 整串原样在里面就算在用;否则按 tag 比,规范化后逐枚比、比不上的再看有没有作为词组
/// 写进句子里,命中 ≥2 枚算在用(只有 1 枚的 ≥1)。故意偏松:误留只是多发一个块,
/// 误删则下一轮又得重新认领。
bool resourceStillInUse(String value, Map<String, dynamic> spec) {
  final v = value.trim();
  final texts = [
    '${spec['positive'] ?? ''}',
    if (spec['characters'] case final List chars)
      for (final c in chars)
        if (c is Map) '${c['positive'] ?? ''}',
  ];
  if (v.isNotEmpty && texts.any((t) => t.contains(v))) return true;
  final want = _bareTags(v);
  if (want.isEmpty) return false;
  final have = {for (final t in texts) ..._bareTags(t)};
  final joined = texts.map(_normText).join(' , ');
  final hits = want
      .where((w) => have.contains(w) || _phraseIn(w, joined))
      .length;
  return hits >= min(2, want.length);
}

/// 收尾记账:本轮命中的 ∪ 上轮记着的,再按「还在不在这幅画里」筛一遍(服务端 `merge_resources`)。
/// [spec] 为 null(这轮没出图)时不筛 —— 没出图不代表用户放弃了这套画风。
Map<String, Map<String, String>> mergeLedger(
  Map<String, Map<String, String>> remembered,
  Map<String, Map<String, String>> thisTurn,
  Map<String, dynamic>? spec,
) {
  final out = <String, Map<String, String>>{};
  // 只记画师串(服务端 RESOURCE_KINDS)。OC 2026-09-19 起不记账,只活在点到它的那一轮;
  // 旧账里的 oc 到这儿就丢。
  for (final kind in const ['artist']) {
    final slot = {...?remembered[kind], ...?thisTurn[kind]};
    if (spec != null) slot.removeWhere((_, v) => !resourceStillInUse(v, spec));
    if (slot.isNotEmpty) out[kind] = slot;
  }
  return out;
}

// ---- 查本地库的工具 ----

/// 工具返回里的一条画师串,字段与服务端 `schemas.Artist` 一致。
Map<String, dynamic> artistToolEntry(LibArtist a) => {
  'id': a.id,
  'name': a.name,
  'prompt': a.prompt,
  'placeholder': artistPlaceholder(a.label),
  'description': null,
};

List<String> _stringList(Object? v) => switch (v) {
  final List l => [
    for (final e in l)
      if (e != null && '$e'.trim().isNotEmpty) '$e'.trim(),
  ],
  final String s when s.trim().isNotEmpty => [s.trim()],
  _ => const [],
};

/// 工具参数里的整数,模型写成字符串也认。
int intArg(Object? v, int fallback) => switch (v) {
  final num n => n.toInt(),
  final String s => int.tryParse(s.trim()) ?? fallback,
  _ => fallback,
};

/// search_artist 查本地库:按编号列表,或者按关键词(名字和画师串里找)。
List<Map<String, dynamic>> searchLocalArtists(
  List<LibArtist> artists,
  Map<String, dynamic> args,
) {
  final ids = {
    for (final i in _stringList(args['artist_ids'])) i.toUpperCase(),
  };
  if (ids.isNotEmpty) {
    return [
      for (final a in artists)
        if (ids.contains(a.id.toUpperCase()) ||
            ids.contains(a.name.toUpperCase()))
          artistToolEntry(a),
    ];
  }
  final k = '${args['keyword'] ?? ''}'.trim().toLowerCase();
  if (k.isEmpty) return const [];
  return [
    for (final a in artists)
      if ('${a.name} ${a.prompt}'.toLowerCase().contains(k)) artistToolEntry(a),
  ];
}

/// search_character 的 OC 那半,查本地库。角色库那半在服务端,由调用方查了接在后面。
List<Map<String, dynamic>> searchLocalOcs(
  List<LibOc> ocs,
  Map<String, dynamic> args,
) {
  final q = normalizeName('${args['query'] ?? ''}');
  if (q.isEmpty) return const [];
  return [
    for (final oc in ocs)
      if (normalizeName(oc.enName).contains(q) ||
          normalizeName(oc.zhName).contains(q) ||
          oc.aliases.any((a) => normalizeName(a).contains(q)))
        {
          'name': oc.enName,
          'zh_aliases': [if (oc.zhName.isNotEmpty) oc.zhName, ...oc.aliases],
          'origin_en': null,
          'origin_zh': const <String>[],
          'tags': oc.tagGroup,
          'source': 'oc',
          'wiki': '',
          'post_count': 0,
        },
  ];
}
