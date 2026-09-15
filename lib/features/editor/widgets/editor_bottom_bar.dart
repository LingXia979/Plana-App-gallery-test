import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../editor_state.dart';

/// 底栏控件的统一高度:左侧正/负滑块与右侧两颗药丸共用一个数。
///
/// 从前一边写死 36、一边靠 9px 上下内边距把文字行高(bodyMedium 14×1.43≈20)
/// 撑成 38 —— 差这 2px 就已经看得出左右不齐;更麻烦的是系统字号一放大,只有
/// 药丸会跟着长,滑块纹丝不动,差距越拉越大。两边都钉死才不会各长各的。
const double _kBarH = 36;

/// 编辑器底栏:正/负 tab(左)+ 显示形态切换 + 撤销(右)。
/// 从顶栏下放到拇指易达的底部,吸在补全栏 / 键盘之上。
class EditorBottomBar extends ConsumerWidget {
  const EditorBottomBar({
    super.key,
    required this.onToggleMode,
    required this.chipMode,
  });

  /// 正文形态切换:注音富文本 ⇄ 芯片流。选择记在编辑器设置里。
  final VoidCallback onToggleMode;
  final bool chipMode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = context.scheme;
    final st = ref.watch(editorProvider);
    final notifier = ref.read(editorProvider.notifier);

    return Material(
      color: scheme.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 12, 6),
        child: Row(
          children: [
            _PosNegToggle(
              positive: st.activePositive,
              onChanged: notifier.setActivePositive,
            ),
            const Spacer(),
            // 文案/图标报的是**切过去**的那一头(和 web 那颗 Grid/AlignLeft
            // 同款语义),所以不做选中高亮 —— 高亮加文案会互相打架。
            _Pill(
              icon: chipMode ? Icons.notes_rounded : Icons.grid_view_rounded,
              label: chipMode ? '文本' : '芯片',
              enabled: true,
              onTap: onToggleMode,
            ),
            const SizedBox(width: 8),
            _Pill(
              icon: Icons.undo,
              label: '撤销',
              enabled: st.canUndo,
              onTap: notifier.undo,
            ),
          ],
        ),
      ),
    );
  }
}

/// 操作药丸:图标 + 文案,禁用置灰(形态切换 / 撤销共用)。
class _Pill extends StatelessWidget {
  const _Pill({
    required this.icon,
    required this.label,
    required this.enabled,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final fg = enabled ? scheme.onSurface : scheme.outlineVariant;
    return Material(
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(_kBarH / 2),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: enabled ? onTap : null,
        child: SizedBox(
          height: _kBarH,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 18, color: fg),
                const SizedBox(width: 6),
                Text(
                  label,
                  maxLines: 1,
                  style: context.texts.bodyMedium!.copyWith(color: fg),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 正面 / 负面 切换 —— 滑块分段:激活段填充语义色(正面金 / 负面红)并滑动过渡。
class _PosNegToggle extends StatelessWidget {
  const _PosNegToggle({required this.positive, required this.onChanged});

  final bool positive;
  final ValueChanged<bool> onChanged;

  static const double _segW = 60;
  static const double _h = _kBarH;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final thumbColor = positive ? scheme.primary : scheme.error;
    final onThumb = positive ? scheme.onPrimary : scheme.onError;

    return Container(
      // 定宽:Row 里宽度无界时 Align 会收缩到滑块自身,滑块没有可移动
      // 空间——永远停在左段、切换无动画(真机反馈修复)。
      width: _PosNegToggle._segW * 2 + 6,
      height: _h,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(_h / 2),
      ),
      child: Stack(
        children: [
          // 滑块:填充当前语义色,左右滑动
          AnimatedAlign(
            duration: Motion.medium,
            curve: Motion.emphasized,
            alignment: positive ? Alignment.centerLeft : Alignment.centerRight,
            child: AnimatedContainer(
              duration: Motion.medium,
              curve: Motion.standard,
              width: _segW,
              height: _h - 6,
              decoration: BoxDecoration(
                color: thumbColor,
                borderRadius: BorderRadius.circular((_h - 6) / 2),
              ),
            ),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _seg(
                '正面',
                Icons.check,
                active: positive,
                onThumb: onThumb,
                onTap: () => onChanged(true),
              ),
              _seg(
                '负面',
                Icons.block,
                active: !positive,
                onThumb: onThumb,
                onTap: () => onChanged(false),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _seg(
    String label,
    IconData icon, {
    required bool active,
    required Color onThumb,
    required VoidCallback onTap,
  }) {
    return _SegLabel(
      label: label,
      icon: icon,
      active: active,
      onThumb: onThumb,
      width: _segW,
      height: _h - 6,
      onTap: onTap,
    );
  }
}

class _SegLabel extends StatelessWidget {
  const _SegLabel({
    required this.label,
    required this.icon,
    required this.active,
    required this.onThumb,
    required this.width,
    required this.height,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool active;
  final Color onThumb;
  final double width;
  final double height;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final fg = active ? onThumb : scheme.onSurfaceVariant;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        width: width,
        height: height,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 14, color: fg),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                color: fg,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
