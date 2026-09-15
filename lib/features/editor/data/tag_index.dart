import 'dart:convert';
import 'dart:typed_data';

import '../../../core/util/prompt_tokens.dart';
import 'suggestions.dart';

/// 离线词库索引:构建期由 [kTagTsv] 编出来的一张二进制表([kTagIndexAsset]),
/// 运行时拿到字节就能查 —— 不解析、不灌注,也不在 Dart 堆里建对象。
///
/// 早先是开机读 TSV → 后台 isolate 解析 9 万行 → 主线程把 11 万条灌进反查缓存。
/// 灌注那一遍在手机上占主线程一两秒;解析虽在后台 isolate,可它与主 isolate
/// 共用一个堆,狂分配触发的 GC 会把主线程一起停住 —— 开机那一小段掉帧就是这么来的。
///
/// 纯 Dart(不 import Flutter),`tool/build_tag_index.dart` 直接 `dart run`。
/// 改了 TSV 或建库口径要重跑它,`test/tag_index_test.dart` 会校验进包的文件是否同步。
///
/// 格式(小端,偏移都从文件头算起):
/// ```
/// 头部   magic 'PTIX' | 版本 | 条目段 | 条目数 | 键段 | 哈希表 | 槽数 | 文件总长
/// 条目段 按热度降序:u16+标签 | u16+首段译名 | u32 热度 | u16+别名(逗号连)
/// 键段   u16+键 | u32 注音条目 | u16 译名字节数 | u32 帖子数条目 | u32 角色条目
/// 哈希表 u32 × 槽数(2 的幂),存键记录偏移,0 为空;FNV-1a + 线性探测
/// ```
/// 三种口径共用一张表:同一个串可能既是注音键又是清洗键,记录里哪个口径的条目
/// 偏移为 0,就是这个口径下没有它。
const kTagIndexAsset = 'assets/danbooru.tagidx';

/// 索引的源数据(不进包)。行格式(tab 分隔):
/// `tag<TAB>post_count<TAB>中文<TAB>alias1,alias2<TAB>category`,已按热度降序。
const kTagTsv = 'assets/danbooru.tsv';

const _magic = 0x58495450; // 'PTIX'
const _version = 1;
const _headerSize = 32;

/// 清洗结果与「下划线换空格」对不上的标签:带括号、方括号、花括号或冒号的。
final _reOddTag = RegExp(r'[()\[\]{}:]');

/// 一枚命中的角色标签。[tag] 是词库正名(下划线形式),[zh] 可空。
typedef CharacterTag = ({String tag, String? zh, int count});

/// 词库一行。热度 <50 的冷门行建库时就滤掉了。
typedef TagRow = ({
  String tag,
  int count,
  String? zh,
  List<String> aliases,
  bool isChar,
});

/// 建库口径:TSV → 三张「键 → 条目」表。[encode] 只是把它原样落盘,
/// 测试也拿它当读取端的对照。
///
/// 三张表同一条规矩:**正名优先,撞车先到先得** —— 词库按热度降序,
/// 赢的是更热门的那行。
class TagIndexSpec {
  TagIndexSpec.fromTsv(String raw) : rows = _parse(raw) {
    // 注音 / 热度。键跟反查那头同走 [metaKey]:下划线归空格、大小写与连续空白归一。
    for (var i = 0; i < rows.length; i++) {
      metaRow.putIfAbsent(metaKey(rows[i].tag.replaceAll('_', ' ')), () => i);
    }
    // 别名是同一个标签的另一种写法 —— 旧名、拼写变体、俗称(`hires`/`high res`
    // →highres、`1girls`→1girl、`oppai`/`tits`→breasts),译名和热度跟着正名走。
    // 这些写法在真实提示词里极常见,全库能这么捡回两万多条。
    for (var i = 0; i < rows.length; i++) {
      for (final a in rows[i].aliases) {
        metaRow.putIfAbsent(metaKey(a), () => i);
      }
    }

    // 帖子数与角色:查询那头的词是 [cleanPromptToken] 清洗过的(`ganyu_(genshin_impact)`
    // 与 `ganyu (genshin impact)` 都归到 `ganyu genshin impact`),键也照此清洗。
    // 多数行的清洗结果就是下划线换空格,只有带括号 / 冒号的才真要跑一遍正则。
    for (var i = 0; i < rows.length; i++) {
      final r = rows[i];
      final k = _reOddTag.hasMatch(r.tag)
          ? cleanPromptToken(r.tag)
          : r.tag.replaceAll('_', ' ');
      if (k.isNotEmpty) postRow.putIfAbsent(k, () => i);
      if (r.isChar) charRow.putIfAbsent(cleanPromptToken(r.tag), () => i);
    }
    for (var i = 0; i < rows.length; i++) {
      final r = rows[i];
      for (final a in r.aliases) {
        final k = a.contains('(') || a.contains(':')
            ? cleanPromptToken(a)
            : a.replaceAll('_', ' ');
        if (k.isNotEmpty) postRow.putIfAbsent(k, () => i);
        // 别名遍:`reimu_hakurei` 也该认出博丽灵梦
        if (r.isChar) charRow.putIfAbsent(cleanPromptToken(a), () => i);
      }
    }
  }

