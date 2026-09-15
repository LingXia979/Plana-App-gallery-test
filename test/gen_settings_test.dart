import 'package:flutter_test/flutter_test.dart';

import 'package:plana_app/core/store/gen_settings.dart';

void main() {
  test('生成设置 json 回环', () {
    const s = GenSettings(
      retryOn429: false,
      retryDelaySecs: 0,
      retryCount: 2,
      streamGen: false,
    );
    expect(GenSettings.fromJson(s.toJson()), s);
  });

  test('流式生成默认开;老存档没这个字段也按开算', () {
    expect(const GenSettings().streamGen, isTrue);
    expect(GenSettings.fromJson({'retryCount': 5}).streamGen, isTrue);
    expect(GenSettings.fromJson({'streamGen': 'off'}).streamGen, isTrue);
    expect(GenSettings.fromJson({'streamGen': false}).streamGen, isFalse);
  });

  test('脏数据/缺字段回退默认(重试开 · 1 秒 · 3 次)', () {
    expect(GenSettings.fromJson({}), const GenSettings());
    expect(GenSettings.fromJson({'retryOn429': 'yes'}).retryOn429, isTrue);
    expect(GenSettings.fromJson({}).retryDelaySecs, 1);
    expect(GenSettings.fromJson({}).retryCount, 3);
  });

  test('数值夹取:间隔 0~600、次数 1~99', () {
    expect(GenSettings.fromJson({'retryDelaySecs': -3}).retryDelaySecs, 0);
    expect(GenSettings.fromJson({'retryDelaySecs': 9999}).retryDelaySecs, 600);
    expect(GenSettings.fromJson({'retryCount': 0}).retryCount, 1);
    expect(GenSettings.fromJson({'retryCount': 500}).retryCount, 99);
  });
}
