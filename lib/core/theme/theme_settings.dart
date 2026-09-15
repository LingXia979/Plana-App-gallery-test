import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../store/app_stores.dart';
import '../store/prefs_store.dart';

/// 主题色档位。
class ThemeSeed {
  const ThemeSeed(this.key, this.label, this.color);

  final String key;
  final String label;
  final Color color;
}

// 按色环排列(新增档位只管加,持久化按 key 不受顺序影响)。
const themeSeeds = <ThemeSeed>[
  ThemeSeed('gold', '金', Color(0xFFD4A72C)),
  ThemeSeed('orange', '橙', Color(0xFFEF6C00)),
  ThemeSeed('red', '红', Color(0xFFC62828)),
  ThemeSeed('rose', '粉', Color(0xFFD81B60)),
  ThemeSeed('plum', '梅', Color(0xFF8E24AA)),
  ThemeSeed('violet', '紫', Color(0xFF6750A4)),
  ThemeSeed('indigo', '靛', Color(0xFF3949AB)),
  ThemeSeed('sky', '浅蓝', Color(0xFF4FA3E3)),
  ThemeSeed('teal', '青', Color(0xFF00897B)),
  ThemeSeed('green', '绿', Color(0xFF2E7D32)),
  ThemeSeed('brown', '棕', Color(0xFF795548)),
  ThemeSeed('grey', '灰', Color(0xFF607D8B)),
];

/// 默认主题色(未选过时的档位)。
const kDefaultSeedKey = 'sky';

/// 外观与触感设置(持久化):深浅模式 + 主题色 + 振动总开关。
class ThemeSettings {
  const ThemeSettings({
    this.mode = ThemeMode.light,
    this.seedKey = kDefaultSeedKey,
    this.haptics = true,
    this.showAssistant = true,
  });

  final ThemeMode mode;
  final String seedKey;

  /// 关掉后 app 内所有振动静默(实际拦在 [Haptics])。
  final bool haptics;

  /// 底栏显不显示「AI」那一格。关掉只是**藏起入口**,助手本身照旧 ——
  /// 已经导入过的改动、归档的会话都不受影响,开回来还在。
  ///
  /// 放在主题设置里是因为它和深浅模式一样要在 ProviderScope 建立之前就读到
  /// (底栏首帧就得知道画几格),而这份是全 app 唯一一个同步加载的偏好。
  final bool showAssistant;

  ThemeSeed get seed => themeSeeds.firstWhere(
    (s) => s.key == seedKey,
    orElse: () => themeSeeds.firstWhere((s) => s.key == kDefaultSeedKey),
  );

  ThemeSettings copyWith({
    ThemeMode? mode,
    String? seedKey,
    bool? haptics,
    bool? showAssistant,
  }) => ThemeSettings(
    mode: mode ?? this.mode,
    seedKey: seedKey ?? this.seedKey,
    haptics: haptics ?? this.haptics,
    showAssistant: showAssistant ?? this.showAssistant,
  );

  /// 脏数据(旧版本/已下架的档位,如早先那档深蓝)回退默认。
  factory ThemeSettings.fromJson(Map<String, dynamic> j) => ThemeSettings(
    mode: ThemeMode.values.asNameMap()[j['mode']] ?? ThemeMode.light,
    seedKey: themeSeeds.any((s) => s.key == j['seed'])
        ? j['seed'] as String
        : kDefaultSeedKey,
    haptics: j['haptics'] != false,
    showAssistant: j['showAssistant'] != false,
  );

  Map<String, dynamic> toJson() => {
    'mode': mode.name,
    'seed': seedKey,
    'haptics': haptics,
    'showAssistant': showAssistant,
  };

  @override
  bool operator ==(Object other) =>
      other is ThemeSettings &&
      other.mode == mode &&
      other.seedKey == seedKey &&
      other.haptics == haptics &&
      other.showAssistant == showAssistant;

  @override
  int get hashCode => Object.hash(mode, seedKey, haptics);
}

const _key = 'theme_settings';

/// 启动时预读的初始值(main 注入,首帧即为用户配色,不闪变)。
final themeInitProvider = Provider<ThemeSettings>((_) => const ThemeSettings());

/// 首帧前的预读。`main()` 在 ProviderScope 之前调用,拿不到 ref,所以直接
/// 收 [PrefsStore] —— 它此时已随 `AppStores.open()` 一次性读进内存,
/// 这里**不再产生任何 I/O**(此前是第二次读 secure storage,要解 Keystore)。
ThemeSettings loadThemeSettings(PrefsStore prefs) {
  try {
    final raw = prefs.get(_key);
    if (raw == null || raw.isEmpty) return const ThemeSettings();
    return ThemeSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  } catch (_) {
    return const ThemeSettings();
  }
}

final themeSettingsProvider =
    NotifierProvider<ThemeSettingsNotifier, ThemeSettings>(
      ThemeSettingsNotifier.new,
    );

class ThemeSettingsNotifier extends Notifier<ThemeSettings> {
  @override
  ThemeSettings build() => ref.watch(themeInitProvider);

  /// 先改状态(全局即时换肤),再尽力持久化。
  void patch(ThemeSettings Function(ThemeSettings) change) {
    state = change(state);
    _persist(state);
  }

  Future<void> _persist(ThemeSettings s) async {
    try {
      await ref
          .read(prefsStoreProvider)
          .write(key: _key, value: jsonEncode(s.toJson()));
    } catch (_) {}
  }
}
