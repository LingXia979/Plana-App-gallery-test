// 解析器的性质测试 —— 手写用例覆盖不全写法组合,这里按语法随机拼提示词:
// ① 预期对照:普通词 / 括号 / `N::a::` / 数值组 / 括号组 / 禁用 / 折叠,再叠上
//    空格、逗号、换行、`::` 连写、`year 2025` 这类数字结尾的词,每枚词应有的
//    权重是知道的,和 parseToks 逐枚对;
// ② 编辑操作:加减、清除、套括号、禁用、改名、删除、批量加权/清除/套括号/删除、
//    outputOf,改完重新解析,没动到的词名字和权重都得原样;
// ③ 乱码:随机拼记号残片,只查不崩、区间合法。
// 种子固定,失败时报出缩减后的最小复现。
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/features/editor/editor_models.dart';

bool _near(double a, double b) =>
    (a - b).abs() <= 1e-6 * max(1.0, max(a.abs(), b.abs()));

class Exp {
  const Exp(this.name, this.mult, this.disabled);
  final String name;
  final double mult;
  final bool disabled;
  @override
  String toString() => '${disabled ? '~' : ''}$name×${fmtMult(mult)}';
}

// ---------------------------------------------------------------- 语法树

abstract class Node {
  String render();
  List<Exp> exp(double outer, bool dis);
  List<Node> shrink();
  bool get startsWithNum => false;
  bool get endsWithClose => false;

  /// 第一个记号就是数值前缀(被 `{` / `~` 包着也算)—— 能截断前一个没收口的组
  bool get opensNum => startsWithNum;

  /// 以「数字 + 收口」结尾(`year 2025::`):后面紧跟普通词时本就有歧义
  bool get gluedDigitClose {
    final r = render();
    return r.length >= 3 &&
        r.endsWith('::') &&
        RegExp(r'[0-9]').hasMatch(r[r.length - 3]);
  }
}

class Tag extends Node {
  Tag(this.name);
  final String name;
  @override
  String render() => name;
  @override
  List<Exp> exp(double o, bool d) => [Exp(name, o, d)];
  @override
  List<Node> shrink() => name == 'a' ? [] : [Tag('a')];
}

class Brace extends Node {
  Brace(this.child, this.k, {this.pad = false});
  final Node child; // Tag / Own
  final int k;
  final bool pad;
  @override
  String render() {
    final o = k > 0 ? '{' * k : '[' * -k;
    final c = k > 0 ? '}' * k : ']' * -k;
    final p = pad ? ' ' : '';
    return '$o$p${child.render()}$p$c';
  }

  @override
  bool get opensNum => child.opensNum;
  @override
  List<Exp> exp(double o, bool d) => child.exp(o * pow(1.05, k).toDouble(), d);
  @override
  List<Node> shrink() => [
    child,
    if (k.abs() > 1) Brace(child, k.sign),
    if (pad) Brace(child, k),
    for (final c in child.shrink()) Brace(c, k, pad: pad),
  ];
}

class Own extends Node {
  Own(this.w, this.child, {this.spA = false, this.spB = false});
  final double w;
  final Node child; // Tag / Brace(Tag)
  final bool spA, spB;
  @override
  String render() =>
      '${fmtMult(w)}::${spA ? ' ' : ''}${child.render()}${spB ? ' ' : ''}::';
  @override
  List<Exp> exp(double o, bool d) => child.exp(o * w, d);
  @override
  bool get startsWithNum => true;
  @override
  bool get endsWithClose => true;
  @override
  List<Node> shrink() => [
    child,
    if (spA || spB) Own(w, child),
    if (w != 1.2) Own(1.2, child, spA: spA, spB: spB),
    for (final c in child.shrink()) Own(w, c, spA: spA, spB: spB),
  ];
}

class Dis extends Node {
  Dis(this.child);
  final Node child; // Tag / Brace / Own
  @override
  String render() => '~${child.render()}~';
  @override
  bool get opensNum => child.opensNum;
  @override
  List<Exp> exp(double o, bool d) => child.exp(o, true);
  @override
  List<Node> shrink() => [child, for (final c in child.shrink()) Dis(c)];
}

class NumGroup extends Node {
  NumGroup(
    this.w,
    this.members,
    this.sep, {
    this.trail = '',
    this.spA = false,
    this.spB = false,
    this.closed = true,
  });
  final double w;
  final List<Node> members; // Tag / Brace(Tag) / Dis(Tag|Brace) / BraceGroup
  final String sep;
  final String trail;
  final bool spA, spB, closed;