  final List<TagRow> rows;

  /// [metaKey] 口径 → 条目下标。注音层 / 词条栏的同步反查。
  final metaRow = <String, int>{};

  /// [cleanPromptToken] 口径 → 条目下标。图库归类掂量词的分量用的帖子数。
  final postRow = <String, int>{};

  /// [cleanPromptToken] 口径 → 角色条目下标。图库按角色归类。
  final charRow = <String, int>{};

  /// 注音键 [key] 该显示的译名。
  ///
  /// 同一个条目的译名按键再切一次:斜杠算不算分隔符要看**键**带不带斜杠
  /// (见 [firstTransSegment]),别名与正名不一定一样。结果总是条目首段译名的前缀,
  /// 所以索引里只记字节数。
  String? transOf(String key) {
    final i = metaRow[key];
    if (i == null) return null;
    final t = firstTransSegment(rows[i].zh, tag: key);
    return t == key ? null : t; // 同 [cacheTagMeta]:原样透传 = 没翻译
  }

  static List<TagRow> _parse(String raw) {
    final rows = <TagRow>[];
    for (final line in const LineSplitter().convert(raw)) {
      if (line.isEmpty) continue;
      final f = line.split('\t');
      if (f.length < 2) continue;
      final count = int.tryParse(f[1]) ?? 0;
      if (count < 50) continue; // 滤冷门(与 web <50 剔除一致)
      rows.add((
        tag: f[0],
        count: count,
        zh: firstTransSegment(
          (f.length > 2 && f[2].isNotEmpty) ? f[2] : null,
          tag: f[0],
        ),
        aliases: (f.length > 3 && f[3].isNotEmpty)
            ? [
                for (final s in f[3].split(','))
                  if (s.isNotEmpty && !s.startsWith('/')) s, // 去掉 /lh 之类快捷别名
              ]
            : const <String>[],
        // 第 5 列 category 目前只填了 4(角色),其余留空 = 未定类,不是「普通标签」
        isChar: f.length > 4 && f[4] == '4',
      ));
    }
    return rows;
  }

