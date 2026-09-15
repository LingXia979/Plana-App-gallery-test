import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/ui/setting_row.dart';
import '../editor_settings.dart';

/// 编辑器设置弹层:行为开关 + 档位选择 + 加减调节,改动即时生效并持久化。
/// 按模块分组;子项跟随所属功能开关置灰(补全关了实体/逗号无意义)。
class EditorSettingsSheet extends ConsumerWidget {
  const EditorSettingsSheet({super.key});

  /// 正文之上那一坨固定高度:顶栏 72(返回行 54 + token 进度条 18)
  /// + 正文区自己的上内边距 8。
  static const _kChromeH = 80.0;

  /// 弹层上方要露出的正文行数 × 默认行高(字号 16 × 行高 2.0)。
  static const _kPeek = 2 * 32.0;

  /// 弹层封顶高度:**不顶满**,上面留出顶栏和两行正文。
  ///
  /// 字号、注音翻译、权重高亮这几项改的就是「正文长什么样」,把正文遮死了
  /// 只能关掉看一眼、再开、再调 —— 露两行就能边调边看。
  ///
  /// 按绝对高度扣而不是按屏高取百分比:要留的是「顶栏 + 两行字」这个**固定**
  /// 的量,屏幕越高百分比越不准。两头夹一下防极端屏幕。
  ///
  /// ⚠ 状态栏高度**不能**读 `MediaQuery.viewPaddingOf(context)`:
  /// ModalBottomSheetRoute 内部做过 `removePadding(removeTop: true)`,
  /// 弹层里读到的顶部安全区恒为 0 —— 少扣一整个状态栏,正文就只剩半行(踩过)。
  /// 直接问 View 拿原始 insets。
  static double _maxHeight(BuildContext context) {
    final h = MediaQuery.sizeOf(context).height;
    final top = MediaQueryData.fromView(View.of(context)).padding.top;
    return (h - top - _kChromeH - _kPeek).clamp(h * .5, h * .85);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = context.scheme;
    final s = ref.watch(editorSettingsProvider).value ?? const EditorSettings();
    final notifier = ref.read(editorSettingsProvider.notifier);

    return Material(
      color: scheme.surfaceContainer,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: _maxHeight(context)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 抓手与标题栏留在滚动区**外面**:整片都塞进 SingleChildScrollView
            // 的话,下拉手势全被滚动条吃掉,弹层自带的下拉关闭永远轮不到
            // (真机反馈:拉不动也没地方点关)。右侧再给一个 ✕ 兜底。
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: scheme.outline.withValues(alpha: .5),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 8, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '编辑器设置',
                      style: context.texts.titleMedium!.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: EdgeInsets.only(
                  bottom: MediaQuery.viewPaddingOf(context).bottom + 10,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    settingSection(context, '显示'),
                    SettingRow(
                      icon: Icons.translate,
                      title: '显示注释翻译',
                      desc: '在词条下方以小字标注中文翻译',
                      value: s.showTranslation,
                      onChanged: (v) =>
                          notifier.patch((c) => c.copyWith(showTranslation: v)),
                    ),
                    SettingRow(
                      icon: Icons.format_color_fill,
                      title: '权重高亮',
                      desc: '加权 / 降权词条按强度显示红 / 蓝色',
                      value: s.showWeightWash,
                      onChanged: (v) =>
                          notifier.patch((c) => c.copyWith(showWeightWash: v)),
                    ),
                    SettingStepperRow(
                      icon: Icons.format_size,
                      title: '文本字号',
                      desc: '文本模式下的文本显示大小',
                      value: s.fontSize,
                      min: EditorSettings.fontSizeMin,
                      max: EditorSettings.fontSizeMax,
                      step: EditorSettings.fontSizeStep,
                      format: (v) => v.toStringAsFixed(0),
                      onChanged: (v) =>
                          notifier.patch((c) => c.copyWith(fontSize: v)),
                    ),
                    SettingStepperRow(
                      icon: Icons.label_outline,
                      title: '芯片字号',
                      desc: '芯片模式下的芯片显示大小',
                      value: s.chipFontSize,
                      min: EditorSettings.fontSizeMin,
                      max: EditorSettings.fontSizeMax,
                      step: EditorSettings.fontSizeStep,
                      format: (v) => v.toStringAsFixed(0),
                      onChanged: (v) =>
                          notifier.patch((c) => c.copyWith(chipFontSize: v)),
                    ),
                    settingSection(context, '补全'),
                    SettingRow(
                      icon: Icons.manage_search,
                      title: '启用补全提示',
                      desc: '输入时在底部给出标签补全建议',
                      value: s.enableCompletion,
                      onChanged: (v) => notifier.patch(
                        (c) => c.copyWith(enableCompletion: v),
                      ),
                    ),
                    SettingRow(
                      icon: Icons.category_outlined,
                      title: '实体建议',
                      desc: '补全中包含画师 / 角色 / OC / 作品',
                      value: s.entitySuggest,
                      enabled: s.enableCompletion,
                      onChanged: (v) =>
                          notifier.patch((c) => c.copyWith(entitySuggest: v)),
                    ),
                    SettingRow(
                      icon: Icons.auto_fix_high,
                      title: '选词自动补逗号',
                      desc: '选中补全后自动加「, 」,方便连打下一枚',
                      value: s.autoComma,
                      enabled: s.enableCompletion,
                      onChanged: (v) =>
                          notifier.patch((c) => c.copyWith(autoComma: v)),
                    ),
                    settingSection(context, '词条栏'),
                    SettingRow(
                      icon: Icons.sell_outlined,
                      title: '启用标签面板',
                      desc: '光标停在词条上时显示权重与操作栏',
                      value: s.enableTagPanel,
                      onChanged: (v) =>
                          notifier.patch((c) => c.copyWith(enableTagPanel: v)),
                    ),
                    SettingRow(
                      icon: Icons.density_small,
                      title: '精简词条栏',
                      desc: '压成一行,只留权重与删除,正文多露两行',
                      value: s.compactTagPanel,
                      enabled: s.enableTagPanel,
                      onChanged: (v) =>
                          notifier.patch((c) => c.copyWith(compactTagPanel: v)),
                    ),
                    SettingStepperRow(
                      icon: Icons.exposure,
                      title: '权重步进',
                      desc: '数值 +/− 每步的调整量',
                      value: s.weightStep,
                      min: EditorSettings.weightStepMin,
                      max: EditorSettings.weightStepMax,
                      step: EditorSettings.weightStepTick,
                      format: _fmtStep,
                      enabled: s.enableTagPanel,
                      onChanged: (v) =>
                          notifier.patch((c) => c.copyWith(weightStep: v)),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 权重步进读数:两位小数去掉尾随的零(0.10 → 0.1,0.05 原样)。
/// 一列读数里只有它拖着个空转的小数位会很扎眼。
String _fmtStep(double v) {
  var t = v.toStringAsFixed(2);
  if (t.contains('.')) {
    t = t.replaceFirst(RegExp(r'0+$'), '');
    if (t.endsWith('.')) t = t.substring(0, t.length - 1);
  }
  return t;
}