  NumGroup _with({
    List<Node>? members,
    String? sep,
    String? trail,
    bool? spA,
    bool? spB,
    bool? closed,
    double? w,
  }) => NumGroup(
    w ?? this.w,
    members ?? this.members,
    sep ?? this.sep,
    trail: trail ?? this.trail,
    spA: spA ?? this.spA,
    spB: spB ?? this.spB,
    closed: closed ?? this.closed,
  );

  @override
  String render() =>
      '${fmtMult(w)}::${spA ? ' ' : ''}'
      '${members.map((m) => m.render()).join(sep)}$trail'
      '${closed ? '${spB ? ' ' : ''}::' : ''}';
  @override
  List<Exp> exp(double o, bool d) => [
    for (final m in members) ...m.exp(o * w, d),
  ];
  @override
  bool get startsWithNum => true;
  @override
  bool get endsWithClose => closed;
  @override
  List<Node> shrink() => [
    if (members.length > 1)
      for (var i = 0; i < members.length; i++)
        _with(members: [...members]..removeAt(i)),
    if (trail.isNotEmpty) _with(trail: ''),
    if (spA) _with(spA: false),
    if (spB) _with(spB: false),
    if (sep != ', ') _with(sep: ', '),
    if (!closed) _with(closed: true),
    if (w != 1.2) _with(w: 1.2),
    for (var i = 0; i < members.length; i++)
      for (final s in members[i].shrink())
        _with(members: [...members]..[i] = s),
  ];
}

class BraceGroup extends Node {
  BraceGroup(this.k, this.members, this.sep);
  final int k;
  final List<Node> members;
  final String sep;
  @override
  String render() {
    final o = k > 0 ? '{' * k : '[' * -k;
    final c = k > 0 ? '}' * k : ']' * -k;
    return '$o${members.map((m) => m.render()).join(sep)}$c';
  }

  @override
  List<Exp> exp(double o, bool d) => [
    for (final m in members) ...m.exp(o * pow(1.05, k).toDouble(), d),
  ];
  @override
  List<Node> shrink() => [
    if (members.length > 1)
      for (var i = 0; i < members.length; i++)
        BraceGroup(k, [...members]..removeAt(i), sep),
    if (k.abs() > 1) BraceGroup(k.sign, members, sep),
    if (sep != ', ') BraceGroup(k, members, ', '),
    for (var i = 0; i < members.length; i++)
      for (final s in members[i].shrink())
        BraceGroup(k, [...members]..[i] = s, sep),
  ];
}

class Fold extends Node {
  Fold(this.name, this.members, this.sep, {this.legacy = false});
  final String name;
  final List<Node> members;
  final String sep;
  final bool legacy;
  @override
  String render() =>
      '<#$name: ${members.map((m) => m.render()).join(sep)}'
      '${legacy ? '>' : '#>'}';
  @override
  List<Exp> exp(double o, bool d) => [for (final m in members) ...m.exp(o, d)];
  @override
  List<Node> shrink() => [
    if (members.length > 1)
      for (var i = 0; i < members.length; i++)
        Fold(name, [...members]..removeAt(i), sep, legacy: legacy),
    if (legacy) Fold(name, members, sep),
    if (name != 'f') Fold('f', members, sep, legacy: legacy),
    if (sep != ', ') Fold(name, members, ', ', legacy: legacy),
    for (var i = 0; i < members.length; i++)
      for (final s in members[i].shrink())
        Fold(name, [...members]..[i] = s, sep, legacy: legacy),
  ];
}

class Prompt {
  Prompt(this.nodes, this.seps, {this.lead = '', this.tail = ''});
  final List<Node> nodes;
  final List<String> seps;
  final String lead, tail;

  String render() {
    final b = StringBuffer(lead);
    for (var i = 0; i < nodes.length; i++) {
      if (i > 0) b.write(seps[i - 1]);
      b.write(nodes[i].render());
    }
    b.write(tail);
    return b.toString();
  }

  List<Exp> exp() => [for (final n in nodes) ...n.exp(1, false)];

