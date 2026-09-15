import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/features/inpaint/inpaint_ops.dart';

/// 重绘蒙版按图记忆的编解码。
/// 存的是 MaskGrid 的原始格子(每格 1 字节 0/1)+ 8 字节尺寸头,
/// 不做光栅化 —— 所以往返必须一字不差,尺寸不符必须拒绝(否则会把
/// 旧蒙版按错误的行宽铺上去,画面完全对不上)。
void main() {
  _prefsTests();
  MaskGrid painted(int w, int h) {
    final g = MaskGrid(w, h);
    g.paintDot(w / 2, h / 2, 64);
    return g;
  }

  test('往返:编码再解回,格子一字不差', () {
    final a = painted(1216, 832);
    expect(a.isEmpty, isFalse);

    final b = MaskGrid(1216, 832);
    expect(b.decodeInto(a.encode()), isTrue);
    expect(b.cells, a.cells);
  });

  test('空蒙版往返仍为空', () {
    final a = MaskGrid(832, 1216);
    final b = MaskGrid(832, 1216);
    expect(b.decodeInto(a.encode()), isTrue);
    expect(b.isEmpty, isTrue);
  });

  test('尺寸不符必须拒绝(扩图/裁切后的旧蒙版)', () {
    final old = painted(832, 1216);
    final wider = MaskGrid(1216, 832); // 长宽对调
    expect(wider.decodeInto(old.encode()), isFalse);
    expect(wider.isEmpty, isTrue, reason: '拒绝后应保持空白,不能铺上错位数据');
  });

  test('损坏/截断数据不崩,直接拒绝', () {
    final g = MaskGrid(512, 512);
    expect(g.decodeInto(Uint8List(0)), isFalse);
    expect(g.decodeInto(Uint8List(4)), isFalse);
    final truncated = Uint8List.fromList(
      painted(512, 512).encode().sublist(0, 20),
    );
    expect(g.decodeInto(truncated), isFalse);
    expect(g.isEmpty, isTrue);
  });

  test('编码体积可控:1216×832 图约 15KB 量级', () {
    final n = painted(1216, 832).encode().length;
    expect(n, lessThan(32 * 1024), reason: '每张图一份,不能大到影响图库存储');
  });

  // ---- 轮廓(重绘完成后遮罩退成描边,不挡结果像素)----

  /// 路径总长度:每段 moveTo+lineTo 是一条独立 contour。
  double outlineLength(MaskGrid g) => g
      .outlinePath()
      .computeMetrics()
      .fold<double>(0, (sum, m) => sum + m.length);

  test('单格轮廓 = 四条边', () {
    final g = MaskGrid(64, 64);
    g.cells[0] = 1;
    expect(outlineLength(g), closeTo(32, .01), reason: '4 条边 × 8px');
  });

  test('相邻格之间的内部边不画(轮廓不是网格线)', () {
    final g = MaskGrid(64, 64);
    g.cells[0] = 1;
    g.cells[1] = 1; // 右邻格
    // 各画各的是 64;并集外轮廓应为 6 段 = 48,中间那条共享边必须省掉
    expect(outlineLength(g), closeTo(48, .01));
  });

  test('空蒙版轮廓为空', () {
    expect(outlineLength(MaskGrid(64, 64)), 0);
  });

  test('实心块只描外圈:3×3 格 = 周长 4×24', () {
    final g = MaskGrid(64, 64);
    for (var y = 0; y < 3; y++) {
      for (var x = 0; x < 3; x++) {
        g.cells[y * g.gw + x] = 1;
      }
    }
    expect(outlineLength(g), closeTo(96, .01), reason: '内部 12 条边全省掉');
  });
}

void _prefsTests() {
  group('重绘偏好的存取', () {
    test('一来一回不丢字段', () {
      const p = InpaintPrefs(
        brush: 88,
        strength: 0.42,
        assist: true,
        mode: 'censor',
        censorStyle: 'solid',
        censorColor: 0xFFFFFFFF,
      );
      final back = InpaintPrefs.fromJson(p.toJson());
      expect(back.brush, 88);
      expect(back.strength, closeTo(0.42, 1e-9));
      expect(back.assist, isTrue);
      expect(back.mode, 'censor');
      expect(back.censorStyle, 'solid');
      expect(back.censorColor, 0xFFFFFFFF);
    });

    test('旧版本存的 JSON(没有新字段)读回来是默认值', () {
      final old = InpaintPrefs.fromJson({
        'brush': 60,
        'strength': 0.5,
        'assist': false,
      });
      expect(old.mode, 'paint');
      expect(old.censorStyle, 'mosaic');
      expect(old.censorColor, 0xFF000000);
    });

    test('认不出的模式一律回落 paint —— 枚举改名/降级装回来都不能崩', () {
      expect(InpaintPrefs.fromJson({'mode': 'wat'}).mode, 'paint');
      expect(InpaintPrefs.fromJson({'mode': 3}).mode, 'paint');
      expect(InpaintPrefs.fromJson({'mode': null}).mode, 'paint');
      expect(
        InpaintPrefs.fromJson({'censorStyle': 'wat'}).censorStyle,
        'mosaic',
      );
    });

    test('笔刷与强度越界被夹回合法档', () {
      expect(InpaintPrefs.fromJson({'brush': 9999}).brush, 400);
      expect(InpaintPrefs.fromJson({'brush': -5}).brush, 4);
      expect(InpaintPrefs.fromJson({'strength': 5}).strength, 1.0);
    });
  });
}
