import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/theme_settings.dart';
import 'widgets/settings_ui.dart';

class AppearancePage extends ConsumerWidget {
  const AppearancePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ts = ref.watch(themeSettingsProvider);
    final notifier = ref.read(themeSettingsProvider.notifier);
    return Scaffold(
      appBar: AppBar(title: const Text('外观与触感')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 24),
        children: [
          const SettingsLabel('深浅模式'),
          SettingsCard(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                child: SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<ThemeMode>(
                    segments: const [
                      ButtonSegment(
                        value: ThemeMode.system,
                        label: Text('跟随系统'),
                      ),
                      ButtonSegment(value: ThemeMode.light, label: Text('浅色')),
                      ButtonSegment(value: ThemeMode.dark, label: Text('深色')),
                    ],
                    selected: {ts.mode},
                    onSelectionChanged: (s) =>
                        notifier.patch((x) => x.copyWith(mode: s.first)),
                    showSelectedIcon: false,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const SettingsLabel('主题色'),
          SettingsCard(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    for (final s in themeSeeds)
                      _Swatch(
                        seed: s,
                        selected: s.key == ts.seed.key,
                        onTap: () =>
                            notifier.patch((x) => x.copyWith(seedKey: s.key)),
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const SettingsLabel('底部导航'),
          SettingsCard(
            children: [
              _SwitchRow(
                icon: Icons.auto_awesome,
                title: '显示 AI 助手',
                subtitle: '关掉后底栏不再显示 AI 入口',
                value: ts.showAssistant,
                onChanged: (v) =>
                    notifier.patch((x) => x.copyWith(showAssistant: v)),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const SettingsLabel('触感'),
          SettingsCard(
            children: [
              _SwitchRow(
                icon: Icons.vibration,
                title: '振动反馈',
                value: ts.haptics,
                onChanged: (v) => notifier.patch((x) => x.copyWith(haptics: v)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 卡片里的一行开关。整行可点。
class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.icon,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final sub = subtitle;
    return InkWell(
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Row(
          children: [
            Icon(icon, size: 20, color: scheme.onSurfaceVariant),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: context.texts.bodyMedium!.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (sub != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      sub,
                      style: context.texts.labelSmall!.copyWith(
                        color: scheme.outline,
                        height: 1.5,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            Switch(value: value, onChanged: onChanged),
          ],
        ),
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.seed,
    required this.selected,
    required this.onTap,
  });

  final ThemeSeed seed;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final onColor =
        ThemeData.estimateBrightnessForColor(seed.color) == Brightness.dark
        ? Colors.white
        : Colors.black87;
    return Tooltip(
      message: seed.label,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: AnimatedContainer(
          duration: Motion.fast,
          width: 44,
          height: 44,
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              width: 2,
              color: selected ? scheme.onSurface : Colors.transparent,
            ),
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: seed.color,
              shape: BoxShape.circle,
            ),
            child: selected
                ? Icon(Icons.check, size: 18, color: onColor)
                : null,
          ),
        ),
      ),
    );
  }
}
