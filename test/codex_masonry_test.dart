// 法典瀑布流几何(CodexMasonryLayout)。
//
// 这份几何交给 SliverGrid 按下标取,SliverGrid 只按「首个 / 末个可能可见的下标」
// 去建子项 —— 两个下标算紧了,滚到某些位置就会凭空缺一张;而瀑布流的底边不单调,
// 最容易在这儿算错。所以除了摆放规则,还拿随机数据把可见区间扫一遍,换列数过渡
// 的插值布局也一起扫。
import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/ui/pinch_columns.dart';
import 'package:plana_app/features/inspiration/codex/codex_masonry.dart';
import 'package:plana_app/features/inspiration/codex/codex_models.dart';

CodexEntry _e(int i, int w, int h) =>
    CodexEntry(id: '$i', title: '', tags: '', imageWidth: w, imageHeight: h);

SliverConstraints _constraints(double width) => SliverConstraints(
  axisDirection: AxisDirection.down,
  growthDirection: GrowthDirection.forward,
  userScrollDirection: ScrollDirection.idle,
  scrollOffset: 0,
  precedingScrollExtent: 0,
  overlap: 0,
  remainingPaintExtent: 600,
  crossAxisExtent: width,
  crossAxisDirection: AxisDirection.right,
  viewportMainAxisExtent: 600,
  remainingCacheExtent: 1100,
  cacheOrigin: 0,
);

/// 与 [a, b) 相交的下标,都得落在 SliverGrid 会去建的区间里。
void _expectCovers(SliverGridLayout layout, int n, double a, double b) {
  final lo = layout.getMinChildIndexForScrollOffset(a);
  final hi = layout.getMaxChildIndexForScrollOffset(b);
  for (var i = 0; i < n; i++) {
    final g = layout.getGeometryForChildIndex(i);
    if (g.scrollOffset < b && g.trailingScrollOffset > a) {
      expect(
        i >= lo && i <= hi,
        isTrue,
        reason: '[$a, $b) 里的第 $i 条不在 [$lo, $hi]',
      );
    }
  }
  if (lo < n) expect(hi, greaterThanOrEqualTo(lo), reason: '末位不能早于首位');
}