  bool get valid {
    for (var i = 0; i < nodes.length; i++) {
      final n = nodes[i];
      if (i > 0 && seps[i - 1].isEmpty) {
        final prev = nodes[i - 1];
        if (!prev.endsWithClose || n is Fold) return false;
        if (prev.gluedDigitClose && !n.startsWithNum) return false;
      }
      if (n is NumGroup && !n.closed) {
        final last = i == nodes.length - 1;
        if (!last && !nodes[i + 1].opensNum) return false;
        if (last && tail.isNotEmpty) return false;
      }
    }
    return nodes.isNotEmpty;
  }

  List<Prompt> shrink() => [
    if (nodes.length > 1)
      for (var i = 0; i < nodes.length; i++)
        Prompt(
          [...nodes]..removeAt(i),
          [...seps]..removeAt(i == 0 ? 0 : i - 1),
        ),
    if (lead.isNotEmpty || tail.isNotEmpty) Prompt(nodes, seps),
    for (var i = 0; i < seps.length; i++)
      if (seps[i] != ', ' && seps[i].isNotEmpty)
        Prompt(nodes, [...seps]..[i] = ', ', lead: lead, tail: tail),
    for (var i = 0; i < nodes.length; i++)
      for (final s in nodes[i].shrink())
        Prompt([...nodes]..[i] = s, seps, lead: lead, tail: tail),
  ];
}

// ---------------------------------------------------------------- 生成器

class Gen {
  Gen(int seed) : r = Random(seed);
  final Random r;

  static const names = [
    'a',
    'b',
    'long hair',
    '1girl',
    'year 2025',
    'artist:ciloranko',
    'artist:motimoti067',
    'hatsune miku (vocaloid)',
    '初音未来',
    '>_<',
    ':3',
    '0_0',
    '3d',
    'score_9',
    '<3',
  ];
  static const weights = [1.2, 0.8, 1.5, 2.0, -1.0, 0.0, 1.05, 0.45];
  static const seps = [', ', ',', '，', '\n', ', \n', ' , '];

  T pick<T>(List<T> xs) => xs[r.nextInt(xs.length)];
  bool chance(double p) => r.nextDouble() < p;

  Node tag() => Tag(pick(names));
  Node brace(Node child) =>
      Brace(child, pick([1, 1, 2, -1, -2]), pad: chance(.15));
  Node own() => Own(
    pick(weights),
    chance(.25) ? brace(tag()) : tag(),
    spA: chance(.15),
    spB: chance(.3),
  );

  /// 单枚词条(可含禁用)
  Node single({bool allowOwn = true}) {
    Node n;
    final x = r.nextDouble();
    if (x < .45) {
      n = tag();
    } else if (x < .65) {
      n = brace(tag());
    } else if (allowOwn && x < .85) {
      n = own();
    } else if (allowOwn) {
      n = Brace(own(), pick([1, -1]));
    } else {
      n = tag();
    }
    return chance(.12) ? Dis(n) : n;
  }

  List<Node> members({required bool inNum, int depth = 0}) {
    final k = 1 + r.nextInt(3);
    return [
      for (var i = 0; i < k; i++)
        if (depth < 1 && chance(.15))
          inNum
              ? BraceGroup(
                  pick([1, -1]),
                  members(inNum: true, depth: 1),
                  pick(seps),
                )
              : NumGroup(
                  pick(weights),
                  members(inNum: true, depth: 1),
                  pick(seps),
                )
        else
          single(allowOwn: !inNum),
    ];
  }

  Node top({bool allowFold = true}) {
    final x = r.nextDouble();
    if (x < .40) return single();
    if (x < .70) {
      return NumGroup(
        pick(weights),
        members(inNum: true),
        pick(seps),
        trail: pick(['', '', '', ', ', ',']),
        spA: chance(.15),
        spB: chance(.3),
      );
    }
    if (x < .85) {
      return BraceGroup(pick([1, 1, 2, -1]), members(inNum: false), pick(seps));
    }
    if (allowFold) {
      final k = 1 + r.nextInt(3);
      return Fold(
        pick(['画师', 'f', 'oc 2']),
        [for (var i = 0; i < k; i++) top(allowFold: false)],
        pick(seps),
        legacy: chance(.2),
      );
    }
    return single();
  }

