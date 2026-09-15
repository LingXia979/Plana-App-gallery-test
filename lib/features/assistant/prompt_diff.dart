/// 结果条上 `+7 −2` 那对读数和详情弹层里的差异:这一轮的提示词相对上一轮多了什么、
/// 少了什么。
///
/// **比对单元是「一枚 tag」或「一整句话」,不再一律按逗号切。** NAI5 的提示词是 tag 和
/// 句子混写的(仅自然语言模式下整条都是句子),而句子里本来就有逗号 —— 按逗号切,一句话
/// 碎成好几截:AI 只改了一个词,读数报出一串增删,弹层里还把半句话画成芯片。
///
/// 怎么认句子见 [promptUnits]。改过的句子会配成对,弹层里只标出改掉的那几个词
/// (见 [markChangedWords])—— 只改了发色却整句标色,等于什么都没说。读数上它仍是
/// `+1 −1`,和代码 diff 同一个说法。
library;

import 'dart:math' as math;

/// 提示词里的一个比对单元:一枚 tag,或一句话。
class PromptUnit {
  const PromptUnit(this.text, this.start, {this.prose = false});

  /// 原文里的这一段,去掉了首尾空白。tag 还去掉了句末标点(`monochrome.` 的句号只是
  /// 分隔);句子原样。
  final String text;

  /// [text] 在原文里的起点。
  final int start;

  int get end => start + text.length;

  /// 句子,或者四个词以上的短句:弹层里当文字排,不画成芯片。
  final bool prose;

  /// 比对用的键。空白折叠、句末标点去掉;三个词以上的再不分大小写 —— 句首字母跟着句子
  /// 怎么断走(`Rain streaks the glass.` 和 `, rain streaks the glass`),不是改了内容。
  /// 短的原样比,**下划线也不归一**:`cat girl` 与 `cat_girl` 对 NAI 是两个不同的 tag,
  /// 合并它们等于把一次真实的改写说成「没变」。
  String get key {
    final t = text.replaceAll(_spaces, ' ').replaceFirst(_trailingStops, '');
    return _words(t) >= 3 ? t.toLowerCase() : t;
  }
}

final _spaces = RegExp(r'\s+');
final _trailingStops = RegExp(r'[.!?。！？]+$');
final _capital = RegExp(r'^[A-Z]');

bool _isSpace(String c) => c == ' ' || c == '\t' || c == '\n' || c == '\r';

bool _isComma(String c) => c == ',' || c == '，';

bool _isStop(String c) => '.!?。！？'.contains(c);

int _words(String s) {
  final t = s.trim();
  return t.isEmpty ? 0 : t.split(_spaces).length;
}

/// [i] 处是不是一句的末尾。`.` `!` `?` 后面得跟空白或到头 —— `1.2::` 这种数里的点、
/// 夹在 tag 中间的 `!?` 都不算;全角的 `。！？` 本身就是句末。
bool _endsSentence(String s, int i) {
  final c = s[i];
  if (c == '。' || c == '！' || c == '？') return true;
  if (c != '.' && c != '!' && c != '?') return false;
  return i + 1 == s.length || _isSpace(s[i + 1]);
}

/// 把一条提示词切成比对单元,按原文顺序。
///
/// 先按句末标点和换行切成一句一句,每句再按逗号切成几截。然后:
///   · **整条一个句末标点都没有**的,每一截各是一个单元 —— 纯 tag 串,或者逗号接短句的
///     混排(预设就是让短句当逗号分隔的成分嵌进去的)。
///   · 有句末标点的,一句里从**第一截大写字母开头的**起到句末,合成一个单元;它前面
///     那几截是挂在句子前头的 tag(画师串、OC 的 tag 组)。没有大写开头的,只合句末那几截
///     连着都是三个词以上的。合出来不到三个词的不算句子 ——
///     `2girls, manga, monochrome.` 的句号只是分隔。
List<PromptUnit> promptUnits(String s) {
  var prosey = false;
  for (var i = 0; i < s.length && !prosey; i++) {
    prosey = _endsSentence(s, i);
  }
  final out = <PromptUnit>[];
  var from = 0;
  for (var i = 0; i < s.length; i++) {
    if (s[i] == '\n') {
      _cut(s, from, i, prosey: prosey, stopped: false, out: out);
      from = i + 1;
    } else if (_endsSentence(s, i)) {
      _cut(s, from, i + 1, prosey: prosey, stopped: true, out: out);
      from = i + 1;
    }
  }
  _cut(s, from, s.length, prosey: prosey, stopped: false, out: out);
  return out;
}

