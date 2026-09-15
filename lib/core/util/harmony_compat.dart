import 'dart:io' show Platform;

import 'package:flutter/services.dart';

import 'log.dart';

/// 是否跑在纯血鸿蒙的安卓兼容容器里(卓易通 / 出境易)。
///
/// 判法在原生侧(`HarmonyCompat.kt`):容器会伪装厂商和型号,只能认它自己设的
/// 系统属性。进程内只问一次;非 Android 或问不到时一律按普通机处理。
final Future<bool> isHarmonyCompatContainer = _detect();

Future<bool> _detect() async {
  if (!Platform.isAndroid) return false;
  try {
    const ch = MethodChannel('plana/harmony_compat');
    final v = await ch.invokeMethod<bool>('isContainer') ?? false;
    logi('[harmony] 安卓兼容容器: $v');
    return v;
  } catch (e) {
    logi('[harmony] 容器检测失败,按普通安卓处理: ${e.runtimeType}');
    return false;
  }
}