  Prompt prompt() {
    for (;;) {
      final k = 1 + r.nextInt(5);
      final nodes = [for (var i = 0; i < k; i++) top()];
      // 末尾的数值组偶尔不收口;后面紧跟前缀的也可以不收口(被截断)
      for (var i = 0; i < nodes.length; i++) {
        final n = nodes[i];
        if (n is NumGroup && chance(.15)) {
          final last = i == nodes.length - 1;
          if (last || nodes[i + 1].opensNum) {
            nodes[i] = n._with(closed: false);
          }
        }
      }
      final ss = <String>[
        for (var i = 1; i < nodes.length; i++)
          nodes[i - 1].endsWithClose && nodes[i] is! Fold && chance(.25)
              ? ''
              : pick(seps),
      ];
      final p = Prompt(
        nodes,
        ss,
        lead: chance(.1) ? '\n' : '',
        tail: chance(.1) ? ', ' : '',
      );
      if (p.valid) return p;
    }
  }
}

// ---------------------------------------------------------------- 检查

List<String> invariants(String text) {
  final errs = <String>[];
  final spans = <WeightSpan>[];
  final folds = <FoldSpan>[];
  List<Tok> toks;
  try {
    toks = parseToks(text, weightSpans: spans, folds: folds);
  } catch (e) {
    return ['throw ${e.runtimeType}'];
  }
  var prev = 0;
  for (final t in toks) {
    final ok =
        prev <= t.segStart &&
        t.segStart <= t.coreStart &&
        t.coreStart <= t.innerStart &&
        t.innerStart <= t.nameStart &&
        t.nameStart <= t.nameEnd &&
        t.nameEnd <= t.innerEnd &&
        t.innerEnd <= t.coreEnd &&
        t.coreEnd <= t.segEnd &&
        t.segEnd <= text.length;
    if (!ok) errs.add('range order');
    prev = t.segEnd;
    if (t.name.isEmpty) errs.add('empty name');
    if (t.name.trim() != t.name) errs.add('untrimmed name');
    if (RegExp('[,，\n]').hasMatch(text.substring(t.segStart, t.segEnd))) {
      errs.add('seg spans separator');
    }
    if (!t.effMult.isFinite) errs.add('non-finite mult');
    final g = t.numGroup;
    if (g != null) {
      if (!(g.start < g.contentStart &&
          g.contentStart <= t.segStart &&
          t.segEnd <= g.end &&
          g.end <= text.length &&
          g.members >= 1)) {
        errs.add('numGroup bounds');
      }
    }
  }
  for (final s in spans) {
    if (!(0 <= s.start && s.start < s.end && s.end <= text.length)) {
      errs.add('span bounds');
    }
  }
  var fp = 0;
  for (final f in folds) {
    if (!(fp <= f.start &&
        f.start < f.nameStart &&
        f.nameStart <= f.nameEnd &&
        f.nameEnd <= f.bodyStart &&
        f.bodyStart <= f.bodyEnd &&
        f.bodyEnd <= f.end &&
        f.end <= text.length)) {
      errs.add('fold bounds');
    }
    fp = f.end;
  }
  return errs;
}

String? oracle(Prompt p) {
  final text = p.render();
  final exp = p.exp();
  List<Tok> toks;
  try {
    toks = parseToks(text);
  } catch (e) {
    return 'throw';
  }
  final got = [for (final t in toks) Exp(t.name, t.effMult, t.disabled)];
  if (got.length != exp.length) return 'count';
  for (var i = 0; i < got.length; i++) {
    if (got[i].name != exp[i].name) return 'name';
    if (got[i].disabled != exp[i].disabled) return 'disabled';
    if (!_near(got[i].mult, exp[i].mult)) return 'mult';
  }
  return null;
}

typedef Snap = List<(String, double, bool)>;
Snap snap(String t) => [
  for (final k in parseToks(t)) (k.name, k.effMult, k.disabled),
];