  Uint8List encode() {
    final w = _Writer()..zeros(_headerSize);
    final entriesOff = w.length;
    final rowAt = List<int>.filled(rows.length, 0);
    for (var i = 0; i < rows.length; i++) {
      final r = rows[i];
      rowAt[i] = w.length;
      w
        ..str16(r.tag)
        ..str16(r.zh ?? '')
        ..u32(r.count)
        ..str16(r.aliases.join(','));
    }

    final keysOff = w.length;
    final keys = {...metaRow.keys, ...postRow.keys, ...charRow.keys};
    final recAt = <int>[];
    final hashes = <int>[];
    for (final k in keys) {
      final kb = utf8.encode(k);
      recAt.add(w.length);
      hashes.add(_fnv1a(kb));
      final meta = metaRow[k];
      final trans = transOf(k);
      if (trans != null && !rows[meta!].zh!.startsWith(trans)) {
        throw StateError('译名不是首段译名的前缀:$k');
      }
      final post = postRow[k];
      final char = charRow[k];
      w
        ..u16(kb.length)
        ..bytes(kb)
        ..u32(meta == null ? 0 : rowAt[meta])
        ..u16(trans == null ? 0 : utf8.encode(trans).length)
        ..u32(post == null ? 0 : rowAt[post])
        ..u32(char == null ? 0 : rowAt[char]);
    }

    // 负载不超过 3/4,线性探测平均一两次就中
    var slots = 1;
    while (slots * 3 < keys.length * 4) {
      slots <<= 1;
    }
    final table = Uint32List(slots);
    for (var i = 0; i < recAt.length; i++) {
      var s = hashes[i] & (slots - 1);
      while (table[s] != 0) {
        s = (s + 1) & (slots - 1);
      }
      table[s] = recAt[i];
    }
    final tableOff = w.length;
    for (final v in table) {
      w.u32(v);
    }

    w
      ..setU32(0, _magic)
      ..setU32(4, _version)
      ..setU32(8, entriesOff)
      ..setU32(12, rows.length)
      ..setU32(16, keysOff)
      ..setU32(20, tableOff)
      ..setU32(24, slots)
      ..setU32(28, w.length);
    return w.take();
  }
}

/// 读取端。查询全是同步的,只读字节;注音层 / 词条栏经 [offlineTagMeta] 用它。
class TagIndex implements OfflineTagMeta {
  TagIndex(ByteData data)
    : _d = data,
      _b = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes) {
    if (data.lengthInBytes < _headerSize ||
        _u32(0) != _magic ||
        _u32(4) != _version ||
        _u32(28) != data.lengthInBytes) {
      throw const FormatException('离线词库索引格式对不上,重跑 tool/build_tag_index.dart');
    }
    _entriesOff = _u32(8);
    _entryCount = _u32(12);
    _tableOff = _u32(20);
    _mask = _u32(24) - 1;
  }

  final ByteData _d;
  final Uint8List _b;
  late final int _entriesOff;
  late final int _entryCount;
  late final int _tableOff;
  late final int _mask;

  @override
  String? transOf(String key) {
    final p = _find(key);
    if (p < 0) return null;
    final row = _u32(p);
    final len = _u16(p + 4);
    if (row == 0 || len == 0) return null;
    return _str(row + 2 + _u16(row) + 2, len);
  }

  @override
  int? countOf(String key) {
    final p = _find(key);
    if (p < 0) return null;
    final row = _u32(p);
    return row == 0 ? null : _rowCount(row);
  }

  /// 清洗过的词([cleanPromptToken] 口径)→ 词库帖子数;没收的回 0。
  int postCountOf(String token) {
    final p = _find(token);
    if (p < 0) return 0;
    final row = _u32(p + 6);
    return row == 0 ? 0 : _rowCount(row);
  }

  /// 分词集合 → 命中的角色标签,按热度降序。
  List<CharacterTag> charactersIn(Iterable<String> tokens) {
    final hit = <int>{};
    for (final t in tokens) {
      final p = _find(t);
      if (p < 0) continue;
      final row = _u32(p + 10);
      if (row != 0) hit.add(row);
    }
    if (hit.isEmpty) return const [];
    final out = [for (final row in hit) _character(row)];
    out.sort((a, b) => b.count.compareTo(a.count));
    return out;
  }

  /// 前缀匹配:标签名命中优先、别名命中次之(各自因源已按热度降序)。取前 [limit] 条。
  ///
  /// 结果是两段拼接,**各段内**按热度降序,整体并非全局有序 —— 一个冷门的
  /// 标签名命中本来就该排在热门的别名命中前面。
  List<Suggestion> search(String query, {int limit = 15}) {
    final q = query.trim().toLowerCase().replaceAll(' ', '_');
    if (q.length < 2) return const [];
    final qb = utf8.encode(q);
    final primary = <int>[]; // 标签名前缀命中
    final secondary = <int>[]; // 仅别名前缀命中
    final seen = <String>{};
    var p = _entriesOff;
    for (var i = 0; i < _entryCount; i++) {
      final row = p;
      final tagLen = _u16(row);
      final zhAt = row + 2 + tagLen;
      final aliasAt = zhAt + 2 + _u16(zhAt) + 4;
      final aliasLen = _u16(aliasAt);
      p = aliasAt + 2 + aliasLen;
      if (_startsWith(row + 2, tagLen, qb)) {
        if (seen.add(_str(row + 2, tagLen))) primary.add(row);
        if (primary.length >= limit) break; // 已按热度,够了就停
      } else if (secondary.length < limit &&
          _aliasStartsWith(aliasAt + 2, aliasLen, qb)) {
        if (seen.add(_str(row + 2, tagLen))) secondary.add(row);
      }
    }
    return [
      for (final row in [...primary, ...secondary].take(limit))
        _suggestion(row),
    ];
  }

  /// 键记录里键之后那几个字段的起点;没有这个键回 -1。
  int _find(String key) {
    final kb = utf8.encode(key);
    var s = _fnv1a(kb) & _mask;
    while (true) {
      final rec = _u32(_tableOff + s * 4);
      if (rec == 0) return -1;
      if (_u16(rec) == kb.length && _startsWith(rec + 2, kb.length, kb)) {
        return rec + 2 + kb.length;
      }
      s = (s + 1) & _mask;
    }
  }

  int _rowCount(int row) {
    final zhAt = row + 2 + _u16(row);
    return _u32(zhAt + 2 + _u16(zhAt));
  }

  CharacterTag _character(int row) {
    final tagLen = _u16(row);
    final zhAt = row + 2 + tagLen;
    final zhLen = _u16(zhAt);
    return (
      tag: _str(row + 2, tagLen),
      zh: zhLen == 0 ? null : _str(zhAt + 2, zhLen),
      count: _u32(zhAt + 2 + zhLen),
    );
  }

  Suggestion _suggestion(int row) {
    final c = _character(row);
    return Suggestion(
      text: c.tag.replaceAll('_', ' '),
      kind: SuggestionKind.tag,
      trans: c.zh,
      count: c.count,
    );
  }

  bool _startsWith(int at, int len, Uint8List q) {
    if (len < q.length) return false;
    for (var i = 0; i < q.length; i++) {
      if (_b[at + i] != q[i]) return false;
    }
    return true;
  }

  /// 逗号连起来的别名里,有没有哪个以 [q] 开头。
  bool _aliasStartsWith(int at, int len, Uint8List q) {
    final end = at + len;
    var s = at;
    while (s < end) {
      var e = s;
      while (e < end && _b[e] != 0x2C) {
        e++;
      }
      if (_startsWith(s, e - s, q)) return true;
      s = e + 1;
    }
    return false;
  }

  String _str(int at, int len) =>
      utf8.decode(Uint8List.sublistView(_b, at, at + len));
  int _u16(int at) => _d.getUint16(at, Endian.little);
  int _u32(int at) => _d.getUint32(at, Endian.little);
}

