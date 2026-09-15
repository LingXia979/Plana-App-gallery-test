// 多选「打包 ZIP」:包真能解回来(加了密的也是),中途取消不留半成品。
//
// zip 编码在后台 isolate 上跑(加密是纯 Dart 的 AES,搁主 isolate 上界面直接
// 僵住),主从之间隔着端口传命令 —— 这条协议不测就只能靠装机发现它挂了。
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plana_app/core/store/blob_store.dart';
import 'package:plana_app/core/store/cache_sweep.dart' show kShareCacheDir;
import 'package:plana_app/features/gallery/gallery_store.dart';
import 'package:plana_app/features/gallery/models.dart';
import 'package:plana_app/features/gallery/save_settings.dart';
import 'package:plana_app/features/gallery/zip_pipeline.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late GalleryStore store;

  // 包落在 cache/share 下,而 getTemporaryDirectory 在测试里没有插件接
  setUp(() {
    root = Directory.systemTemp.createTempSync('plana_zip');
    store = GalleryStore(BlobStore(root), root);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => root.path,
        );
  });

  tearDown(() {
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  // bytes 直接带在手上,readImage 就不进来 —— 测的是打包那一段
  List<ResultImage> pics(int n) => [
    for (var i = 0; i < n; i++)
      ResultImage(
        id: 'gen$i',
        width: 8,
        height: 8,
        seed: 100 + i,
        createdAt: DateTime(2026, 3, 4, 5, 6).millisecondsSinceEpoch,
        bytes: Uint8List.fromList(List.generate(300, (b) => (b + i) & 0xff)),
      ),
  ];

  Future<({File? file, int packed, int failed})> pack(
    List<ResultImage> items, {
    String? password,
    bool Function(int done)? onEach,
  }) => packImagesZip(
    items,
    store: store,
    settings: const SaveSettings(),
    fileName: 'out.zip',
    password: password,
    onEach: onEach,
  );

  test('不加密:三张都在,字节与原图一致', () async {
    final items = pics(3);
    final r = await pack(items);
    expect(r.packed, 3);
    expect(r.failed, 0);

    final zip = ZipDecoder().decodeBytes(await r.file!.readAsBytes());
    expect(zip.files.map((f) => f.name), [
      'plana_100.png',
      'plana_101.png',
      'plana_102.png',
    ]);
    for (var i = 0; i < 3; i++) {
      expect(zip.files[i].readBytes(), items[i].bytes);
    }
  });

  test('加密:要密码才解得开,解出来还是原字节', () async {
    final items = pics(2);
    final r = await pack(items, password: 'hunter2');
    expect(r.packed, 2);

    final bytes = await r.file!.readAsBytes();
    final zip = ZipDecoder().decodeBytes(bytes, password: 'hunter2');
    expect(zip.files.length, 2);
    expect(zip.files[0].readBytes(), items[0].bytes);
    expect(zip.files[1].readBytes(), items[1].bytes);

    // 密码错 / 不给密码都不该悄悄吐出明文
    expect(
      () => ZipDecoder()
          .decodeBytes(bytes, password: 'nope')
          .files
          .first
          .readBytes(),
      throwsA(anything),
    );
    expect(
      () => ZipDecoder().decodeBytes(bytes).files.first.readBytes(),
      throwsA(anything),
    );
  });

  // 每张由各自的 worker 单独编成一个小包,再拼成一个大包 —— 拼接要是错了位,
  // 条目顺序、偏移、中央目录任意一处都能坏,而且只在多于一波时才露出来。
  test('九张分几波编完,顺序和内容都不错位', () async {
    final items = pics(9);
    final r = await pack(items, password: 'hunter2');
    expect(r.packed, 9);

    final zip = ZipDecoder().decodeBytes(
      await r.file!.readAsBytes(),
      password: 'hunter2',
      verify: true, // 逐条核 crc
    );
    expect(zip.files.length, 9);
    for (var i = 0; i < 9; i++) {
      expect(zip.files[i].name, 'plana_${100 + i}.png');
      expect(zip.files[i].readBytes(), items[i].bytes);
    }
  });

  test('中途取消:不留半成品', () async {
    final r = await pack(pics(5), onEach: (done) => done < 2);
    expect(r.file, isNull);
    expect(
      Directory(
        '${root.path}/$kShareCacheDir',
      ).listSync().whereType<File>().where((f) => f.path.endsWith('.zip')),
      isEmpty,
    );
  });

  test('一张都读不出来:不交空包', () async {
    final r = await pack([
      const ResultImage(id: 'missing', width: 8, height: 8, seed: 1),
    ]);
    expect(r.file, isNull);
    expect(r.packed, 0);
    expect(r.failed, 1);
  });

  // 解出来按时间排,顺序该和出图时一样,而不是全挤在打包那一分钟
  test('包内时间用的是出图那一刻', () async {
    final r = await pack(pics(1));
    final zip = ZipDecoder().decodeBytes(await r.file!.readAsBytes());
    // zip 存的是本地挂钟上的 DOS 时间;lastModDateTime 原样读回来标成 utc
    expect(zip.files.first.lastModDateTime, DateTime.utc(2026, 3, 4, 5, 6));
  });
}
