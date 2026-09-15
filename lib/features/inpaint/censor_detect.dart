/// 自动打码的**模型无关层**:letterbox 几何、YOLOv8 输出解码、NMS、框→遮罩。
///
/// 这里一行推理代码都没有 —— ORT / TFLite / NCNN 将来怎么换,这层都不动。
/// 所以它先写先测:纯函数、无 Flutter 依赖、跑得起单测。
///
/// 模型:`deepghs/anime_censor_detection`(YOLOv8,二次元数据训练,MIT)。
/// 输入 1×3×640×640,输出 `[1, 4+3, 8400]`,三类 = nipple_f / penis / pussy。
/// 框已经在导出时解过 DFL、类别分数已过 sigmoid,拿到就能用。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'inpaint_ops.dart' show IntRect, MaskGrid;

/// 模型类别。顺序与 `labels.json` 一致,别调换。
enum CensorClass { nippleF, penis, pussy }

/// 模型输入边长。8400 个锚点正是 80²+40²+20²,和这个尺寸绑死 ——
/// 换尺寸就得跟着换锚点数,所以这里写成常量而不是参数。
const int kDetInputSize = 640;

/// 模型作者给的 F1 最优阈值(`threshold.json`):n 档 0.278、s 档 0.238。
///
/// 我们**故意取得更低** —— 打码是召回优先,漏一块是事故,多框一块用户擦掉就行。
const double kDetConfThreshold = 0.20;

/// NMS 的 IoU 阈值(对齐 imgutils 的 `detect_censors` 默认值)。
const double kDetIouThreshold = 0.7;

/// 一个检测框,坐标已经还原到**原图像素**。
class CensorBox {
  const CensorBox({
    required this.x0,
    required this.y0,
    required this.x1,
    required this.y1,
    required this.cls,
    required this.score,
  });

  final double x0, y0, x1, y1;
  final CensorClass cls;
  final double score;

  double get w => x1 - x0;
  double get h => y1 - y0;
  double get area => math.max(0, w) * math.max(0, h);

  /// 四周按边长比例外扩,并夹回图内。
  ///
  /// 检测框普遍偏紧,不扩就会沿边漏出一圈 —— 这是打码最常见的失败样子。
  CensorBox expand(double ratio, int imgW, int imgH) {
    final dx = w * ratio, dy = h * ratio;
    return CensorBox(
      x0: (x0 - dx).clamp(0, imgW.toDouble()),
      y0: (y0 - dy).clamp(0, imgH.toDouble()),
      x1: (x1 + dx).clamp(0, imgW.toDouble()),
      y1: (y1 + dy).clamp(0, imgH.toDouble()),
      cls: cls,
      score: score,
    );
  }
}

/// letterbox 几何:等比缩放进 [size]×[size] 方框、居中留边。
///
/// **坐标还原写错就是整体偏移**,是这条管线最容易翻车的一步,所以单独成类
/// 并且正反变换都留出来给单测钉。
class Letterbox {
  Letterbox._(
    this.scale,
    this.padX,
    this.padY,
    this.size,
    this.srcW,
    this.srcH,
    this.originX,
    this.originY,
  );

  factory Letterbox.fit(int srcW, int srcH, {int size = kDetInputSize}) {
    final s = math.min(size / srcW, size / srcH);
    final dw = srcW * s, dh = srcH * s;
    return Letterbox._(
      s,
      (size - dw) / 2,
      (size - dh) / 2,
      size,
      srcW,
      srcH,
      0,
      0,
    );
  }

  /// 分块推理用:把 [t] 这一块单独 letterbox 进 [size],坐标还原时自动
  /// 加回块的左上角,所以调用方拿到的框**始终是整图坐标**。
  factory Letterbox.tile(IntRect t, {int size = kDetInputSize}) {
    final base = Letterbox.fit(t.w, t.h, size: size);
    return Letterbox._(
      base.scale,
      base.padX,
      base.padY,
      size,
      t.w,
      t.h,
      t.x,
      t.y,
    );
  }

  /// 原图 → 模型输入的缩放比(等比,单值)。
  final double scale;

  /// 居中留边的偏移(模型输入像素)。
  final double padX, padY;
  final int size;

  /// 本次喂进模型的那块区域的尺寸(整图推理即整图,分块推理即块)。
  final int srcW, srcH;

  /// 该块在**整图**里的左上角。整图推理恒为 (0,0)。
  final int originX, originY;

  /// 整图坐标 → 模型输入坐标。
  double mapX(double x) => (x - originX) * scale + padX;
  double mapY(double y) => (y - originY) * scale + padY;

  /// 模型输入坐标 → 整图坐标(推理结果走这条)。
  double unmapX(double x) => (x - padX) / scale + originX;
  double unmapY(double y) => (y - padY) / scale + originY;
}

/// 分块推理的切块方案(整图坐标)。返回空表示这张图不值得切。
///
/// **为什么要切**:小目标漏检的根因是缩放比。1216 长边进 640 的输入,缩放比
/// 只有 0.53 —— 原图上 40px 的目标到模型眼里只剩 21px,掉到 YOLOv8 的检测
/// 尺度下限附近。切块后每块单独 letterbox,缩放比回到 1 附近,小目标重新
/// 进入模型看得见的尺寸。这就是 SAHI 那套做法。
///
/// [overlap] 是相邻块**互相探入**的比例:骑在切缝上的目标不切开就会被切成
/// 两半,两边各剩一截、谁也够不上阈值。
///
/// 图本身不比输入大时返回空 —— 那种图整图那一遍缩放比已经 ≥1,切了纯属
/// 白跑几次推理。
List<IntRect> planTiles(
  int w,
  int h, {
  int size = kDetInputSize,
  double overlap = 0.25,
  int maxGrid = 3,
}) {
  final cols = (w / size).ceil().clamp(1, maxGrid);
  final rows = (h / size).ceil().clamp(1, maxGrid);
  if (cols == 1 && rows == 1) return const [];

  final tw = w / cols, th = h / rows;
  final padX = tw * overlap, padY = th * overlap;
  final out = <IntRect>[];
  for (var r = 0; r < rows; r++) {
    for (var c = 0; c < cols; c++) {
      final x0 = math.max(0, (c * tw - padX).floor());
      final y0 = math.max(0, (r * th - padY).floor());
      final x1 = math.min(w, ((c + 1) * tw + padX).ceil());
      final y1 = math.min(h, ((r + 1) * th + padY).ceil());
      out.add((x: x0, y: y0, w: x1 - x0, h: y1 - y0));
    }
  }
  return out;
}

