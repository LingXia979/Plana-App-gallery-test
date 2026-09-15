/// 自动打码的推理层:图片字节 → letterbox 张量 → ORT → [CensorBox]。
///
/// 只有这一个文件知道用的是 ONNX Runtime。几何/解码/NMS 全在
/// [censor_detect.dart],换推理框架时这里重写、那边不动。
///
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

import '../../core/util/log.dart';
import 'censor_detect.dart';
import 'inpaint_ops.dart' show IntRect;

/// 模型资源键与输入输出名(与导出时一致,改模型要跟着改)。
const String _kAsset = 'assets/models/censor_n.ort';
const String _kInput = 'images';
const String _kOutput = 'output0';

/// letterbox 留边填充色。YOLO 训练时用的就是 114 灰,填别的会让边缘出幻觉框。
const int _kPadGray = 114;

/// 懒加载的会话。模型 3.2MB,加载有开销,常驻直到 [disposeCensorSession]。
OrtSession? _session;
Future<OrtSession>? _loading;

Future<OrtSession> _ensureSession() {
  final s = _session;
  if (s != null) return Future.value(s);
  return _loading ??= OnnxRuntime()
      .createSessionFromAsset(_kAsset)
      .then(
        (s) {
          _session = s;
          _loading = null;
          return s;
        },
        onError: (Object e) {
          _loading = null;
          throw e;
        },
      );
}

/// 提前把模型读进内存(进打码档时调,免得点「自动」才开始等)。
Future<void> warmUpCensorSession() async {
  try {
    await _ensureSession();
  } catch (_) {
    // 预热失败不打扰用户,真点「自动」时再报
  }
}

Future<void> disposeCensorSession() async {
  final s = _session;
  _session = null;
  if (s != null) await s.close();
}

/// 检测需要打码的区域。[rgba] 是 `ui.Image.toByteData(rawRgba)` 的裸字节。
///
/// **不吃 PNG**:调用方(编辑器)本来就持有一份原生解码好的 `ui.Image`,
/// 再在 Dart 里解一次 PNG 是白花几百毫秒 —— 实测那一下占了总耗时的大头。
///
/// **整图一遍 + 分块各一遍**:整图那遍保大目标,分块保小目标(见
/// [planTiles] 的说明)。所有框都还原到整图坐标后一次性 NMS 去重 ——
/// 重叠区域里同一个目标会被相邻块各检出一次,靠 NMS 合并。
Future<List<CensorBox>> detectCensorBoxes(
  Uint8List rgba,
  int srcW,
  int srcH,
) async {
  final session = await _ensureSession();
  final sw = Stopwatch()..start();
  var msPre = 0, msRun = 0;
  var t0 = 0;

  final fullInput = await compute(_preprocess, (rgba, srcW, srcH, null));
  msPre += sw.elapsedMilliseconds;

  final tiles = planTiles(srcW, srcH);
  final total = 1 + tiles.length;

  // **流水线**:预处理跑在 isolate 里、不经插件那把全局锁,所以下一遍的张量
  // 可以在当前这遍推理的同时备好 —— 省掉的正是每遍那次 PNG 解码。
  //
  // 推理本身**无法并发**:插件把整个 onMethodCall 包在一把全局锁里
  // (FlutterOnnxruntimePlugin.kt),ORT 会话本身是支持并发 Run 的。
  Future<Float32List>? pending = tiles.isEmpty
      ? null
      : compute(_preprocess, (rgba, srcW, srcH, tiles[0]));

  final boxes = <CensorBox>[];
  t0 = sw.elapsedMilliseconds;
  boxes.addAll(
    decodeYolo(await _run(session, fullInput), lb: Letterbox.fit(srcW, srcH)),
  );
  msRun += sw.elapsedMilliseconds - t0;

  for (var i = 0; i < tiles.length; i++) {
    t0 = sw.elapsedMilliseconds;
    final ti = await pending!;
    msPre += sw.elapsedMilliseconds - t0;
    // 先把下一遍的预处理起起来,再去等这一遍的推理
    pending = i + 1 < tiles.length
        ? compute(_preprocess, (rgba, srcW, srcH, tiles[i + 1]))
        : null;

    t0 = sw.elapsedMilliseconds;
    boxes.addAll(
      decodeYolo(await _run(session, ti), lb: Letterbox.tile(tiles[i])),
    );
    msRun += sw.elapsedMilliseconds - t0;
  }

  final out = nms(boxes);
  logd(
    '[censor] $total 遍 ${sw.elapsedMilliseconds}ms'
    ' (等预处理 $msPre / 推理 $msRun) → ${boxes.length} 框, NMS 后 ${out.length}',
  );
  return out;
}

