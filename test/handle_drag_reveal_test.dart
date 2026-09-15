// 编辑页正文拖选区手柄时的贴边滚动。
//
// 安卓上拖**起点**手柄往上划选,框架每挪一下滚两次、方向相反(当场露起点往上,
// 帧尾露末尾往下),正文来回抽。这里用真的 TextField 和手柄走一遍,
// 逐帧看滚动位置:往上拖只许往上走。
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plana_app/core/theme/editor_theme.dart';
import 'package:plana_app/features/editor/widgets/annotated_field.dart';
import 'package:plana_app/features/editor/widgets/rich_tag_controller.dart';

Future<({RichTagController ctrl, ScrollController scroll})> _pump(
  WidgetTester tester,
) async {
  final ctrl = RichTagController(
    text: List.generate(120, (i) => 'tag$i').join(', '),
  )..showTrans = false;
  final focus = FocusNode();
  final scroll = ScrollController();
  addTearDown(() {
    ctrl.dispose();
    focus.dispose();
    scroll.dispose();
  });
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Theme(
          data: editorTheme(context),
          child: Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: SizedBox(
                height: 320,
                child: AnnotatedField(
                  controller: ctrl,
                  focusNode: focus,
                  hint: '',
                  showTrans: false,
                  showWeightWash: false,
                  scrollController: scroll,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  return (ctrl: ctrl, scroll: scroll);
}

void main() {
  testWidgets(
    '往上拖起点手柄:正文一路往上滚,不往回弹',
    (tester) async {
      final (:ctrl, :scroll) = await _pump(tester);
      final field = tester.getRect(find.byType(AnnotatedField));
      scroll.jumpTo(scroll.position.maxScrollExtent / 2);
      await tester.pumpAndSettle();

      // 长按视口靠下的一个词,选中它、出手柄
      await tester.longPressAt(Offset(field.left + 60, field.bottom - 60));
      await tester.pumpAndSettle();
      expect(ctrl.selection.isCollapsed, isFalse);

      // 起点手柄的触摸盒中心:锚点 = Material 左手柄 (22, 0) + 居中进 48 见方的内边距 (13, 13)
      final editable = tester.renderObject<RenderEditable>(
        find.byWidgetPredicate((w) => w.runtimeType.toString() == '_Editable'),
      );
      final start = editable.localToGlobal(
        editable.getEndpointsForSelection(ctrl.selection).first.point,
      );
      final gesture = await tester.startGesture(start + const Offset(-11, 11));

      final offsets = <double>[scroll.offset];
      // 先一路拖到视口顶上,再在顶边一点点往上蹭,让框架持续贴边滚
      var y = start.dy + 11;
      while (y > field.top + 4) {
        await gesture.moveBy(const Offset(0, -12));
        y -= 12;
        await tester.pump(const Duration(milliseconds: 16));
        offsets.add(scroll.offset);
      }
      for (var i = 0; i < 40; i++) {
        await gesture.moveBy(const Offset(0, -2));
        await tester.pump(const Duration(milliseconds: 16));
        await tester.pump(const Duration(milliseconds: 120)); // 等帧尾那次动画跑完
        offsets.add(scroll.offset);
      }
      await gesture.up();
      await tester.pumpAndSettle();
      offsets.add(scroll.offset);

      expect(offsets.last, lessThan(offsets.first), reason: '应当贴边往上滚过');
      for (var i = 1; i < offsets.length; i++) {
        expect(
          offsets[i],
          lessThanOrEqualTo(offsets[i - 1] + 0.5),
          reason: '第 $i 帧往回滚了:$offsets',
        );
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets('往下拖终点手柄:照旧一路往下滚', (tester) async {
    final (:ctrl, :scroll) = await _pump(tester);
    final field = tester.getRect(find.byType(AnnotatedField));
    scroll.jumpTo(scroll.position.maxScrollExtent / 2);
    await tester.pumpAndSettle();

    await tester.longPressAt(Offset(field.left + 60, field.top + 40));
    await tester.pumpAndSettle();
    expect(ctrl.selection.isCollapsed, isFalse);

    // 终点手柄:Material 右手柄锚点 (0, 0) + 内边距 (13, 13)
    final editable = tester.renderObject<RenderEditable>(
      find.byWidgetPredicate((w) => w.runtimeType.toString() == '_Editable'),
    );
    final end = editable.localToGlobal(
      editable.getEndpointsForSelection(ctrl.selection).last.point,
    );
    final gesture = await tester.startGesture(end + const Offset(11, 11));

    final offsets = <double>[scroll.offset];
    var y = end.dy + 11;
    while (y < field.bottom - 4) {
      await gesture.moveBy(const Offset(0, 12));
      y += 12;
      await tester.pump(const Duration(milliseconds: 16));
      offsets.add(scroll.offset);
    }
    for (var i = 0; i < 40; i++) {
      await gesture.moveBy(const Offset(0, 2));
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 120));
      offsets.add(scroll.offset);
    }
    await gesture.up();
    await tester.pumpAndSettle();
    offsets.add(scroll.offset);

    expect(offsets.last, greaterThan(offsets.first), reason: '应当贴边往下滚过');
    for (var i = 1; i < offsets.length; i++) {
      expect(
        offsets[i],
        greaterThanOrEqualTo(offsets[i - 1] - 0.5),
        reason: '第 $i 帧往回滚了:$offsets',
      );
    }
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
