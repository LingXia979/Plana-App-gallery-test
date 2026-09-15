// 弹层关掉后别把焦点还给输入框、把软键盘顶出来(InputFocusGuard)。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/ui/input_focus_guard.dart';

void main() {
  late FocusNode focus;
  late BuildContext pageContext;

  Future<void> pumpPage(WidgetTester tester, {InputFocusGuard? guard}) async {
    focus = FocusNode();
    addTearDown(focus.dispose);
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [?guard],
        home: Scaffold(
          body: Builder(
            builder: (context) {
              pageContext = context;
              return TextField(focusNode: focus);
            },
          ),
        ),
      ),
    );
    focus.requestFocus();
    await tester.pump();
    expect(focus.hasFocus, isTrue);
  }

  Future<void> openAndCloseSheet(WidgetTester tester) async {
    final closed = showModalBottomSheet<void>(
      context: pageContext,
      builder: (_) => const SizedBox(height: 120),
    );
    await tester.pumpAndSettle();
    expect(focus.hasFocus, isFalse, reason: '弹层开着时焦点在弹层上');
    Navigator.of(pageContext).pop();
    await tester.pumpAndSettle();
    await closed;
  }

  testWidgets('前提:不挂守卫时,弹层一关焦点就回到输入框', (tester) async {
    await pumpPage(tester);
    await openAndCloseSheet(tester);
    expect(focus.hasFocus, isTrue);
  });

  testWidgets('挂了守卫:弹层关掉后焦点不回输入框', (tester) async {
    await pumpPage(tester, guard: InputFocusGuard());
    await openAndCloseSheet(tester);
    expect(focus.hasFocus, isFalse);
  });

  testWidgets('推之前自己收了焦点、关掉后自己要回来的,照旧能要回来', (tester) async {
    await pumpPage(tester, guard: InputFocusGuard());
    focus.unfocus();
    await tester.pump();
    final closed = showModalBottomSheet<void>(
      context: pageContext,
      builder: (_) => const SizedBox(height: 120),
    );
    await tester.pumpAndSettle();
    Navigator.of(pageContext).pop();
    await closed;
    focus.requestFocus();
    await tester.pumpAndSettle();
    expect(focus.hasFocus, isTrue);
  });
}