/// 跑一遍推理,拿回展平的输出张量。
Future<Float32List> _run(OrtSession session, Float32List input) async {
  final tensor = await OrtValue.fromList(input, [
    1,
    3,
    kDetInputSize,
    kDetInputSize,
  ]);
  try {
    final out = await session.run({_kInput: tensor});
    final raw = out[_kOutput];
    if (raw == null) throw StateError('模型没有输出 $_kOutput');
    final flat = await raw.asFlattenedList();
    await raw.dispose();
    // 插件返回的就是 Float32List(Android 侧是 FloatArray,走 Flutter 的
    // typed-data 快路径)。逐元素抄一遍等于把 5.8 万个 double 装箱读一遍,
    // 白扔几十毫秒 —— 能直接用就直接用。
    if (flat is Float32List) return flat;
    return Float32List.fromList(
      flat.cast<num>().map((e) => e.toDouble()).toList(),
    );
  } finally {
    await tensor.dispose();
  }
}

/// 后台 isolate:从整图裸 RGBA 直接采样出 NCHW 张量。
///
/// 裁块、缩放、留边、归一化**融成一个循环**。之前是 copyCrop + copyResize
/// + fill + compositeImage + getBytes 五次遍历再加一次逐像素 getPixel,
/// 实测那套占了预处理的绝大部分。这里对每个输出像素反算源坐标、双线性
/// 采样一次就写进三个通道平面,中间不落任何位图。
///
/// [arg] 的第四项非空时只采该块(分块推理);为空时采整图。
Float32List _preprocess((Uint8List, int, int, IntRect?) arg) {
  final (rgba, srcW, srcH, tile) = arg;
  final tx = tile?.x ?? 0, ty = tile?.y ?? 0;
  final tw = tile?.w ?? srcW, th = tile?.h ?? srcH;
  final lb = Letterbox.fit(tw, th);

  const size = kDetInputSize;
  const n = size * size;
  final out = Float32List(3 * n);
  // 先整片铺灰,内容区随后覆盖 —— 比在循环里逐像素判边界快
  out.fillRange(0, 3 * n, _kPadGray / 255.0);

  // 内容区在输出图里的范围
  final ix0 = lb.padX.floor().clamp(0, size);
  final iy0 = lb.padY.floor().clamp(0, size);
  final ix1 = (lb.padX + tw * lb.scale).ceil().clamp(0, size);
  final iy1 = (lb.padY + th * lb.scale).ceil().clamp(0, size);

  final maxX = srcW - 1, maxY = srcH - 1;
  for (var oy = iy0; oy < iy1; oy++) {
    // 输出像素中心 → 块内坐标 → 整图坐标
    var sy = (oy + 0.5 - lb.padY) / lb.scale - 0.5 + ty;
    if (sy < 0) sy = 0;
    if (sy > maxY) sy = maxY.toDouble();
    final y0 = sy.floor();
    final y1 = y0 < maxY ? y0 + 1 : y0;
    final wy = sy - y0;
    final row0 = y0 * srcW, row1 = y1 * srcW;
    final dst = oy * size;
    for (var ox = ix0; ox < ix1; ox++) {
      var sx = (ox + 0.5 - lb.padX) / lb.scale - 0.5 + tx;
      if (sx < 0) sx = 0;
      if (sx > maxX) sx = maxX.toDouble();
      final x0 = sx.floor();
      final x1 = x0 < maxX ? x0 + 1 : x0;
      final wx = sx - x0;

      final i00 = (row0 + x0) * 4, i01 = (row0 + x1) * 4;
      final i10 = (row1 + x0) * 4, i11 = (row1 + x1) * 4;
      final w00 = (1 - wx) * (1 - wy), w01 = wx * (1 - wy);
      final w10 = (1 - wx) * wy, w11 = wx * wy;

      final o = dst + ox;
      for (var c = 0; c < 3; c++) {
        out[c * n + o] =
            (rgba[i00 + c] * w00 +
                rgba[i01 + c] * w01 +
                rgba[i10 + c] * w10 +
                rgba[i11 + c] * w11) /
            255.0;
      }
    }
  }
  return out;
}
