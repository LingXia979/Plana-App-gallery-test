// 自动打码的模型无关层:letterbox 几何、YOLOv8 解码、NMS、框→遮罩。
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/features/inpaint/censor_detect.dart';
import 'package:plana_app/features/inpaint/inpaint_ops.dart';

/// 造一份 `[1, 4+nc, anchors]` 通道主序输出,只在指定锚点上放框。
Float32List yoloOut({
  required int anchors,
  int numClasses = 3,
  required List<
    ({int a, double cx, double cy, double w, double h, int cls, double score})
  >
  dets,
}) {
  final out = Float32List((4 + numClasses) * anchors);
  for (final d in dets) {
    out[d.a] = d.cx;
    out[anchors + d.a] = d.cy;
    out[2 * anchors + d.a] = d.w;
    out[3 * anchors + d.a] = d.h;
    out[(4 + d.cls) * anchors + d.a] = d.score;
  }
  return out;
}

void main() {
  group('letterbox 几何', () {
    test('横图:左右贴边,上下留边', () {
      final lb = Letterbox.fit(1280, 640);
      expect(lb.scale, 0.5);
      expect(lb.padX, 0);
      expect(lb.padY, 160); // (640 - 320) / 2
    });

    test('竖图:上下贴边,左右留边', () {
      final lb = Letterbox.fit(832, 1216);
      expect(lb.scale, closeTo(640 / 1216, 1e-9));
      expect(lb.padY, 0);
      expect(lb.padX, closeTo((640 - 832 * 640 / 1216) / 2, 1e-9));
    });

    test('正反变换互逆 —— 坐标还原写错就是整体偏移', () {
      final lb = Letterbox.fit(832, 1216);
      for (final p in [0.0, 1.0, 415.5, 831.0]) {
        expect(lb.unmapX(lb.mapX(p)), closeTo(p, 1e-6));
      }
      for (final p in [0.0, 7.0, 608.0, 1215.0]) {
        expect(lb.unmapY(lb.mapY(p)), closeTo(p, 1e-6));
      }
    });

    test('原图四角映射到留边内侧,不跑出画布', () {
      final lb = Letterbox.fit(1216, 832);
      expect(lb.mapX(0), closeTo(lb.padX, 1e-9));
      expect(lb.mapY(0), closeTo(lb.padY, 1e-9));
      expect(lb.mapX(1216), closeTo(640 - lb.padX, 1e-6));
      expect(lb.mapY(832), closeTo(640 - lb.padY, 1e-6));
    });
  });

  group('分块方案', () {
    test('图不比输入大 → 不切,整图那遍就够', () {
      expect(planTiles(640, 640), isEmpty);
      expect(planTiles(512, 300), isEmpty);
    });

    test('大图切成网格,块数按边长/输入尺寸取上限', () {
      final t = planTiles(1216, 832);
      expect(t, hasLength(4), reason: '1216/640→2 列,832/640→2 行');
      final t3 = planTiles(2048, 640);
      expect(t3, hasLength(3), reason: '2048/640→4 列夹到 3;640→1 行');
    });

    test('相邻块有重叠 —— 骑在切缝上的目标不会被切两半', () {
      final t = planTiles(1216, 832);
      // 第一块的右边缘应越过第二块的左边缘
      final a = t[0], b = t[1];
      expect(a.x + a.w, greaterThan(b.x));
    });

    test('所有块都夹在图内,且并集盖满整图', () {
      const w = 1216, h = 832;
      final tiles = planTiles(w, h);
      for (final t in tiles) {
        expect(t.x, greaterThanOrEqualTo(0));
        expect(t.y, greaterThanOrEqualTo(0));
        expect(t.x + t.w, lessThanOrEqualTo(w));
        expect(t.y + t.h, lessThanOrEqualTo(h));
        expect(t.w, greaterThan(0));
        expect(t.h, greaterThan(0));
      }
      // 逐像素抽样检查覆盖(步长 16 够了)
      for (var y = 0; y < h; y += 16) {
        for (var x = 0; x < w; x += 16) {
          final hit = tiles.any(
            (t) => x >= t.x && x < t.x + t.w && y >= t.y && y < t.y + t.h,
          );
          expect(hit, isTrue, reason: '($x,$y) 没被任何块覆盖');
        }
      }
    });

    test('块的 letterbox 把框还原到**整图**坐标', () {
      const t = (x: 500, y: 300, w: 400, h: 400);
      final lb = Letterbox.tile(t);
      // 块正中心 → 整图上的 (700, 500)
      expect(lb.unmapX(lb.mapX(700)), closeTo(700, 1e-6));
      expect(lb.unmapY(lb.mapY(500)), closeTo(500, 1e-6));
      // 块左上角映射到留边内侧
      expect(lb.mapX(500), closeTo(lb.padX, 1e-6));
      expect(lb.mapY(300), closeTo(lb.padY, 1e-6));
    });

    test('整图的 letterbox 原点为 0,与旧行为一致', () {
      final lb = Letterbox.fit(832, 1216);
      expect(lb.originX, 0);
      expect(lb.originY, 0);
      expect(lb.unmapX(lb.padX), closeTo(0, 1e-6));
    });
  });

  group('YOLOv8 解码', () {
    test('框还原回原图坐标', () {
      // 832×1216 竖图:scale = 640/1216,左右留边
      final lb = Letterbox.fit(832, 1216);
      // 原图上一个 (100,200)-(180,260) 的框,正推到模型空间再喂回解码
      final cx = (lb.mapX(100) + lb.mapX(180)) / 2;
      final cy = (lb.mapY(200) + lb.mapY(260)) / 2;
      final w = lb.mapX(180) - lb.mapX(100);
      final h = lb.mapY(260) - lb.mapY(200);
      final out = yoloOut(
        anchors: 8400,
        dets: [(a: 42, cx: cx, cy: cy, w: w, h: h, cls: 0, score: 0.9)],
      );
      final boxes = decodeYolo(out, lb: lb);
      expect(boxes, hasLength(1));
      expect(boxes.first.x0, closeTo(100, 1e-3));
      expect(boxes.first.y0, closeTo(200, 1e-3));
      expect(boxes.first.x1, closeTo(180, 1e-3));
      expect(boxes.first.y1, closeTo(260, 1e-3));
      expect(boxes.first.cls, CensorClass.nippleF);
    });

    test('低于阈值的丢掉', () {
      final lb = Letterbox.fit(640, 640);
      final out = yoloOut(
        anchors: 100,
        dets: [
          (a: 1, cx: 50, cy: 50, w: 10, h: 10, cls: 0, score: 0.05),
          (a: 2, cx: 90, cy: 90, w: 10, h: 10, cls: 1, score: 0.5),
        ],
      );
      final boxes = decodeYolo(out, lb: lb);
      expect(boxes, hasLength(1));
      expect(boxes.first.cls, CensorClass.penis);
    });

    test('同一锚点取最高分的类,不重复出框', () {
      final lb = Letterbox.fit(640, 640);
      final anchors = 100;
      final out = Float32List(7 * anchors);
      out[3] = 50;
      out[anchors + 3] = 50;
      out[2 * anchors + 3] = 20;
      out[3 * anchors + 3] = 20;
      out[4 * anchors + 3] = 0.30; // nippleF
      out[5 * anchors + 3] = 0.85; // penis ← 最高
      out[6 * anchors + 3] = 0.25; // pussy
      final boxes = decodeYolo(out, lb: lb);
      expect(boxes, hasLength(1));
      expect(boxes.first.cls, CensorClass.penis);
      expect(boxes.first.score, closeTo(0.85, 1e-6));
    });

    test('按分数降序', () {
      final lb = Letterbox.fit(640, 640);
      final out = yoloOut(
        anchors: 50,
        dets: [
          (a: 1, cx: 10, cy: 10, w: 4, h: 4, cls: 0, score: 0.4),
          (a: 2, cx: 90, cy: 90, w: 4, h: 4, cls: 0, score: 0.95),
          (a: 3, cx: 300, cy: 300, w: 4, h: 4, cls: 0, score: 0.6),
        ],
      );
      final s = decodeYolo(out, lb: lb).map((b) => b.score).toList();
      expect(s, [greaterThan(0.9), closeTo(0.6, 1e-6), closeTo(0.4, 1e-6)]);
    });

    test('长度对不上 → 空,不崩', () {
      expect(decodeYolo(Float32List(13), lb: Letterbox.fit(64, 64)), isEmpty);
    });
  });

  group('NMS', () {
    CensorBox box(
      double x,
      double y,
      double s, {
      CensorClass c = CensorClass.nippleF,
      double sc = 0.9,
    }) => CensorBox(x0: x, y0: y, x1: x + s, y1: y + s, cls: c, score: sc);

    test('高度重叠的同类框只留最高分那个', () {
      final r = nms([box(0, 0, 100, sc: 0.9), box(5, 5, 100, sc: 0.8)]);
      expect(r, hasLength(1));
      expect(r.first.score, closeTo(0.9, 1e-6));
    });

    test('不重叠的都留着', () {
      final r = nms([box(0, 0, 50), box(200, 200, 50)]);
      expect(r, hasLength(2));
    });

    test('跨类不互相压制 —— 不同部位天然会重叠', () {
      final r = nms([
        box(0, 0, 100, c: CensorClass.nippleF, sc: 0.9),
        box(0, 0, 100, c: CensorClass.pussy, sc: 0.8),
      ]);
      expect(r, hasLength(2));
    });
  });

  group('框 → 遮罩', () {
    test('覆盖框所在的格,并按类别外扩', () {
      final g = MaskGrid(256, 256);
      // 不外扩时占 (80,80)-(120,120);nippleF 外扩 0.35 → 各边多 14px
      final n = paintBoxes(g, [
        const CensorBox(
          x0: 80,
          y0: 80,
          x1: 120,
          y1: 120,
          cls: CensorClass.nippleF,
          score: 0.9,
        ),
      ]);
      expect(n, greaterThan(0));
      // 外扩后左上角到 66 → 落在第 8 格(64..71)
      expect(g.cells[(66 ~/ 8) * g.gw + (66 ~/ 8)], 1);
      // 框外远处不该被碰
      expect(g.cells[(200 ~/ 8) * g.gw + (200 ~/ 8)], 0);
    });

    test('只加不减:不擦掉用户已涂的格', () {
      final g = MaskGrid(128, 128);
      g.cells[0] = 1; // 用户涂的
      paintBoxes(g, [
        const CensorBox(
          x0: 60,
          y0: 60,
          x1: 70,
          y1: 70,
          cls: CensorClass.pussy,
          score: 0.9,
        ),
      ]);
      expect(g.cells[0], 1, reason: '预填不该动用户涂过的格');
    });

    test('外扩越界被夹回图内,不越界写数组', () {
      final g = MaskGrid(64, 64);
      expect(
        () => paintBoxes(g, [
          const CensorBox(
            x0: 0,
            y0: 0,
            x1: 64,
            y1: 64,
            cls: CensorClass.nippleF,
            score: 0.9,
          ),
        ]),
        returnsNormally,
      );
      expect(g.isEmpty, isFalse);
    });

    test('返回新涂格数;重复刷同一个框第二次为 0', () {
      final g = MaskGrid(128, 128);
      const b = CensorBox(
        x0: 30,
        y0: 30,
        x1: 60,
        y1: 60,
        cls: CensorClass.penis,
        score: 0.9,
      );
      final first = paintBoxes(g, [b]);
      expect(first, greaterThan(0));
      expect(paintBoxes(g, [b]), 0);
    });
  });
}
