// 权重编辑(词条栏加减 / 清除 / 删除、多选和芯片的批量操作)在复杂写法下
// 不能把提示词改坏:改完重新解析,没动到的词名字和权重都得原样。
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/features/editor/editor_models.dart';

/// 逐词条对照 (名字, 有效倍率),倍率按浮点容差比
void _near(String text, List<(String, double)> exp) {
  final got = parseToks(text);
  expect(
    [for (final t in got) t.name],
    [for (final e in exp) e.$1],
    reason: text,
  );
  for (var i = 0; i < exp.length; i++) {
    expect(
      got[i].effMult,
      closeTo(exp[i].$2, 1e-9),
      reason: '$text · ${exp[i].$1}',
    );
  }
}

void main() {
  // 老实现按逗号段量改写范围,会把组的开记号 / 收口一起卷进去:芯片模式在
  // 一个组框里点两颗按 +,得到 `1.3::a, b::, c::`,c 后面挂着孤零零的 `::`。
  test('多选只选中组里的一部分:先拆组,没选中的词权重不变', () {
    const t = '1.2::a, b, c::, d';
    _near(batchSetMult(t, 0, 1, 1.3), [
      ('a', 1.3),
      ('b', 1.3),
      ('c', 1.2),
      ('d', 1),
    ]);
    _near(batchClearWeight(t, 1, 2), [
      ('a', 1.2),
      ('b', 1),
      ('c', 1),
      ('d', 1),
    ]);
    _near(batchWrap(t, 1, 2, up: true), [
      ('a', 1.2),
      ('b', 1.26),
      ('c', 1.26),
      ('d', 1),
    ]);
    // 括号组里挑两枚改数值:嵌在括号组里合法,括号组不用拆
    expect(batchSetMult('{a, b, c}', 1, 2, 1.3), '{a, 1.3::b, c::}');
  });

  test('选区跨过组边界', () {
    const t = '1.2::a, b::, c';
    _near(batchWrap(t, 1, 2, up: true), [('a', 1.2), ('b', 1.26), ('c', 1.05)]);
    _near(batchClearWeight(t, 1, 2), [('a', 1.2), ('b', 1), ('c', 1)]);
    _near(batchDelete(t, 0, 0).$1, [('b', 1.2), ('c', 1)]);
  });

  test('删掉组里唯一的词:连组记号一起删,不留 `1.2::::` 空壳', () {
    const t = '1.2::a, ::, b';
    expect(deleteTok(t, parseToks(t).first).$1, 'b');
    const braced = 'x, {a, }';
    expect(deleteTok(braced, parseToks(braced)[1]).$1, 'x');
  });

  // `1.5::a, 1.2::b::, c` 里 1.5 那组没写收口,是被 b 的前缀截断的。拆掉这个
  // 前缀,1.5 就会一路延伸过来 —— 曾经 b(删除时连 c)都成了 ×1.5。
  test('拆掉截断着前一组的前缀:原处替前一组收口', () {
    const t = '1.5::a, 1.2::b::, c';
    final b = parseToks(t)[1];
    _near(clearWeight(t, b).$1, [('a', 1.5), ('b', 1), ('c', 1)]);
    _near(setTokMult(t, b, 1).$1, [('a', 1.5), ('b', 1), ('c', 1)]);
    _near(deleteTok(t, b).$1, [('a', 1.5), ('c', 1)]);
  });

  test('连写的词:改一枚不会和旁边那枚粘成一个', () {
    const t = '1.2::a::b';
    expect(clearWeight(t, parseToks(t).first).$1, 'a, b'); // 曾经是 `ab`
    const t2 = 'a, 1.2::b, ::c';
    _near(deleteTok(t2, parseToks(t2)[1]).$1, [('a', 1), ('c', 1)]);
    // 光标停在连写的接缝上算后一枚,词条栏不跳到前一枚
    expect(tokIndexAt(t, 8), 1);
  });

  test('里层禁用号:切换、清除、加减都认得', () {
    const t = '1.2::~a~::';
    expect(
      parseToks(toggleTokDisabled(t, parseToks(t).single)).single.disabled,
      isFalse,
    );
    const t2 = '{~a~}';
    final cleared = parseToks(clearWeight(t2, parseToks(t2).single).$1).single;
    expect((cleared.disabled, cleared.braceLevel), (true, 0));
    // 加减不丢括号:括号挪到数值外面
    const t3 = '1.2::{a}::';
    expect(setTokMult(t3, parseToks(t3).single, 1.3).$1, '{1.3::a::}');
  });

  test('记号残片上点清除 / 加减不崩溃', () {
    const t = '0.5::x9-,\n[::,';
    for (final k in parseToks(t)) {
      expect(() => clearWeight(t, k), returnsNormally);
      expect(() => setTokMult(t, k, 1), returnsNormally);
    }
  });

  test('折叠头后面紧跟换行也认得(剔掉禁用的第一枚后常见)', () {
    expect(outputOf('<#f: ~a~\nb#>'), 'b'); // 曾经 `<#f:` 原样漏给 NAI
  });
}