/// 编辑操作的变形检查;返回 (操作, 失败描述) 或 null
(String, String)? metamorphic(String text) {
  final toks = parseToks(text);
  final base = snap(text);
  bool sameExcept(Snap a, Snap b, Set<int> skip, {bool mults = true}) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].$1 != b[i].$1 || a[i].$3 != b[i].$3) return false;
      if (mults && !skip.contains(i) && !_near(a[i].$2, b[i].$2)) return false;
    }
    return true;
  }

  for (var i = 0; i < toks.length; i++) {
    final t = toks[i];
    final mates = <int>{
      for (var j = 0; j < toks.length; j++)
        if (t.numGroup != null && identical(toks[j].numGroup, t.numGroup)) j,
      i,
    };

    // 数值加减
    for (final m in [t.numWeight + 0.1, 1.0, 1.3]) {
      final target = (m * 100).roundToDouble() / 100;
      final (out, cur) = setTokMult(text, t, m);
      if (cur < 0 || cur > out.length) return ('setTokMult', 'cursor');
      final after = parseToks(out);
      if (!sameExcept(base, snap(out), mates)) {
        return ('setTokMult→${fmtMult(target)}', 'others changed');
      }
      final ti = after[i];
      if (!_near(ti.numWeight, target)) {
        return ('setTokMult→${fmtMult(target)}', 'numWeight ${ti.numWeight}');
      }
      if (ti.braceLevel != t.braceLevel) {
        return ('setTokMult→${fmtMult(target)}', 'brace changed');
      }
      final i2 = tokIndexAt(out, cur, after);
      if (i2 != i) return ('setTokMult→${fmtMult(target)}', 'cursor off tok');
    }

    // 清除
    {
      final (out, cur) = clearWeight(text, t);
      if (cur < 0 || cur > out.length) return ('clearWeight', 'cursor');
      final after = parseToks(out);
      if (!sameExcept(base, snap(out), mates)) {
        return ('clearWeight', 'others changed');
      }
      if (after[i].braceLevel != 0 || !_near(after[i].numWeight, 1)) {
        return ('clearWeight', 'still weighted');
      }
    }

    // 套括号
    {
      final out = wrapBracket(text, t, up: true);
      final after = parseToks(out);
      if (!sameExcept(base, snap(out), {i})) {
        return ('wrapBracket', 'others changed');
      }
      if (after[i].braceLevel != t.braceLevel + 1) {
        return ('wrapBracket', 'brace ${after[i].braceLevel}');
      }
    }

    // 禁用来回
    {
      final once = toggleTokDisabled(text, t);
      final a1 = parseToks(once);
      if (a1.length != toks.length || a1[i].disabled == t.disabled) {
        return ('toggleDisabled', 'not toggled');
      }
      final twice = toggleTokDisabled(once, a1[i]);
      if (!sameExcept(base, snap(twice), {})) {
        return ('toggleDisabled', 'not reversible');
      }
    }

    // 改名
    {
      final out = renameTok(text, t, 'zz');
      final s = snap(out);
      final exp = [...base]..[i] = ('zz', base[i].$2, base[i].$3);
      if (!sameExcept(exp, s, {})) return ('renameTok', 'mismatch');
    }

    // 删除
    {
      final (out, _) = deleteTok(text, t);
      final s = snap(out);
      final exp = [...base]..removeAt(i);
      if (!sameExcept(exp, s, {})) return ('deleteTok', 'mismatch');
    }
  }

  // 批量(连续区间)。跨折叠边界的选区按设计拒绝改写(折叠恒为最外层),不查
  final folds = parseFolds(text);
  bool crossesFold(int a, int b) {
    for (final f in folds) {
      final inside = [for (var k = a; k <= b; k++) f.holds(toks[k])];
      if (inside.contains(true) && inside.contains(false)) return true;
    }
    return false;
  }

  for (var a = 0; a < toks.length; a++) {
    for (var b = a + 1; b < toks.length && b <= a + 2; b++) {
      if (crossesFold(a, b)) continue;
      final range = {for (var k = a; k <= b; k++) k};
      {
        final out = batchSetMult(text, a, b, 1.3);
        final s = snap(out);
        if (!sameExcept(base, s, range)) return ('batchSetMult', 'others');
        final after = parseToks(out);
        for (final k in range) {
          if (!_near(after[k].numWeight, 1.3) || after[k].braceLevel != 0) {
            return ('batchSetMult', 'member not 1.3');
          }
        }
      }
      {
        final out = batchClearWeight(text, a, b);
        if (!sameExcept(base, snap(out), range)) {
          return ('batchClearWeight', 'others');
        }
        final after = parseToks(out);
        for (final k in range) {
          if (!_near(after[k].numWeight, 1) || after[k].braceLevel != 0) {
            return ('batchClearWeight', 'member still weighted');
          }
        }
      }
      {
        final out = batchWrap(text, a, b, up: true);
        final s = snap(out);
        if (!sameExcept(base, s, range)) return ('batchWrap', 'others');
        for (final k in range) {
          if (!_near(s[k].$2, base[k].$2 * 1.05)) {
            return ('batchWrap', 'member not ×1.05');
          }
        }
      }
      {
        final (out, _) = batchDelete(text, a, b);
        final exp = [...base]..removeRange(a, b + 1);
        if (!sameExcept(exp, snap(out), {})) return ('batchDelete', 'mismatch');
      }
    }
  }

  // 输出:剔禁用 + 剥折叠,启用词条原样保留
  {
    final out = outputOf(text);
    final exp = [
      for (final e in base)
        if (!e.$3) e,
    ];
    if (!sameExcept(exp, snap(out), {})) return ('outputOf', 'mismatch');
  }
  return null;
}

