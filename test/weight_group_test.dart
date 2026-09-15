// 数值权重组 `N::…::` 的边界 —— 与桌面端 novelai_web_ui 的
// `src/components/PromptEditor.tsx` 权重装饰(Pass 2)同规则:
// 右界 = min(最近的闭合 `::`, 下一个 `N::` 前缀)。
//
// 钉这两条老实现踩过的坑:
// ① 闭记号落在逗号**之后**(`0.5::a,::b`)照样收口 —— 老实现按逗号切段、
//    只认「段尾以 :: 结尾」,收不了口的组一路吞到文末(实机截图:整屏权重
//    底色糊成一片);
// ② 未闭合的组被下一个 `N::` 前缀截断,不吞掉后面的组 —— 老实现是再压一层
//    栈,倍率连乘,后面的词条 effMult 被连乘成异常值(报橙色警告)。
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/features/editor/editor_models.dart';

/// (name, effMult) 便于逐词条断言
List<(String, double)> _toks(String text) => [
  for (final t in parseToks(text)) (t.name, t.effMult),
];

/// (原文片段, 倍率) 便于断言权重可视区间
List<(String, double)> _spans(String text) {
  final spans = <WeightSpan>[];
  parseToks(text, weightSpans: spans);
  return [for (final s in spans) (text.substring(s.start, s.end), s.mult)];
}

