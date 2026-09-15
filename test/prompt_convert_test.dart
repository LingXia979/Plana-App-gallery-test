import 'package:flutter_test/flutter_test.dart';

import 'package:plana_app/core/util/prompt_convert.dart';
import 'package:plana_app/core/util/prompt_tokens.dart';

void main() {
  group('SD → NAI', () {
    test('权重词条与裸括号', () {
      expect(
        convertSdToNai('(masterpiece:1.2), (best quality), 1girl'),
        '1.2::masterpiece::, {best quality}, 1girl',
      );
    });

    test('1.05 → {},0.95/0.952381 → []', () {
      expect(convertSdToNai('(a:1.05)'), '{a}');
      expect(convertSdToNai('(b:0.95)'), '[b]');
      expect(convertSdToNai('(b:0.952381)'), '[b]');
    });

    test('整数权重不带 .0(JS Number 语义)', () {
      expect(convertSdToNai('(x:2)'), '2::x::');
    });

    test('转义括号还原为字面括号', () {
      expect(
        convertSdToNai(r'ganyu \(genshin impact\)'),
        'ganyu (genshin impact)',
      );
    });

    test('嵌套:内层裸括号转 {}', () {
      expect(convertSdToNai('(x (y):1.2)'), '1.2::x {y}::');
    });

    test('内容以数字结尾:收口前补空格,免得 `2025::` 被读成权重前缀', () {
      expect(convertSdToNai('(year 2025:1.2)'), '1.2::year 2025 ::');
    });

    test('去 Lora 清洗', () {
      expect(stripLoraTags('<lora:foo:0.8>, a, <lora:bar>, b'), 'a, b');
    });
  });

  group('NAI → SD', () {
    test('权重/花括号/方括号', () {
      expect(
        convertNaiToSd('1.2::masterpiece::, {best quality}, [c]'),
        '(masterpiece:1.2), (best quality:1.05), [c]',
      );
    });

    test('字面括号转义', () {
      expect(
        convertNaiToSd('ganyu (genshin impact)'),
        r'ganyu \(genshin impact\)',
      );
    });

    test('SD→NAI→SD 权重词条回环', () {
      expect(convertNaiToSd(convertSdToNai('(a:1.2)')), '(a:1.2)');
    });
  });

  group('分词清洗', () {
    test('清洗:权重记号/括号/下划线归一/小写', () {
      expect(cleanPromptToken('1.2::Hatsune_Miku::'), 'hatsune miku');
      expect(cleanPromptToken('{blue   eyes}'), 'blue eyes');
    });

    test('清洗:圆括号归空格,画师名带账号的三种写法收成同一个词', () {
      for (final s in [
        'lobelia(saclia)',
        'lobelia (saclia)',
        'lobelia_(saclia)',
      ]) {
        expect(cleanPromptToken(s), 'lobelia saclia', reason: s);
      }
    });

    test('清洗:摘掉 artist: 前缀,大小写与冒号后的空格不影响', () {
      for (final s in [
        'artist:wlop',
        'Artist: wlop',
        '1.1::artist:wlop::',
        '{artist:wlop}',
      ]) {
        expect(cleanPromptToken(s), 'wlop', reason: s);
      }
      // 两个权重组连写、`::` 被检索索引删掉之后,第二个前缀紧贴着上一个画师名
      expect(
        cleanPromptToken('inaedaartist:yoneyama mai'),
        cleanPromptToken('1.2::artist:inaeda::0.4::artist:Yoneyama Mai::'),
      );
      expect(
        cleanPromptToken('artist collaboration'),
        'artist collaboration',
        reason: '没有冒号的不是前缀',
      );
    });
  });
}
