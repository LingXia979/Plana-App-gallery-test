// 双指捏合换网格列数(PinchColumnsMixin)。
//
// 容易出岔子的全在手势竞技场里:两指底下的格子会不会被当成点了一下、单指滚动
// 会不会被新垫进去的认领识别器截胡、先滚再落第二指时列表停不停。这些光看代码
// 判断不牢,这里真发指针事件跑一遍。另外钉两条:过渡期间不重建整页(页面 build
// 里的排序、筛选很贵),以及捏到一半网格被拆掉之后不会冻住。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/ui/pinch_columns.dart';
import 'package:plana_app/core/util/haptics.dart';

class _Harness extends StatefulWidget {
  const _Harness({this.initial = 3, this.onTap});

  final int initial;
  final void Function(int index)? onTap;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness>
    with TickerProviderStateMixin, PinchColumnsMixin {
  final ctrl = ScrollController();
  final changes = <int>[];
  int builds = 0;
  bool _gridShown = true;

  void showGrid(bool shown) => setState(() => _gridShown = shown);

  @override
  int get initialGridColumns => widget.initial;

  @override
  int get minGridColumns => 1;

  @override
  int get maxGridColumns => 4;

  @override
  ScrollController get pinchScrollController => ctrl;

  @override
  void onGridColumnsChanged(int cols) => changes.add(cols);

  @override
  void dispose() {
    ctrl.dispose();
    super.dispose();
  }

  // 测试画布 800×600,方格无间距:3 列时格宽 266.7,2 列 400
  @override
  Widget build(BuildContext context) {
    builds++;
    return MaterialApp(
      home: Scaffold(
        body: !_gridShown
            ? const SizedBox.expand()
            : pinchLayer(
                child: pinchBuilder(
                  (_) => CustomScrollView(
                    controller: ctrl,
                    physics: pinchPhysics(),
                    slivers: [
                      SliverGrid(
                        gridDelegate: zoomGridDelegate(
                          (n) => SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: n,
                          ),
                        ),
                        delegate: SliverChildBuilderDelegate(
                          (_, i) => GestureDetector(
                            key: ValueKey(i),
                            onTap: () => widget.onTap?.call(i),
                            child: const ColoredBox(color: Colors.grey),
                          ),
                          childCount: 300,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
      ),
    );
  }
}

_HarnessState _state(WidgetTester tester) =>
    tester.state<_HarnessState>(find.byType(_Harness));

double _cellWidth(WidgetTester tester) =>
    tester.getSize(find.byKey(const ValueKey(0))).width;

void main() {
  setUp(() => Haptics.enabled = false); // 测试里没有平台通道

  testWidgets('撑开少一列、收拢多一列;过渡中格子连续变宽', (tester) async {
    await tester.pumpWidget(const _Harness());
    expect(_cellWidth(tester), closeTo(800 / 3, .01));

    final a = await tester.startGesture(const Offset(300, 300), pointer: 1);
    final b = await tester.startGesture(const Offset(500, 300), pointer: 2);
    await b.moveTo(const Offset(560, 300)); // 指间距 200 → 260,1.3 倍
    await tester.pump();
    expect(_state(tester).changes, [2], reason: '过渡一起步就回调目标列数');

    await tester.pump(const Duration(milliseconds: 60));
    final mid = _cellWidth(tester);
    expect(mid, greaterThan(800 / 3 + 1));
    expect(mid, lessThan(399), reason: '几何插值,不是一步跳过去');

    await a.up();
    await b.up();
    await tester.pumpAndSettle();
    expect(_state(tester).gridColumns, 2);
    expect(_cellWidth(tester), closeTo(400, .01));

    final c = await tester.startGesture(const Offset(300, 300), pointer: 3);
    final d = await tester.startGesture(const Offset(500, 300), pointer: 4);
    await d.moveTo(const Offset(440, 300)); // 200 → 140,0.7 倍
    await c.up();
    await d.up();
    await tester.pumpAndSettle();
    expect(_state(tester).changes, [2, 3]);
    expect(_state(tester).gridColumns, 3);
  });

  testWidgets('上一档还在过渡时接着捏:从目标那一档起算', (tester) async {
    await tester.pumpWidget(const _Harness());
    final a = await tester.startGesture(const Offset(200, 300), pointer: 1);
    final b = await tester.startGesture(const Offset(400, 300), pointer: 2);
    await b.moveTo(const Offset(460, 300)); // 3 → 2,基准重取为 260
    await tester.pump(const Duration(milliseconds: 50));
    await b.moveTo(const Offset(540, 300)); // 260 → 340,再一档:2 → 1
    await tester.pump(const Duration(milliseconds: 50));
    await b.moveTo(const Offset(420, 300)); // 340 → 220,反着捏:1 → 2,不是跨到 4
    await a.up();
    await b.up();
    await tester.pumpAndSettle();
    expect(_state(tester).changes, [2, 1, 2]);
    expect(_state(tester).gridColumns, 2);
  });

  testWidgets('到头了不换档,也不回调', (tester) async {
    await tester.pumpWidget(const _Harness(initial: 1));
    final a = await tester.startGesture(const Offset(300, 300), pointer: 1);
    final b = await tester.startGesture(const Offset(500, 300), pointer: 2);
    await b.moveTo(const Offset(600, 300));
    await a.up();
    await b.up();
    await tester.pumpAndSettle();
    expect(_state(tester).changes, isEmpty);
    expect(_state(tester).gridColumns, 1);
  });

  testWidgets('初始列数越界时夹回;jumpGridColumns 不走过渡', (tester) async {
    await tester.pumpWidget(const _Harness(initial: 9));
    expect(_state(tester).gridColumns, 4);
    _state(tester).jumpGridColumns(2);
    await tester.pump();
    expect(_cellWidth(tester), closeTo(400, .01));
    expect(_state(tester).changes, isEmpty, reason: '程序换列数不算用户捏出来的');
  });

  testWidgets('两指落在格子上再抬起,不算点了一下;单指点按照常', (tester) async {
    final taps = <int>[];
    await tester.pumpWidget(_Harness(onTap: taps.add));

    final a = await tester.startGesture(const Offset(100, 100), pointer: 1);
    await tester.pump(const Duration(milliseconds: 150));
    final b = await tester.startGesture(const Offset(400, 100), pointer: 2);
    await tester.pump(const Duration(milliseconds: 150));
    await a.up();
    await b.up();
    await tester.pumpAndSettle();
    expect(taps, isEmpty);

    await tester.tapAt(const Offset(100, 100));
    await tester.pumpAndSettle();
    expect(taps, [0]);
  });

  testWidgets('单指拖动照常滚动', (tester) async {
    await tester.pumpWidget(const _Harness());
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(_state(tester).ctrl.offset, greaterThan(200));
  });

  testWidgets('捏合、过渡、落定都不重建整页,只重建网格那一块', (tester) async {
    await tester.pumpWidget(const _Harness());
    final builds = _state(tester).builds;
    final a = await tester.startGesture(const Offset(300, 300), pointer: 1);
    final b = await tester.startGesture(const Offset(500, 300), pointer: 2);
    await tester.pump();
    await b.moveTo(const Offset(560, 300));
    await tester.pump(const Duration(milliseconds: 60));
    await a.up();
    await b.up();
    await tester.pumpAndSettle();
    expect(_cellWidth(tester), closeTo(400, .01), reason: '网格照样跟着换了');
    expect(_state(tester).builds, builds);
  });

  testWidgets('捏到一半网格被拆掉,松手后网格回来不冻住', (tester) async {
    await tester.pumpWidget(const _Harness());
    final a = await tester.startGesture(const Offset(300, 300), pointer: 1);
    final b = await tester.startGesture(const Offset(500, 300), pointer: 2);
    await tester.pump();

    // 比如搜索落地、结果变空,网格换成了空态;手指这时才抬起
    _state(tester).showGrid(false);
    await tester.pump();
    await a.up();
    await b.up();
    _state(tester).showGrid(true);
    await tester.pumpAndSettle();

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(_state(tester).ctrl.offset, greaterThan(200));
  });

  testWidgets('先单指滚起来再落第二指:列表停住,松手也不甩', (tester) async {
    await tester.pumpWidget(const _Harness());
    final a = await tester.startGesture(const Offset(300, 400), pointer: 1);
    await a.moveBy(const Offset(0, -30)); // 越过起拖门槛
    await a.moveBy(const Offset(0, -30));
    await tester.pump();
    final before = _state(tester).ctrl.offset;
    expect(before, greaterThan(0));

    final b = await tester.startGesture(const Offset(500, 340), pointer: 2);
    await tester.pump();
    // 竖着挪第二指:指间距几乎不变,不触发换档,只看列表动不动
    await b.moveBy(const Offset(0, -40));
    await b.moveBy(const Offset(0, -40));
    await tester.pump();
    expect(_state(tester).ctrl.offset, before);

    await b.up();
    await a.up();
    await tester.pumpAndSettle();
    expect(_state(tester).ctrl.offset, before);
    expect(_state(tester).changes, isEmpty);
  });
}
