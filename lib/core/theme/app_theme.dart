import 'package:flutter/material.dart';
import 'package:material_color_utilities/material_color_utilities.dart'
    show Hct, SchemeTonalSpot;

import '../ui/slide_back_transitions.dart';

/// 全局主题。当前阶段按用户要求使用 M3 默认配色(基准种子色),
/// 组件一律走语义角色(primary/surfaceContainer* 等),
/// 将来切 NAI 品牌皮肤时只需替换这里的 ColorScheme。
abstract final class AppTheme {
  /// 默认种子色:浅蓝(与「外观」页 sky 档一致,可在那里换其他种子)。
  static const Color seed = Color(0xFF4FA3E3);

  static ThemeData light([Color? seedColor]) =>
      _build(Brightness.light, seedColor ?? seed);

  static ThemeData dark([Color? seedColor]) =>
      _build(Brightness.dark, seedColor ?? seed);

  static ThemeData _build(Brightness brightness, Color seedColor) {
    final scheme = _widenSurfaces(
      ColorScheme.fromSeed(seedColor: seedColor, brightness: brightness),
      seedColor,
      brightness,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      splashFactory: InkSparkle.splashFactory,
      visualDensity: VisualDensity.standard,
      navigationBarTheme: NavigationBarThemeData(
        height: 68,
        backgroundColor: scheme.surfaceContainer,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        modalBackgroundColor: scheme.surfaceContainerLow,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
      ),
      // 二级页左右滑动,不跟手(见 SlideBackPageTransitionsBuilder)。
      // 默认那套预测性返回松手后页面直接消失,和进场动画接不上。
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {TargetPlatform.android: SlideBackPageTransitionsBuilder()},
      ),
    );
  }

  /// M3 默认 surface 阶梯太贴(暗色 背景N6/卡片N10,亮色 背景N98/卡片N96),
  /// 层级观感弱。用种子的中性调色板重排一条间距更大的阶梯:
  /// 暗色 背景压深、容器逐级提亮;亮色改「灰底白卡」,容器逐级压灰。
  static ColorScheme _widenSurfaces(
    ColorScheme s,
    Color seedColor,
    Brightness brightness,
  ) {
    // 与 fromSeed 同源:默认变体 tonalSpot 的中性调色板
    final neutral = SchemeTonalSpot(
      sourceColorHct: Hct.fromInt(seedColor.toARGB32()),
      isDark: brightness == Brightness.dark,
      contrastLevel: 0.0,
    ).neutralPalette;
    Color t(int tone) => Color(neutral.get(tone));
    return brightness == Brightness.dark
        ? s.copyWith(
            surface: t(4),
            surfaceContainerLowest: t(2),
            surfaceContainerLow: t(12),
            surfaceContainer: t(18),
            surfaceContainerHigh: t(24),
            surfaceContainerHighest: t(30),
          )
        : s.copyWith(
            surface: t(96),
            surfaceContainerLowest: t(100),
            surfaceContainerLow: t(100),
            surfaceContainer: t(92),
            surfaceContainerHigh: t(89),
            surfaceContainerHighest: t(86),
          );
  }
}

/// 固定语义色 —— **不跟随种子色**。
///
/// 何时用这里、何时用 `scheme.tertiary` / `scheme.error`:
/// 元素若压在**图片或固定浅色背景**上(状态圆点、图库角标、可视化画布的
/// 参考线),跟着种子色走会在某些配色下失去对比,必须用固定值;其余一律走
/// M3 语义角色。
///
/// 集中在此的原因:早先这些色散落在四个功能文件里各自 `const` 定义,
/// 同一个「可用/免费」语义漂成了三个不同的绿(2E9E44 / 2E9E57 / 2E7D32),
/// 用户在不同页面看到的是三种颜色。
abstract final class FixedSemantic {
  /// 可用 / 免费 / 已完成
  static const ok = Color(0xFF2E9E57);

  /// 缺条件 / 不可用(但非错误)
  static const warn = Color(0xFFE8890C);

  /// 超限 / 错误
  static const danger = Color(0xFFE0413F);

  /// 重绘(图库角标)
  static const inpaint = Color(0xFF7E57C2);

  /// 打码(图库角标)。与重绘同为「派生品」,取冷灰蓝拉开区分。
  static const censor = Color(0xFF546E7A);
}

/// 便捷访问
extension ThemeX on BuildContext {
  ColorScheme get scheme => Theme.of(this).colorScheme;
  TextTheme get texts => Theme.of(this).textTheme;
}

/// 等宽数字(参数读数、token 计数用)
TextStyle mono(
  BuildContext context, {
  double size = 12,
  FontWeight weight = FontWeight.w600,
  Color? color,
}) {
  return TextStyle(
    fontFamily: 'monospace',
    fontFeatures: const [FontFeature.tabularFigures()],
    fontSize: size,
    fontWeight: weight,
    color: color ?? context.scheme.onSurface,
  );
}

/// 浮动药丸里的滑杆外观:细轨 + 小滑块 + 无水波。
/// M3 默认的滑杆压在画布/列表上太抢戏,而这些地方读数才是主角。
final compactSliderTheme = SliderThemeData(
  padding: EdgeInsets.zero,
  trackHeight: 3,
  thumbSize: const WidgetStatePropertyAll(Size(14, 14)),
  overlayShape: SliderComponentShape.noOverlay,
);

/// M3 动效时长/曲线的统一出口,页面内所有过渡保持一致节奏。
abstract final class Motion {
  static const Duration quick = Durations.short2; // 100ms(离场/关闭收得快)
  static const Duration fast = Durations.short4; // 200ms
  static const Duration medium = Durations.medium2; // 300ms
  static const Duration slow = Durations.medium4; // 400ms
  static const Curve emphasized = Easing.emphasizedDecelerate;
  static const Curve standard = Easing.standard;
}