/// 一句 [a, b) 切成单元追加进 [out]。[stopped] = 这句收在句末标点上(标点在 b-1)。
void _cut(
  String s,
  int a,
  int b, {
  required bool prosey,
  required bool stopped,
  required List<PromptUnit> out,
}) {
  final pieces = <(int, int)>[];
  var p = a;
  for (var i = a; i <= b; i++) {
    if (i < b && !_isComma(s[i])) continue;
    var x = p, y = i;
    while (x < y && _isSpace(s[x])) {
      x++;
    }
    while (y > x && _isSpace(s[y - 1])) {
      y--;
    }
    if (y > x) pieces.add((x, y));
    p = i + 1;
  }
  if (pieces.isEmpty) return;
  final texts = [for (final (x, y) in pieces) s.substring(x, y)];

  // 句子从第几截开始;等于截数 = 这句里没有句子,全是 tag
  var head = pieces.length;
  if (prosey) {
    var k = texts.indexWhere(_capital.hasMatch);
    if (k < 0) {
      // 没有大写开头的:从句末往回数,连着都是三个词以上的那几截才算句子。
      // 不能从第一截长的一路合到句末 —— 中间夹着的 tag 会被一起吞进去。
      k = pieces.length;
      while (k > 0 && _words(texts[k - 1]) >= 3) {
        k--;
      }
      if (k == pieces.length) k = -1;
    }
    if (k >= 0 && _words(s.substring(pieces[k].$1, b)) >= 3) head = k;
  }

  for (var k = 0; k < head; k++) {
    final (x, y) = pieces[k];
    var e = y;
    // 收句的标点落在最后一截 tag 上时只是分隔,去掉;整截就是标点的(`?` 这枚 tag)原样留着
    if (stopped && k == pieces.length - 1) {
      while (e > x && _isStop(s[e - 1])) {
        e--;
      }
      while (e > x && _isSpace(s[e - 1])) {
        e--;
      }
      if (e == x) e = y;
    }
    final text = s.substring(x, e);
    out.add(PromptUnit(text, x, prose: _words(text) >= 4));
  }
  if (head < pieces.length) {
    final x = pieces[head].$1;
    out.add(PromptUnit(s.substring(x, pieces.last.$2), x, prose: true));
  }
}

/// 有多少个 tag:按 [promptUnits] 数,一句话算一个;[parts] 是角色分区,一并算上。
/// 结果条上的「生成了 N tag」和历史会话列表的「N tag」都用它,两处的数才对得上,
/// 也和 `+7 −2` 是同一种单位。
int countTags(String main, [Iterable<String> parts = const []]) =>
    parts.fold(promptUnits(main).length, (n, p) => n + promptUnits(p).length);

/// 两份提示词之间的增删。
class PromptDiff {
  const PromptDiff({required this.added, required this.removed});

  /// 这一轮多出来的单元,按这一轮里的顺序。
  final List<PromptUnit> added;

  /// 上一轮有、这一轮没了的单元,按上一轮里的顺序。
  final List<PromptUnit> removed;

  bool get isEmpty => added.isEmpty && removed.isEmpty;
}

/// [after] 相对 [before] 的增删。按单元的 [PromptUnit.key] 比集合,**不看顺序** ——
/// AI 每轮都可能把 tag 挪个位置,那不是改动。
PromptDiff diffPrompt(String before, String after) {
  final a = promptUnits(before), b = promptUnits(after);
  final had = {for (final u in a) u.key};
  final has = {for (final u in b) u.key};
  return PromptDiff(
    added: [
      for (final u in b)
        if (!had.contains(u.key)) u,
    ],
    removed: [
      for (final u in a)
        if (!has.contains(u.key)) u,
    ],
  );
}

