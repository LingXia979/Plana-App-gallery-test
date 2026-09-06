// 图库分组:按时间 / 按归属(角色、画风)分堆的纯函数 + 画风判定表。
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/util/prompt_tokens.dart';
import 'package:plana_app/features/gallery/gallery_groups.dart';
import 'package:plana_app/features/gallery/models.dart';
import 'package:plana_app/features/inspiration/tag_models.dart';

ResultImage img(String id, DateTime at) => ResultImage(
  id: id,
  width: 832,
  height: 1216,
  seed: 1,
  createdAt: at.millisecondsSinceEpoch,
);

GroupTag tag(String k, [String? label]) => (key: k, label: label ?? k);

void main() {
  group('按天分堆', () {
    test('键的首现序即堆序,段头文案照旧', () {
      final now = DateTime(2026, 9, 6, 12);
      final g = groupByDay([
        img('a', DateTime(2026, 9, 6, 10)),
        img('b', DateTime(2026, 9, 6, 9)),
        img('c', DateTime(2026, 9, 5, 23)),
      ], now);
      expect(g.map((e) => e.label), ['今天', '昨天']);
      expect(g.first.items.map((e) => e.id), ['a', 'b']);
    });

    test('无时间戳归「更早」', () {
      final g = groupByDay([
        img('a', DateTime(2026, 9, 6)),
        const ResultImage(id: 'z', width: 1, height: 1, seed: 0),
      ], DateTime(2026, 9, 6, 12));
      expect(g.last.label, '更早');
      expect(g.last.items.single.id, 'z');
    });
  });

  group('按归属分堆', () {
    // 时间:a 最新 → c 最旧
    final a = img('a', DateTime(2026, 9, 6, 12));
    final b = img('b', DateTime(2026, 9, 6, 11));
    final c = img('c', DateTime(2026, 9, 6, 10));

    test('一张多角色的图,每一堆里都看得到', () {
      final g = groupByTags([a, b], {
        'a': [tag('ganyu_(genshin_impact)', '甘雨'), tag('keqing', '刻晴')],
        'b': [tag('keqing', '刻晴')],
      });
      expect(g.map((e) => e.label), ['甘雨', '刻晴']);
      expect(g[0].items.map((e) => e.id), ['a']);
      // 双人图在刻晴那堆里也在,只归一边的话另一边的合集就是缺的
      expect(g[1].items.map((e) => e.id), ['a', 'b']);
    });

    test('堆序按堆内最新一张降序,未归类恒垫底', () {
      final g = groupByTags([a, b, c], {
        // c 最旧却排在前面传入 —— 堆序看的是时间不是传入序
        'c': [tag('x')],
        'b': [tag('y')],
      });
      expect(g.map((e) => e.key), ['y', 'x', kGalleryUngroupedKey]);
      expect(g.last.label, '未归类');
      expect(g.last.items.map((e) => e.id), ['a']);
    });

    test('堆内保持传入顺序(调用方已按新→旧)', () {
      final g = groupByTags([a, b, c], {
        'a': [tag('x')],
        'b': [tag('x')],
        'c': [tag('x')],
      });
      expect(g.single.items.map((e) => e.id), ['a', 'b', 'c']);
    });

    test('归属表为空 / 全空列表 → 只有未归类,或什么都没有', () {
      expect(groupByTags([a, b], const {}).single.key, kGalleryUngroupedKey);
      expect(groupByTags(const [], const {}), isEmpty);
      // 有键但值是空表,等同于没归属
      expect(
        groupByTags([a], {'a': const []}).single.key,
        kGalleryUngroupedKey,
      );
    });

    test('显示名以先到的为准,键相同即同一堆', () {
      final g = groupByTags([a, b], {
        'a': [tag('hakurei_reimu', '博丽灵梦')],
        'b': [tag('hakurei_reimu', '灵梦')],
      });
      expect(g.single.label, '博丽灵梦');
      expect(g.single.items.length, 2);
    });
  });

  group('画风判定(标签集包含)', () {
    TagEntry style(String name, String positive) => TagEntry(
      id: 'e_$name',
      category: TagCategory.artist,
      name: name,
      positive: positive,
    );

    test('条目标签全在图里才算命中,少一枚不算', () {
      final m = StyleMatcher([style('冷淡水彩', 'artist:wlop, artist:ciloranko')]);
      expect(
        m.match(tokenizeSet('1girl, artist:wlop, artist:ciloranko, solo')),
        [(key: '冷淡水彩', label: '冷淡水彩')],
      );
      // 只用了其中一枚 —— 那不是这个画风,不能归进去
      expect(m.match(tokenizeSet('1girl, artist:wlop')), isEmpty);
    });

    test('共用画师的两个条目不互相串味', () {
      final m = StyleMatcher([
        style('A', 'artist:wlop, artist:ciloranko'),
        style('B', 'artist:wlop, artist:rella'),
      ]);
      final hit = m.match(tokenizeSet('artist:wlop, artist:rella, 1girl'));
      expect(hit.map((e) => e.key), ['B']);
    });

    test('下划线/权重/括号写法同归一', () {
      final m = StyleMatcher([style('阿米娅风', 'ke-ta, mika_pikazo')]);
      for (final form in [
        'ke-ta, mika_pikazo',
        '{ke-ta}, 1.3::mika pikazo::',
        'KE-TA, Mika_Pikazo, 1girl',
      ]) {
        expect(m.match(tokenizeSet(form)).length, 1, reason: form);
      }
    });

    test('没标签 / 没名字的条目一律剔掉,不当成「人人都用了」', () {
      // 空标签集若留着,containsAll 恒真 —— 全库每张图都会归进这个条目
      final m = StyleMatcher([style('空标签', '  '), style('  ', 'a, b')]);
      expect(m.match(tokenizeSet('随便什么, 别的')), isEmpty);
      expect(m.match(tokenizeSet('a, b')), isEmpty, reason: '没名字的条目也不该归组');
      // 剔干净后整表为空,provider 据此早退
      expect(m.isEmpty, isTrue);
      expect(StyleMatcher(const []).isEmpty, isTrue);
    });

    test('同名条目(本地 + 收藏的公共副本)只出一条', () {
      final m = StyleMatcher([
        style('同一个', 'a, b'),
        style('同一个', 'a, b'),
      ]);
      expect(m.match(tokenizeSet('a, b, c')).length, 1);
    });

    test('同名但内容不同时,先撞上的没过不挡住后一个', () {
      final m = StyleMatcher([
        style('撞名', 'a, zzz'), // 不会命中
        style('撞名', 'a, b'), // 该命中
      ]);
      expect(m.match(tokenizeSet('a, b')).map((e) => e.key), ['撞名']);
    });
  });

  test('GalleryGroupBy 的存档名稳定(UiPrefs 存的是 name)', () {
    expect(GalleryGroupBy.day.name, 'day');
    expect(GalleryGroupBy.character.name, 'character');
    expect(GalleryGroupBy.style.name, 'style');
    expect(GalleryGroupBy.day.label, '按时间');
    expect(GalleryGroupBy.character.label, '按角色');
    expect(GalleryGroupBy.style.label, '按画风');
    // 时间走分段列表,归属类的走堆叠封面墙
    expect(GalleryGroupBy.day.stacked, isFalse);
    expect(GalleryGroupBy.character.stacked, isTrue);
    expect(GalleryGroupBy.style.stacked, isTrue);
  });
}
