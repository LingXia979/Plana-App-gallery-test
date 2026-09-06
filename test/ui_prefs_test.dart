// UiPrefs 的编解码兜底:每一项各自回默认,一项是垃圾值不连累其余项。
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/store/ui_prefs.dart';

void main() {
  test('往返一致', () {
    const p = UiPrefs(
      statsRange: 'month',
      toolsTab: 2,
      genSettingsTab: 'comfy',
      completionByHeat: false,
      galleryDaysFilter: 7,
      galleryGroupBy: 'style',
      galleryColumns: 5,
    );
    final back = UiPrefs.fromJson(p.toJson());
    expect(back.galleryGroupBy, 'style');
    expect(back.galleryColumns, 5);
    expect(back.galleryDaysFilter, 7);
    expect(back.statsRange, 'month');
  });

  test('图库列数越界夹回,缺键给默认', () {
    // 双指捏合存的是夹过的值,但存档可能来自旧版/被改过
    expect(UiPrefs.fromJson({'galleryColumns': 99}).galleryColumns, 5);
    expect(UiPrefs.fromJson({'galleryColumns': 1}).galleryColumns, 2);
    expect(UiPrefs.fromJson({'galleryColumns': 0}).galleryColumns, 2);
    expect(UiPrefs.fromJson({'galleryColumns': -3}).galleryColumns, 2);
    expect(UiPrefs.fromJson(const {}).galleryColumns, 3);
    // 字符串不能让整份 fromJson 抛异常 —— 抛了就是「所有偏好一起被重置」
    expect(UiPrefs.fromJson({'galleryColumns': 'x'}).galleryColumns, 3);
    expect(UiPrefs.fromJson({'toolsTab': 'x'}).toolsTab, 0);
    expect(kGalleryMinColumns, 2);
    expect(kGalleryMaxColumns, 5);
  });

  test('分组维度认不出的值回「按时间」,不连累别的项', () {
    final p = UiPrefs.fromJson({'galleryGroupBy': 42, 'galleryColumns': 4});
    expect(p.galleryGroupBy, 'day');
    expect(p.galleryColumns, 4, reason: '一项是垃圾值不该连累其余项');
  });
}