/// 改过的句子里具体变了哪些词。两份列表与 [PromptDiff.added] / [PromptDiff.removed]
/// 逐条对应,装的是原文区间;null = 没配上对,整条都是新写的 / 整条删了。
typedef ChangedWords = ({
  List<List<(int, int)>?> added,
  List<List<(int, int)>?> removed,
});

/// 把删掉的和新写的配成对:词的重合过半就算同一句改了几个词,标出改掉的那几个。
/// 三个词以下的不配 —— 一枚 tag 换成另一枚就是换了,没有「改了哪个词」可说。
///
/// 从最像的一对开始配,配过的不再参与。算一遍要跑几十次最长公共子序列,所以
/// 只在打开弹层时算,结果条上的读数用不着它。
ChangedWords markChangedWords(PromptDiff d) {
  final added = List<List<(int, int)>?>.filled(d.added.length, null);
  final removed = List<List<(int, int)>?>.filled(d.removed.length, null);
  final newWords = [for (final u in d.added) _tokens(u)];
  final oldWords = [for (final u in d.removed) _tokens(u)];

  final pairs = <(double, int, int)>[];
  for (var i = 0; i < newWords.length; i++) {
    if (newWords[i].length < 3) continue;
    for (var j = 0; j < oldWords.length; j++) {
      if (oldWords[j].length < 3) continue;
      final n = _lcs(oldWords[j], newWords[i]).length;
      final sim = 2 * n / (oldWords[j].length + newWords[i].length);
      if (sim >= .5) pairs.add((sim, i, j));
    }
  }
  pairs.sort((x, y) => y.$1.compareTo(x.$1));

  for (final (_, i, j) in pairs) {
    if (added[i] != null || removed[j] != null) continue;
    final common = _lcs(oldWords[j], newWords[i]);
    final keptOld = {for (final (o, _) in common) o};
    final keptNew = {for (final (_, n) in common) n};
    removed[j] = [
      for (var k = 0; k < oldWords[j].length; k++)
        if (!keptOld.contains(k)) (oldWords[j][k].start, oldWords[j][k].end),
    ];
    added[i] = [
      for (var k = 0; k < newWords[i].length; k++)
        if (!keptNew.contains(k)) (newWords[i][k].start, newWords[i][k].end),
    ];
  }
  return (added: added, removed: removed);
}

typedef _Word = ({int start, int end, String norm});

final _wordRe = RegExp(r'\S+');
final _edgePunct = RegExp(r'^[^\p{L}\p{N}]+|[^\p{L}\p{N}]+$', unicode: true);

/// 单元里的词(原文区间)。比的时候不分大小写、不带两头的标点:句末那个句号挪了位置
/// 不该让最后一个词算成改过。
List<_Word> _tokens(PromptUnit u) => [
  for (final m in _wordRe.allMatches(u.text))
    (
      start: u.start + m.start,
      end: u.start + m.end,
      norm: switch (m[0]!.replaceAll(_edgePunct, '').toLowerCase()) {
        '' => m[0]!,
        final w => w,
      },
    ),
];

/// 最长公共子序列,返回配上的下标对 (a 里的, b 里的)。
List<(int, int)> _lcs(List<_Word> a, List<_Word> b) {
  final n = a.length, m = b.length;
  final len = List.generate(n + 1, (_) => List.filled(m + 1, 0));
  for (var i = n - 1; i >= 0; i--) {
    for (var j = m - 1; j >= 0; j--) {
      len[i][j] = a[i].norm == b[j].norm
          ? len[i + 1][j + 1] + 1
          : math.max(len[i + 1][j], len[i][j + 1]);
    }
  }
  final out = <(int, int)>[];
  var i = 0, j = 0;
  while (i < n && j < m) {
    if (a[i].norm == b[j].norm) {
      out.add((i, j));
      i++;
      j++;
    } else if (len[i + 1][j] >= len[i][j + 1]) {
      i++;
    } else {
      j++;
    }
  }
  return out;
}
