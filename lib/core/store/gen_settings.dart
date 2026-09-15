import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_stores.dart';

/// 生成设置(持久化)。
/// [retryOn429]:被限流(HTTP 429)时自动重试当张,默认开;
/// 固定间隔 [retryDelaySecs] 秒(0 = 立即),最多 [retryCount] 次。
/// [genNotify]:生成进度前台通知(可上灵动岛/状态栏胶囊),默认开。
/// [streamGen]:直连流式生成(逐步预览),默认开;关了改走一次性端点。
/// [notifyPrimed]:首启的通知说明页是否已过(过了就不再挡在进主界面之前)。
class GenSettings {
  const GenSettings({
    this.retryOn429 = true,
    this.retryDelaySecs = 1,
    this.retryCount = 3,
    this.genNotify = true,
    this.notifyPrimed = false,
    this.straightAlpha = true,
    this.streamGen = true,
  });

  final bool retryOn429;
  final int retryDelaySecs;
  final int retryCount;
  final bool genNotify;
  final bool notifyPrimed;

  /// 直连出图走流式端点(`/ai/generate-image-stream`):边采样边回帧,画布上
  /// 能看着图一步步长出来。关了改走一次性的 `/ai/generate-image` —— 出图前
  /// 没有逐步预览,只有一根不确定进度条,画完一次性回整张。
  ///
  /// 会想关它的只有一种情况:用了第三方接口(见 `NaiKey.endpoint`),而对面
  /// 只实现了非流式那个端点。官方接口两个都在,没必要关。
  ///
  /// Bot 线不看这个:那条的进度来自后端 WS,与 NAI 的流式端点无关。
  final bool streamGen;

  /// 透明图(V5)的 alpha 编码约定:true = 直通 Straight(RGB 是原色,PS/AE
  /// 默认想要的那种),false = 预乘 Premultiplied(RGB 已乘过 alpha)。
  /// 官方默认直通,这里跟随。只在模型支持透明时随请求发出。
  final bool straightAlpha;

  GenSettings copyWith({
    bool? retryOn429,
    int? retryDelaySecs,
    int? retryCount,
    bool? genNotify,
    bool? notifyPrimed,
    bool? straightAlpha,
    bool? streamGen,
  }) => GenSettings(
    retryOn429: retryOn429 ?? this.retryOn429,
    retryDelaySecs: retryDelaySecs ?? this.retryDelaySecs,
    retryCount: retryCount ?? this.retryCount,
    genNotify: genNotify ?? this.genNotify,
    notifyPrimed: notifyPrimed ?? this.notifyPrimed,
    straightAlpha: straightAlpha ?? this.straightAlpha,
    streamGen: streamGen ?? this.streamGen,
  );

  static int _intIn(Object? v, int fallback, int min, int max) {
    final n = (v as num?)?.toInt() ?? fallback;
    return n.clamp(min, max);
  }

  factory GenSettings.fromJson(Map<String, dynamic> j) => GenSettings(
    retryOn429: j['retryOn429'] is bool ? j['retryOn429'] as bool : true,
    retryDelaySecs: _intIn(j['retryDelaySecs'], 1, 0, 600),
    retryCount: _intIn(j['retryCount'], 3, 1, 99),
    genNotify: j['genNotify'] is bool ? j['genNotify'] as bool : true,
    notifyPrimed: j['notifyPrimed'] == true,
    straightAlpha: j['straightAlpha'] is bool
        ? j['straightAlpha'] as bool
        : true,
    streamGen: j['streamGen'] is bool ? j['streamGen'] as bool : true,
  );

  Map<String, dynamic> toJson() => {
    'retryOn429': retryOn429,
    'retryDelaySecs': retryDelaySecs,
    'retryCount': retryCount,
    'genNotify': genNotify,
    'notifyPrimed': notifyPrimed,
    'straightAlpha': straightAlpha,
    'streamGen': streamGen,
  };

  @override
  bool operator ==(Object other) =>
      other is GenSettings &&
      other.retryOn429 == retryOn429 &&
      other.retryDelaySecs == retryDelaySecs &&
      other.retryCount == retryCount &&
      other.genNotify == genNotify &&
      other.notifyPrimed == notifyPrimed &&
      other.straightAlpha == straightAlpha &&
      other.streamGen == streamGen;

  @override
  int get hashCode => Object.hash(
    retryOn429,
    retryDelaySecs,
    retryCount,
    genNotify,
    notifyPrimed,
    straightAlpha,
    streamGen,
  );
}

const _key = 'gen_settings';

final genSettingsProvider =
    AsyncNotifierProvider<GenSettingsNotifier, GenSettings>(
      GenSettingsNotifier.new,
    );

class GenSettingsNotifier extends AsyncNotifier<GenSettings> {
  @override
  Future<GenSettings> build() async {
    try {
      final raw = await ref.read(prefsStoreProvider).read(key: _key);
      if (raw == null || raw.isEmpty) return const GenSettings();
      return GenSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return const GenSettings();
    }
  }

  /// 先改状态(立即生效),再尽力持久化。
  Future<void> patch(GenSettings Function(GenSettings) change) async {
    final next = change(state.value ?? const GenSettings());
    state = AsyncData(next);
    try {
      await ref
          .read(prefsStoreProvider)
          .write(key: _key, value: jsonEncode(next.toJson()));
    } catch (_) {}
  }
}