/// 解码 YOLOv8 输出。
///
/// [out] 是 `[1, 4+nc, anchors]` 的**通道主序**扁平数组:第 c 通道第 a 个锚点
/// 落在 `out[c * anchors + a]`。前 4 通道是 cx/cy/w/h(模型输入像素空间),
/// 之后每类一个通道存 sigmoid 过的分数。
///
/// 返回的框已经**还原到原图坐标**并按分数降序,但**还没做 NMS**(见 [nms])。
List<CensorBox> decodeYolo(
  Float32List out, {
  required Letterbox lb,
  int numClasses = 3,
  double confThreshold = kDetConfThreshold,
}) {
  final stride = 4 + numClasses;
  if (out.length % stride != 0) return const [];
  final anchors = out.length ~/ stride;
  final res = <CensorBox>[];
  for (var a = 0; a < anchors; a++) {
    // 先挑出这个锚点上分最高的类,再和阈值比 —— 逐类比会让同一个目标
    // 冒出多个类别的重复框,交给 NMS 收拾反而更脏。
    var best = 0;
    var bestScore = out[4 * anchors + a];
    for (var k = 1; k < numClasses; k++) {
      final s = out[(4 + k) * anchors + a];
      if (s > bestScore) {
        bestScore = s;
        best = k;
      }
    }
    if (bestScore < confThreshold) continue;
    final cx = out[a], cy = out[anchors + a];
    final bw = out[2 * anchors + a], bh = out[3 * anchors + a];
    res.add(
      CensorBox(
        x0: lb.unmapX(cx - bw / 2),
        y0: lb.unmapY(cy - bh / 2),
        x1: lb.unmapX(cx + bw / 2),
        y1: lb.unmapY(cy + bh / 2),
        cls: CensorClass.values[best],
        score: bestScore,
      ),
    );
  }
  res.sort((a, b) => b.score.compareTo(a.score));
  return res;
}

/// 标准 NMS。[boxes] 需已按分数降序([decodeYolo] 的输出就是)。
///
/// **逐类做** —— 不同类别的框天然会重叠(比如胸和身体),跨类压制会把该留的
/// 框吃掉。
List<CensorBox> nms(
  List<CensorBox> boxes, {
  double iouThreshold = kDetIouThreshold,
}) {
  final keep = <CensorBox>[];
  for (final cls in CensorClass.values) {
    final pool = [
      for (final b in boxes)
        if (b.cls == cls) b,
    ];
    final taken = <CensorBox>[];
    for (final b in pool) {
      var drop = false;
      for (final t in taken) {
        if (_iou(b, t) > iouThreshold) {
          drop = true;
          break;
        }
      }
      if (!drop) taken.add(b);
    }
    keep.addAll(taken);
  }
  keep.sort((a, b) => b.score.compareTo(a.score));
  return keep;
}

double _iou(CensorBox a, CensorBox b) {
  final x0 = math.max(a.x0, b.x0), y0 = math.max(a.y0, b.y0);
  final x1 = math.min(a.x1, b.x1), y1 = math.min(a.y1, b.y1);
  final inter = math.max(0, x1 - x0) * math.max(0, y1 - y0);
  final union = a.area + b.area - inter;
  return union <= 0 ? 0 : inter / union;
}

/// 每类的外扩比例。
///
/// 乳头那类框最小、最容易漏边,给得最松;下体两类框本来就大,同比例外扩会
/// 盖掉过多画面,给得紧一些。
const Map<CensorClass, double> kExpandRatio = {
  CensorClass.nippleF: 0.35,
  CensorClass.penis: 0.15,
  CensorClass.pussy: 0.15,
};

/// 把框刷进遮罩网格(格粒度,与手涂共用同一张 [MaskGrid])。
///
/// 只**加**不减:自动预填从不擦掉用户已经涂的东西。
int paintBoxes(
  MaskGrid grid,
  List<CensorBox> boxes, {
  Map<CensorClass, double> expandRatio = kExpandRatio,
}) {
  var painted = 0;
  for (final raw in boxes) {
    final b = raw.expand(expandRatio[raw.cls] ?? 0.15, grid.imgW, grid.imgH);
    final gx0 = (b.x0 / 8).floor().clamp(0, grid.gw - 1);
    final gy0 = (b.y0 / 8).floor().clamp(0, grid.gh - 1);
    // 右/下边界用 ceil:半格也要盖满,宁可多一格
    final gx1 = (b.x1 / 8).ceil().clamp(0, grid.gw);
    final gy1 = (b.y1 / 8).ceil().clamp(0, grid.gh);
    for (var gy = gy0; gy < gy1; gy++) {
      for (var gx = gx0; gx < gx1; gx++) {
        final i = gy * grid.gw + gx;
        if (grid.cells[i] == 0) painted++;
        grid.cells[i] = 1;
      }
    }
  }
  return painted;
}
