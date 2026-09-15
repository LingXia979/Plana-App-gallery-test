// 底栏可以藏掉「AI」那一格。藏的是**入口**,逻辑下标(kTab*)一个都不动 ——
// 跨页跳转全靠那几个常量,跟着挪的话「生成完跳图库」「缺 token 跳我的」
// 会集体错位,而错位表现是「点了跳到隔壁页」,测不出来只能靠人撞见。
import 'package:flutter_test/flutter_test.dart';

import 'package:plana_app/core/theme/theme_settings.dart';
import 'package:plana_app/features/shell/shell_state.dart';

/// 与 AppShell 里那份保持一致:可见格 → 逻辑下标。
List<int> visibleTabs({required bool showAi}) => [
  kTabCreate,
  kTabGallery,
  if (showAi) kTabAssistant,
  kTabInspiration,
  kTabProfile,
];

void main() {
  group('底栏格子映射', () {
    test('开着 AI:五格,可见位次就是逻辑下标', () {
      final tabs = visibleTabs(showAi: true);
      expect(tabs.length, 5);
      for (var i = 0; i < tabs.length; i++) {
        expect(tabs[i], i, reason: '开着的时候两套下标必须重合');
      }
    });

    test('关掉 AI:四格,后面两格的逻辑下标不变', () {
      final tabs = visibleTabs(showAi: false);
      expect(tabs, [kTabCreate, kTabGallery, kTabInspiration, kTabProfile]);
      // 「我的」在底栏是第 4 格,但跳转仍然用 kTabProfile(4)
      expect(tabs.indexOf(kTabProfile), 3);
      expect(kTabProfile, 4);
    });

    test('点第 3 格拿到的是灵感,不是 AI', () {
      expect(visibleTabs(showAi: false)[2], kTabInspiration);
      expect(visibleTabs(showAi: true)[2], kTabAssistant);
    });

    test('关掉之后 AI 不在可见表里 —— selectedIndex 会是 -1,调用方要兜住', () {
      expect(visibleTabs(showAi: false).indexOf(kTabAssistant), -1);
    });
  });

  group('底栏开关的持久化', () {
    test('默认显示', () {
      expect(const ThemeSettings().showAssistant, isTrue);
    });

    test('存得下也读得回来', () {
      const s = ThemeSettings(showAssistant: false);
      expect(ThemeSettings.fromJson(s.toJson()).showAssistant, isFalse);
    });

    test('老存档没这个字段:按显示算,别把人的 tab 弄没了', () {
      expect(ThemeSettings.fromJson(const {}).showAssistant, isTrue);
    });

    test('copyWith 只动指定那一项', () {
      const s = ThemeSettings(haptics: false);
      final n = s.copyWith(showAssistant: false);
      expect(n.showAssistant, isFalse);
      expect(n.haptics, isFalse, reason: '没提到的项不该被顺手打开');
    });
  });
}