Prompt shrinkWhile(Prompt p, bool Function(Prompt) fails) {
  var cur = p;
  var progress = true;
  while (progress) {
    progress = false;
    for (final c in cur.shrink()) {
      if (c.valid && fails(c)) {
        cur = c;
        progress = true;
        break;
      }
    }
  }
  return cur;
}

String show(String s) => s.replaceAll('\n', r'\n');

void main() {
  test('按语法随机生成的提示词:逐枚词对照预期权重', () {
    final g = Gen(20260914);
    for (var k = 0; k < 1500; k++) {
      final p = g.prompt();
      final inv = invariants(p.render());
      final why = inv.isNotEmpty ? 'inv:${inv.first}' : oracle(p);
      if (why == null) continue;
      bool fails(Prompt q) {
        final i = invariants(q.render());
        return (i.isNotEmpty ? 'inv:${i.first}' : oracle(q)) == why;
      }

      final min = shrinkWhile(p, fails);
      final got = [
        for (final t in parseToks(min.render()))
          Exp(t.name, t.effMult, t.disabled),
      ];
      fail('$why | ${show(min.render())}\n  got $got\n  exp ${min.exp()}');
    }
  });

  test('编辑操作改完:没动到的词名字、权重原样', () {
    final g = Gen(7);
    for (var k = 0; k < 200; k++) {
      final p = g.prompt();
      final text = p.render();
      if (oracle(p) != null || invariants(text).isNotEmpty) continue;
      final why = metamorphic(text);
      if (why == null) continue;
      final min = shrinkWhile(p, (q) {
        final t = q.render();
        return oracle(q) == null &&
            invariants(t).isEmpty &&
            metamorphic(t) == why;
      });
      fail('${why.$1} ${why.$2} | ${show(min.render())}');
    }
  });

  test('乱码:不崩溃、区间合法', () {
    final r = Random(42);
    const frags = [
      'a',
      'b c',
      '1',
      '2025',
      '1.2',
      '-',
      '.',
      ':',
      '::',
      ',',
      '，',
      ' ',
      '\n',
      '{',
      '}',
      '[',
      ']',
      '~',
      '(',
      ')',
      '<#f: ',
      '#>',
      '<',
      '>',
      '#',
      kFoldZw,
      '_',
      'x9',
      '0.5::',
      '::,',
    ];
    for (var k = 0; k < 3000; k++) {
      final len = r.nextInt(14);
      final s = [
        for (var i = 0; i < len; i++) frags[r.nextInt(frags.length)],
      ].join();
      // 空名词条是打字途中的正常状态(单打一个 `~`、`1.5::`),不算错
      final errs = invariants(s).where((e) => e != 'empty name');
      expect(errs, isEmpty, reason: show(s));
      expect(
        () {
          final toks = parseToks(s);
          for (final t in toks) {
            setTokMult(s, t, t.numWeight + 0.1);
            setTokMult(s, t, 1);
            clearWeight(s, t);
            wrapBracket(s, t, up: false);
            toggleTokDisabled(s, t);
            deleteTok(s, t);
            renameTok(s, t, 'q');
          }
          if (toks.length >= 2) {
            batchSetMult(s, 0, toks.length - 1, 1.1);
            batchWrap(s, 0, toks.length - 1, up: true);
            batchClearWeight(s, 0, toks.length - 1);
            batchDelete(s, 0, toks.length - 1);
            reorderToks(s, 0, toks.length - 1);
            foldRange(s, 0, 1, 'n');
          }
          outputOf(s);
          final (body, bodies) = collapseFolds(s);
          expandFolds(body, bodies);
          final units = topLevelUnits(body, bodies);
          unitGroups(body, units);
          if (units.length >= 2) moveUnits(body, bodies, [0], units.length);
        },
        returnsNormally,
        reason: show(s),
      );
    }
  });
}
