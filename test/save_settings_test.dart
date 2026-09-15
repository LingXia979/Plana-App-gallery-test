import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:plana_app/core/util/png_meta.dart';
import 'package:plana_app/features/gallery/save_pipeline.dart';
import 'package:plana_app/features/gallery/save_settings.dart';
import 'package:plana_app/features/gallery/zip_pipeline.dart';
import 'package:plana_app/features/import/image_metadata.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('保存设置 json 回环 + 脏数据回退', () {
    const s = SaveSettings(
      meta: SaveMeta.custom,
      format: SaveFormat.jpg,
      quality: 0.5,
      customPrompt: '1girl',
    );
    expect(SaveSettings.fromJson(s.toJson()), s);
    expect(SaveSettings.fromJson({}), const SaveSettings());
    expect(SaveSettings.fromJson({'meta': 'nope', 'quality': 99}).quality, 1.0);
    expect(SaveSettings.fromJson({'meta': 'nope'}).meta, SaveMeta.original);
  });

  test('保存管线:PNG 原样直出;JPG 重编码为无 alpha 的 JPEG', () async {
    final rgba = Uint8List(64 * 64 * 4);
    for (var i = 0; i < rgba.length; i += 4) {
      rgba[i] = 200;
      rgba[i + 1] = 120;
      rgba[i + 2] = 40;
      rgba[i + 3] = 255;
    }
    final png = await encodePngFromRgba(rgba, 64, 64);

    final original = await processForSave(png, const SaveSettings());
    expect(identical(original, png), isTrue); // 原始 = 零拷贝直出

    final jpg = await processForSave(
      png,
      const SaveSettings(format: SaveFormat.jpg, quality: 0.8),
    );
    final decoded = img.decodeJpg(jpg);
    expect(decoded, isNotNull);
    expect(decoded!.width, 64);
  });

  test('保存管线:PNG+覆写可被读取端解析,PNG+清除读不出', () async {
    final rgba = Uint8List(160 * 160 * 4);
    for (var i = 3; i < rgba.length; i += 4) {
      rgba[i] = 255;
    }
    final png = await encodePngFromRgba(rgba, 160, 160);

    final custom = await processForSave(
      png,
      const SaveSettings(meta: SaveMeta.custom, customPrompt: 'plana, smile'),
    );
    final meta = await extractImageMetadata(custom);
    expect(meta?.prompt, 'plana, smile');

    final clean = await processForSave(
      custom,
      const SaveSettings(meta: SaveMeta.clean),
    );
    expect(await extractImageMetadata(clean), isNull);
  });

  // 一批 N 张共用一个 seed,多选打包时名字必然撞 —— zip 允许重名条目,
  // 解出来却是互相覆盖,少的那几张用户根本发现不了。
  group('打包 ZIP 的包内文件名', () {
    test('与保存/分享同款,重名依次补 _2 _3', () {
      final used = <String>{};
      expect(zipEntryName(123, 'png', used), 'plana_123.png');
      expect(zipEntryName(123, 'png', used), 'plana_123_2.png');
      expect(zipEntryName(123, 'png', used), 'plana_123_3.png');
      expect(zipEntryName(456, 'png', used), 'plana_456.png');
    });

    test('跟着保存格式走', () {
      expect(zipEntryName(7, 'jpg', <String>{}), 'plana_7.jpg');
    });

    test('换了扩展名不算重名', () {
      final used = <String>{};
      expect(zipEntryName(7, 'png', used), 'plana_7.png');
      expect(zipEntryName(7, 'jpg', used), 'plana_7.jpg');
    });
  });

  // 包名由用户在打包弹层里改,直接落到文件系统上 —— 带非法字符会让整次导出
  // 失败,而空名字得在按钮上就拦住。
  group('打包 ZIP 的包名清洗', () {
    test('剔除文件系统非法字符', () {
      expect(sanitizeZipName('a/b\\c:d*e?f"g<h>i|j'), 'abcdefghij');
    });

    test('压缩空白并去两端', () {
      expect(sanitizeZipName('  plana   精选  '), 'plana 精选');
    });

    test('自己打了 .zip 不会变成 .zip.zip', () {
      expect(sanitizeZipName('plana.ZIP'), 'plana');
      expect(sanitizeZipName('plana.zip'), 'plana');
      expect(sanitizeZipName('plana.zip.zip'), 'plana.zip');
    });

    test('去掉首尾的点', () {
      expect(sanitizeZipName('.plana.'), 'plana');
      expect(sanitizeZipName('plana-2026.'), 'plana-2026');
    });

    test('全非法/全空白 → 空串(调用方据此禁用打包)', () {
      expect(sanitizeZipName('///'), '');
      expect(sanitizeZipName('   '), '');
      expect(sanitizeZipName('.zip'), '');
    });

    test('中文与常规字符原样保留', () {
      expect(sanitizeZipName('plana 精选-2026_v2'), 'plana 精选-2026_v2');
    });
  });
}