void main() {
  test('按顺序进当时最矮的一列,一样矮取靠左;卡高 = 列宽 / 比例', () {
    // 宽 210、缝 10、两列:列宽 100
    final layout = CodexMasonryLayout(
      [_e(0, 100, 100), _e(1, 100, 200), _e(2, 100, 100), _e(3, 200, 100)],
      cols: 2,
      width: 210,
      gap: 10,
    );
    SliverGridGeometry g(int i) => layout.getGeometryForChildIndex(i);
    expect(layout.columnWidth, 100);

    expect((g(0).crossAxisOffset, g(0).scrollOffset), (0, 0));
    expect(g(0).mainAxisExtent, 100);
    expect((g(1).crossAxisOffset, g(1).scrollOffset), (110, 0));
    expect(g(1).mainAxisExtent, 200);
    // 左列到 110 比右列 210 矮
    expect((g(2).crossAxisOffset, g(2).scrollOffset), (0, 110));
    // 左列 220 比右列 210 高,进右列;横图只有 50 高
    expect((g(3).crossAxisOffset, g(3).scrollOffset), (110, 210));
    expect(g(3).mainAxisExtent, 50);

    expect(layout.computeMaxScrollOffset(4), 260);
  });

  test('没有尺寸的词条按竖图 .75 排,不塌成 0 高', () {
    final layout = CodexMasonryLayout(
      [const CodexEntry(id: 'x', title: '', tags: '')],
      cols: 1,
      width: 300,
      gap: 10,
    );
    expect(layout.getGeometryForChildIndex(0).mainAxisExtent, 400);
  });

  test('越界下标给末尾的空格子,空批次不崩', () {
    final layout = CodexMasonryLayout(
      [_e(0, 1, 1)],
      cols: 2,
      width: 210,
      gap: 10,
    );
    final g = layout.getGeometryForChildIndex(5);
    expect(g.scrollOffset, 100);
    expect(g.mainAxisExtent, 0);

    final empty = CodexMasonryLayout([], cols: 3, width: 300, gap: 10);
    expect(empty.computeMaxScrollOffset(0), 0);
    expect(empty.getMinChildIndexForScrollOffset(0), 0);
    expect(empty.getMaxChildIndexForScrollOffset(500), 0);
  });

  test('随机批次:任意可见区间里的每一条都在建的范围内(含换列过渡的插值)', () {
    final r = math.Random(7);
    final entries = [
      for (var i = 0; i < 400; i++)
        _e(i, 200 + r.nextInt(1800), 200 + r.nextInt(1800)),
    ];
    final masonry = CodexMasonry(gap: 10);
    const width = 341.0;
    for (var cols = 1; cols <= 4; cols++) {
      final layout = masonry.layout(entries, cols, width);
      final end = layout.computeMaxScrollOffset(entries.length);
      for (var k = 0; k < 300; k++) {
        final a = r.nextDouble() * end;
        _expectCovers(layout, entries.length, a, a + 20 + r.nextDouble() * 900);
      }
    }
    for (final (from, to) in [(2, 3), (3, 1), (4, 2)]) {
      for (final t in [.2, .5, .9]) {
        final layout = ZoomGridDelegate(
          (n) => masonry.delegate(entries, n),
          from,
          to,
          t,
        ).getLayout(_constraints(width));
        final end = layout.computeMaxScrollOffset(entries.length);
        for (var k = 0; k < 200; k++) {
          final a = r.nextDouble() * end;
          _expectCovers(layout, entries.length, a, a + 600);
        }
      }
    }
  });

  test('几何按(批次, 列数, 宽)缓存;换一批词条整份作废', () {
    final masonry = CodexMasonry(gap: 10);
    final a = [_e(0, 1, 1), _e(1, 1, 2)];
    final first = masonry.layout(a, 2, 300);
    expect(identical(masonry.layout(a, 2, 300), first), isTrue);
    expect(identical(masonry.layout(a, 3, 300), first), isFalse);
    expect(identical(masonry.layout([...a], 2, 300), first), isFalse);
  });

  testWidgets('交给 SliverGrid 真跑:滚到底、来回跳、过渡中都不缺格也不报断言', (
    tester,
  ) async {
    final r = math.Random(3);
    final entries = [
      for (var i = 0; i < 300; i++)
        _e(i, 300 + r.nextInt(1500), 300 + r.nextInt(1500)),
    ];
    final masonry = CodexMasonry(gap: 10);
    final ctrl = ScrollController();
    addTearDown(ctrl.dispose);

    Future<void> pumpGrid(SliverGridDelegate delegate) =>
        tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: CustomScrollView(
              controller: ctrl,
              slivers: [
                SliverGrid(
                  gridDelegate: delegate,
                  delegate: SliverChildBuilderDelegate(
                    (_, i) => SizedBox(key: ValueKey(i)),
                    childCount: entries.length,
                  ),
                ),
              ],
            ),
          ),
        );

    // 800 宽的测试画布,三列时列宽 260
    await pumpGrid(masonry.delegate(entries, 3));
    final layout = masonry.layout(entries, 3, 800);
    for (final to in [0.0, 3000.0, 1e9, 1234.0, 0.0]) {
      ctrl.jumpTo(to.clamp(0, ctrl.position.maxScrollExtent));
      await tester.pump();
      // 视口里该有的每一张都建出来了,位置对得上
      final top = ctrl.offset;
      for (var i = 0; i < entries.length; i++) {
        final g = layout.getGeometryForChildIndex(i);
        if (g.scrollOffset < top + 600 && g.trailingScrollOffset > top) {
          final rect = tester.getRect(find.byKey(ValueKey(i)));
          expect(rect.left, closeTo(g.crossAxisOffset, .01));
          expect(rect.top, closeTo(g.scrollOffset - top, .01));
        }
      }
    }
    expect(
      ctrl.position.maxScrollExtent,
      closeTo(layout.computeMaxScrollOffset(entries.length) - 600, .01),
    );

    for (final t in [.1, .4, .8]) {
      ctrl.jumpTo(1500);
      await pumpGrid(
        ZoomGridDelegate((n) => masonry.delegate(entries, n), 3, 2, t),
      );
    }
    expect(tester.takeException(), isNull);
  });
}
