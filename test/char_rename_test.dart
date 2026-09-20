// 点角色卡上的名字改名。
//
// 两处容易一起坏:热区只包名字本身,外层那圈仍是「点开编辑器」,里层得先拿到
// 这一下;留空要回到默认的「角色 N」—— 真存个空名字,那一行就只剩电源开关和
// 站位徽章,谁是谁看不出来。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/features/editor/editor_page.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/generate/widgets/character_card.dart';

/// 摆两张角色卡的面板(addCharacter 自己会把面板展开)。
///
/// 存储走 `AppStores.ephemeral()`:`open()` 是真的读盘,在 testWidgets 的
/// fake-async 里那个 await 永远回不来,整个测试干等到超时。
Future<GenerateNotifier> _pumpCard(WidgetTester tester) async {
  final c = ProviderContainer(
    overrides: [appStoresProvider.overrideWithValue(AppStores.ephemeral())],
  );
  addTearDown(c.dispose);
  final gen = c.read(generateProvider.notifier);
  gen.addCharacter();
  gen.addCharacter();

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: AppTheme.light(),
        home: const Scaffold(
          body: SingleChildScrollView(child: CharacterCard()),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return gen;
}

List<String> _names(GenerateNotifier gen) => [
  for (final c in gen.state.characters) c.name,
];

/// 工作区落盘是 800ms 防抖,计时器留到收尾会被判「还有挂着的 Timer」。
Future<void> _flushAutosave(WidgetTester tester) =>
    tester.pump(const Duration(seconds: 1));

void main() {
  testWidgets('点名字弹改名,保存后卡上换成新名字', (tester) async {
    final gen = await _pumpCard(tester);

    await tester.tap(find.text('角色 2'));
    await tester.pumpAndSettle();
    expect(find.text('重命名'), findsOneWidget);
    expect(find.byType(EditorPage), findsNothing, reason: '里层先拿到这一下');

    await tester.enterText(find.byType(TextField), '  小夜  ');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(_names(gen), ['角色 1', '小夜'], reason: '两头空白去掉,只改点到的那张');
    expect(find.text('小夜'), findsOneWidget);
    await _flushAutosave(tester);
  });

  testWidgets('留空回到默认的「角色 N」', (tester) async {
    final gen = await _pumpCard(tester);
    gen.updateCharacter(gen.state.characters[1].id, name: '小夜');
    await tester.pumpAndSettle();

    await tester.tap(find.text('小夜'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '   ');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(_names(gen), ['角色 1', '角色 2']);
    await _flushAutosave(tester);
  });

  testWidgets('取消不动名字', (tester) async {
    final gen = await _pumpCard(tester);

    await tester.tap(find.text('角色 1'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '小夜');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(_names(gen), ['角色 1', '角色 2']);
    await _flushAutosave(tester);
  });
}