int _fnv1a(Uint8List b) {
  var h = 0x811c9dc5;
  for (final x in b) {
    h = ((h ^ x) * 0x01000193) & 0xFFFFFFFF;
  }
  return h;
}

class _Writer {
  var _buf = Uint8List(1 << 22);
  var length = 0;

  void _grow(int n) {
    if (length + n <= _buf.length) return;
    var cap = _buf.length * 2;
    while (cap < length + n) {
      cap *= 2;
    }
    _buf = Uint8List(cap)..setRange(0, length, _buf);
  }

  void zeros(int n) {
    _grow(n);
    length += n;
  }

  void bytes(List<int> b) {
    _grow(b.length);
    _buf.setRange(length, length + b.length, b);
    length += b.length;
  }

  void u16(int v) {
    if (v > 0xFFFF) throw StateError('字段超长:$v 字节');
    _grow(2);
    ByteData.sublistView(_buf).setUint16(length, v, Endian.little);
    length += 2;
  }

  void u32(int v) {
    _grow(4);
    ByteData.sublistView(_buf).setUint32(length, v, Endian.little);
    length += 4;
  }

  void str16(String s) {
    final b = utf8.encode(s);
    u16(b.length);
    bytes(b);
  }

  void setU32(int at, int v) =>
      ByteData.sublistView(_buf).setUint32(at, v, Endian.little);

  Uint8List take() => _buf.sublist(0, length);
}