void main() {
  test('闭记号在逗号之后:收得了口,不吞后文', () {
    // 实机截图里的真实形态(画师串被写成 `w::name,::` )
    const t =
        '0.5::artist:fujiyama,::artist:motimoti067,'
        '0.8::artist:ham_melon::,tail';
    expect(_toks(t), [
      ('artist:fujiyama', 0.5),
      ('artist:motimoti067', 1.0), // 组已收口 → 不受 0.5 影响
      ('artist:ham_melon', 0.8),
      ('tail', 1.0),
    ]);
    expect(_spans(t), [
      ('0.5::artist:fujiyama,::', 0.5), // 底色恰好裹住该组,含闭记号
      ('0.8::artist:ham_melon::', 0.8),
    ]);
  });

  test('数字后接三冒号 `1.5:::` 不崩溃(开记号与收口重叠)', () {
    // 打权重时 `1.5::` 后再补一个冒号,三冒号里两对 `::` 共用中间那个,
    // 曾算出 nameStart > nameEnd 让 substring 抛 RangeError,连累注音/权重
    // 底色/富文本三处 parseToks 全崩,屏上一大片灰。现应降级为普通文本。
    for (final t in ['1:::', '1.5:::', '20:::', '-3:::']) {
      expect(() => parseToks(t), returnsNormally, reason: t);
      final spans = <WeightSpan>[];
      final toks = parseToks(t, weightSpans: spans);
      expect(toks.single.name, t, reason: '$t 整枚当普通文本'); // 未成词条权重
      expect(toks.single.effMult, 1.0, reason: t);
      expect(spans, isEmpty, reason: '$t 不铺权重底色');
    }
    // 打全收口即恢复正常上色
    expect(_toks('1.5::x::'), [('x', 1.5)]);
  });

  test('未闭合的组被下一个前缀截断,倍率不连乘', () {
    const t = '0.5::a, b, 0.8::c::';
    expect(_toks(t), [
      ('a', 0.5),
      ('b', 0.5),
      ('c', 0.8), // 不是 0.5×0.8 —— 前一组到此已被截断
    ]);
    expect(_spans(t), [('0.5::a, b, ', 0.5), ('0.8::c::', 0.8)]);
  });

  test('正常跨词条组:组内全员生效,组外不受影响', () {
    const t = '1.2::a, b::, c';
    expect(_toks(t), [('a', 1.2), ('b', 1.2), ('c', 1.0)]);
    expect(_spans(t), [('1.2::a, b::', 1.2)]);
  });

  test('单词条自身权重不当跨段组处理', () {
    const t = '1.2::a::, b';
    expect(_toks(t), [('a', 1.2), ('b', 1.0)]);
    expect(_spans(t), [('1.2::a::', 1.2)]);
  });

  test('括号组不受影响', () {
    const t = '{a, b}, c';
    expect(_toks(t), [('a', 1.05), ('b', 1.05), ('c', 1.0)]);
    expect(_spans(t), [('{a, b}', 1.05)]);
  });

  test('负权重组照常', () {
    const t = '-2::a, b::, c';
    expect(_toks(t), [('a', -2.0), ('b', -2.0), ('c', 1.0)]);
  });

  // `::` 在 NAI 里本身就是分隔符,不少人拿它当逗号使:写完一个词直接跟下一段
  // 的权重,中间不打逗号。老实现开组时把 a 一跳跳到组内容处,开记号前面那截
  // **整段丢了** —— 不成词条(没注音、没翻译、词条栏点不着),屏幕上是一截灰字。
  test('开记号前面的内容不能丢:`a::1.5::b` 里的 a 照样成词条', () {
    const t =
        'print,constellation print in grey pantyhose::1.5::gothic lolita,'
        'black lolita';
    expect(_toks(t), [
      ('print', 1.0),
      ('constellation print in grey pantyhose', 1.0), // 曾经整个消失
      ('gothic lolita', 1.5),
      ('black lolita', 1.5), // 未闭合的组延伸到文末
    ]);
    // 权重区间只圈组本身,前面那截不该被染色
    expect(_spans(t), [('1.5::gothic lolita,black lolita', 1.5)]);
  });

  test('开记号紧跟逗号时不误伤(本来就没有头部)', () {
    const t = 'a,1.5::b';
    expect(_toks(t), [('a', 1.0), ('b', 1.5)]);
  });

  // 未闭合的组右界是「下一个前缀 / 文末」截出来的,不是闭记号 —— 剥记号那步
  // 却照着 end-2 削两个字符,削掉的是用户的正文。
  test('未闭合的组不能把末尾两个字符当闭记号削掉', () {
    const t = '1.2::a, black lolita';
    expect(_toks(t), [('a', 1.2), ('black lolita', 1.2)]); // 曾经变成 black loli
  });

  // 词尾是数字的标签紧跟收口:`year 2025::` 里的 `2025::` 和权重前缀长得一样。
  // 老实现一律当前缀 —— 组被截在 `year ` 处,后文整段压上 ×2025;单词条写法
  // 恰好走内层剥数值没出事,于是看起来像「组里有逗号就认不出权重」。
  test('词尾数字紧跟收口:`year 2025::` 是收口,不是新前缀', () {
    const t = '1.2::1girl, year 2025::, solo';
    expect(_toks(t), [('1girl', 1.2), ('year 2025', 1.2), ('solo', 1.0)]);
    expect(_spans(t), [('1.2::1girl, year 2025::', 1.2)]);
    // 单词条后面还跟着别的词:曾经 solo 被压成 ×2025
    expect(_toks('1.2::year 2025::, solo'), [
      ('year 2025', 1.2),
      ('solo', 1.0),
    ]);
    // 画师名里的数字同理;收口后直接接下一个权重
    expect(_toks('1.3::artist:a, artist:motimoti067::0.8::b, c::'), [
      ('artist:a', 1.3),
      ('artist:motimoti067', 1.3),
      ('b', 0.8),
      ('c', 0.8),
    ]);
  });

  test('漏打逗号的前缀后面跟着词,仍是前缀,且不与前一组连乘', () {
    expect(_toks('0.5::a, b 0.8::c, d'), [
      ('a', 0.5),
      ('b', 0.5),
      ('c', 0.8),
      ('d', 0.8),
    ]);
  });

  test('段中收口后紧跟下一组:后一组不与前一组连乘', () {
    const t = '1.2::a, b::1.5::c, d::';
    expect(_toks(t), [
      ('a', 1.2),
      ('b', 1.2),
      ('c', 1.5), // 曾经 ×1.8
      ('d', 1.5),
    ]);
    expect(_spans(t), [('1.2::a, b::', 1.2), ('1.5::c, d::', 1.5)]);
  });

  // NAI 把 `year 2025::` 读成「从这里起权重 2025」,app 自己写权重时要补空格
  test('给词尾数字的标签加权:收口前补空格', () {
    const t = 'year 2025, 1girl';
    final (one, _) = setTokMult(t, parseToks(t).first, 1.2);
    expect(one, '1.2::year 2025 ::, 1girl');
    expect(_toks(one), [('year 2025', 1.2), ('1girl', 1.0)]);
    // 再调一次:名字不带空格,不会越叠越多
    expect(
      setTokMult(one, parseToks(one).first, 1.3).$1,
      '1.3::year 2025 ::, 1girl',
    );
    expect(
      batchSetMult('1girl, year 2025', 0, 1, 1.2),
      '1.2::1girl, year 2025 ::',
    );
    expect(sdToNaiSeg('(year_2025:1.2)'), '1.2::year 2025 ::');
    // 不以数字结尾的照旧
    expect(setTokMult('solo', parseToks('solo').first, 1.2).$1, '1.2::solo::');
  });

  // 补全选词自带「, 」,接着打收口就是 `1.2::a, ::` —— 只包着一枚词的数值组。
  // 老实现只认词自己写的数:词条栏读数 ×1、清除键灰着,按 + 写出
  // `1.2::1.1::a::, ::`,整组解析全乱。
  test('只包着一枚词的数值组,就是这枚词自己的权重', () {
    const t = '1.2::a, ::, b';
    final a = parseToks(t).first;
    expect(a.numWeight, 1.2);
    expect(a.tagMult, closeTo(1.2, 1e-9));
    expect(a.inGroup, isFalse);
    expect(setTokMult(t, a, 1.3).$1, '1.3::a, ::, b');
    expect(setTokMult(t, a, 1.0).$1, 'a, b');
    expect(clearWeight(t, a).$1, 'a, b');
    // 在文末:逗号后的空格留着,好接着打下一枚
    const tail = '1.2::a, ::';
    expect(clearWeight(tail, parseToks(tail).first).$1, 'a, ');
    // 自己的括号照常叠在上面
    const braced = '1.2::{a}, ::';
    final ba = parseToks(braced).first;
    expect(ba.tagMult, closeTo(1.26, 1e-9));
    expect(setTokMult(braced, ba, 1.3).$1, '1.3::{a}, ::');
    expect(clearWeight(braced, ba).$1, 'a, ');
  });

  test('包着多枚词的数值组:加减改组的数,清除拆掉组记号', () {
    const t = '1.2::a, b::, c';
    final b = parseToks(t)[1];
    expect(b.numWeight, 1.2);
    expect(b.inGroup, isTrue);
    final (up, at) = setTokMult(t, b, 1.25);
    expect(up, '1.25::a, b::, c');
    expect(up[at], 'b', reason: '光标跟着前缀变长平移,词条栏不跳走');
    expect(clearWeight(t, b).$1, 'a, b, c');
    // 收口紧挨着数字:改数时顺手补空格
    const y = '1.2::1girl, year 2025::';
    expect(
      setTokMult(y, parseToks(y).first, 1.3).$1,
      '1.3::1girl, year 2025 ::',
    );
  });

  // ---- 下面这些是按语法随机拼提示词、逐词对照预期权重翻出来的形态,
  // 修之前每一种都会认错词名或权重(随机对照本身见 parser_property_test)。

  test('数值权重里再套括号 / 禁用号:里层记号照样剥', () {
    // 删掉组员后常剩下这种里外颠倒的形态(`1.2::{a}, b::` 删掉 b)
    _near('1.2::{a}::', [('a', 1.26)]); // 曾经名字是 `{a}`、×1.2
    _near('1.2::[a]::', [('a', 1.2 / 1.05)]);
    final a = parseToks('1.2::~a~::').single;
    expect((a.name, a.disabled), ('a', true)); // 曾经名字 `~a~`、没禁用
    final b = parseToks('{~a~}').single;
    expect((b.name, b.disabled, b.braceLevel), ('a', true, 1));
    expect(outputOf('b, 1.2::~a~::'), 'b'); // `~` 曾经原样发给 NAI
  });

  test('数值组里套括号组', () {
    // 曾经解析成 `{b`、`c}` 两个名字,d 也被算进组里
    _near('1.2::a, {b, c}::, d', [
      ('a', 1.2),
      ('b', 1.26),
      ('c', 1.26),
      ('d', 1.0),
    ]);
  });

  test('`:3`、`<3` 这类以数字结尾的颜文字紧跟收口', () {
    _near('1.2::a, :3::, b', [('a', 1.2), (':3', 1.2), ('b', 1.0)]);
    _near('1.2::a, <3::, b', [('a', 1.2), ('<3', 1.2), ('b', 1.0)]);
    _near('1.2:::3::', [(':3', 1.2)]);
  });

  test('拿 `::` 当逗号连写:每一枚各成词条', () {
    _near('1.2::a::0.8::b::', [('a', 1.2), ('b', 0.8)]); // 曾经是 `a::0.8::b`
    _near('1.5::rain, night:: black shoes', [
      ('rain', 1.5),
      ('night', 1.5),
      ('black shoes', 1.0), // 曾经和 night 糊成一枚,还带着 ×1.5
    ]);
    _near('1.2::a, b::1.5::c', [('a', 1.2), ('b', 1.2), ('c', 1.5)]);
    _near('1.2::a::{b, c}', [('a', 1.2), ('b', 1.05), ('c', 1.05)]);
    _near('1.2::{a, b}::c', [('a', 1.26), ('b', 1.26), ('c', 1.0)]);
    expect(parseToks('1.2::a::~b~').last.name, 'b');
  });

  test('没收口的组被括号里的前缀截断:不连乘', () {
    _near('1.2::a, {1.2::b::}', [('a', 1.2), ('b', 1.26)]); // 曾经 b ×1.512
  });
}

/// 逐词条对照 (名字, 有效倍率),倍率按浮点容差比
void _near(String text, List<(String, double)> exp) {
  final got = _toks(text);
  expect(
    [for (final g in got) g.$1],
    [for (final e in exp) e.$1],
    reason: text,
  );
  for (var i = 0; i < exp.length; i++) {
    expect(got[i].$2, closeTo(exp[i].$2, 1e-9), reason: '$text · ${exp[i].$1}');
  }
}
