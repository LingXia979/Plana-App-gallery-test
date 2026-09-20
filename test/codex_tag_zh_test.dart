import 'dart:convert';

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:plana_app/features/editor/data/tag_translation_service.dart';
import 'package:plana_app/features/inspiration/codex/codex_models.dart';
import 'package:plana_app/features/inspiration/codex/codex_tag_zh.dart';
import 'package:plana_app/features/inspiration/widgets/prompt_chips.dart';

/// 原站 tag 中文对照(`data/tag_zh/`)的接入:查表键与原站逐条一致、三组译名的
/// 优先级、缓存戳,以及芯片流里「对照表优先、表在路上先不问后端」。
void main() {
  // 原站 tools/fixtures/tag_zh_keys.json 原样照搬(2026-09-19)。原站前端
  // tagZhKey 与构建端 tag_key 靠它防漂移;这边也得对上,否则表里有也查不到。
  // 原站改了规则就同步这份,再跑一遍。
  const upstreamCases = [
    ['1girl', '1girl'],
    ['Long_Hair', 'long hair'],
    ['  looking   at_viewer ', 'looking at viewer'],
    ['{{collared shirt', 'collared shirt'],
    ['shirt under sweater}}', 'shirt under sweater'],
    ['[[[[[from side]]]]]', 'from side'],
    ['1.4::undead girl::', 'undead girl'],
    [
      '1.4:: a chibi skeleton grim reaper sits atop her head',
      'a chibi skeleton grim reaper sits atop her head',
    ],
    ['-1::nipples', 'nipples'],
    ['2::black reverse outfit', 'black reverse outfit'],
    ['0.5::artist:bloomminority::', ''],
    ['artist:ciloranko', ''],
    ['Artist: tsunako', ''],
    ['(white sweater:1.2)', 'white sweater'],
    ['((masterpiece))', 'masterpiece'],
    ['(checkered shirt:0.8', 'checkered shirt'],
    ['checkered shirt:1.2)', 'checkered shirt'],
    ['sho (sho lwlw)', 'sho (sho lwlw)'],
    ['(sho (sho lwlw):1.2)', 'sho (sho lwlw)'],
    ['arrow_(projectile)}}', 'arrow (projectile)'],
    ['{{ bow (weapon) ', 'bow (weapon)'],
    [r'hatsune miku \(cosplay\)', 'hatsune miku (cosplay)'],
    ['"{{{normal quality', 'normal quality'],
    ['dual wielding"', 'dual wielding'],
    [':)', ''],
    ['(:d:1.2)', ':d'],
    ['+ +', ''],
    ['::', ''],
    ['', ''],
    ['画风', ''],
    ['year 2024', 'year 2024'],
    ['rating:general', 'rating:general'],
    ['fate/zero', 'fate/zero'],
    ['</style>', '</style>'],
  ];

  group('tagZhKey 与原站夹具逐条一致', () {
    for (final c in upstreamCases) {
      test('${jsonEncode(c[0])} → ${jsonEncode(c[1])}', () {
        expect(tagZhKey(c[0]), c[1]);
      });
    }

    test('超长(>300 字)不查', () {
      expect(tagZhKey('a' * 300), 'a' * 300);
      expect(tagZhKey('a' * 301), '');
    });
  });

  group('TagZhShard.fromJson', () {
    test('schema 不认、不是对象 → null(当作没有对照表)', () {
      expect(TagZhShard.fromJson({'schema': 2, 'd': {}}), isNull);
      expect(TagZhShard.fromJson({'d': {}}), isNull);
      expect(TagZhShard.fromJson(const ['x']), isNull);
      expect(TagZhShard.fromJson(null), isNull);
    });

    test('空白 / 非字符串的译名丢掉;shards 只收字符串', () {
      final s = TagZhShard.fromJson({
        'schema': 1,
        'm': {'cowboy shot': '七分身（大腿以上）'},
        'd': {'1girl': '单人女性', 'blank': '  ', 'num': 3},
        'a': 'oops',
        'shards': ['suozhang', 7, 'raven_composition'],
      })!;
      expect(s.m, {'cowboy shot': '七分身（大腿以上）'});
      expect(s.d, {'1girl': '单人女性'});
      expect(s.a, isEmpty);
      expect(s.shards, ['suozhang', 'raven_composition']);
    });

    test('坏 JSON 经 tagZhParsePayload 回 null,不抛', () {
      expect(tagZhParsePayload('{not json'), isNull);
    });
  });

  group('CodexTagZh.lookup', () {
    const core = TagZhShard(
      m: {'text': '文字'},
      d: {'1girl': '单人女性', 'long hair': '长发', 'text': '文字焦点'},
      a: {'very aesthetic': '极具美感', 'long hair': '长长的头发'},
    );
    const shard = TagZhShard(
      m: {'very aesthetic': '人工订正'},
      a: {'1.blue horn-shaped hair ornaments': '蓝色角状发饰'},
    );
    const zh = CodexTagZh(core, shard);

    test('人工 > 词库 > AI;跨表也按组排,先组后表', () {
      expect(zh.lookup('text'), '文字', reason: '人工压过词库');
      expect(zh.lookup('long hair'), '长发', reason: '词库压过 AI');
      expect(
        zh.lookup('very aesthetic'),
        '人工订正',
        reason: '分片的人工组排在 core 的 AI 组前面',
      );
    });

    test('键先归一:权重、下划线、大小写都不影响命中', () {
      expect(zh.lookup('{{Long_Hair}}'), '长发');
      expect(zh.lookup('1.3::1girl::'), '单人女性');
      expect(
        zh.lookup('1.blue horn-shaped hair ornaments'),
        '蓝色角状发饰',
        reason: '分片里的长尾整句',
      );
    });

    test('画师 / 查不到 → null;没有分片的书只查 core', () {
      expect(zh.lookup('artist:ciloranko'), isNull);
      expect(zh.lookup('nonexistent tag'), isNull);
      expect(const CodexTagZh(core).lookup('very aesthetic'), '极具美感');
    });
  });

  group('codexIndexStamp', () {
    const a1 = CodexMeta(
      id: 'a',
      type: CodexType.codex,
      title: 'A',
      version: '2026.9.1',
    );
    const b1 = CodexMeta(
      id: 'b',
      type: CodexType.pack,
      title: 'B',
      version: '2026.9.2',
    );
    const b2 = CodexMeta(
      id: 'b',
      type: CodexType.pack,
      title: 'B',
      version: '2026.9.3',
    );

    test('与索引顺序无关;任何一部换版本都换戳', () {
      expect(codexIndexStamp([a1, b1]), codexIndexStamp([b1, a1]));
      expect(codexIndexStamp([a1, b1]), isNot(codexIndexStamp([a1, b2])));
      expect(codexIndexStamp([a1, b1]), matches(RegExp(r'^[0-9a-f]{12}$')));
    });
  });

  test('isolate 往返:compute 解析回完整的三组译名与分片清单', () async {
    final raw = jsonEncode({
      'schema': 1,
      'm': {'cowboy shot': '七分身（大腿以上）'},
      'd': {'1girl': '单人女性'},
      'a': {'year 2025': '2025 年'},
      'source': {'name': 'x', 'url': 'https://x.test', 'license': 'GPL-3.0'},
      'shards': ['suozhang'],
    });
    final s = (await compute(tagZhParsePayload, raw))!;
    expect(s.m['cowboy shot'], '七分身（大腿以上）');
    expect(s.d['1girl'], '单人女性');
    expect(s.a['year 2025'], '2025 年');
    expect(s.shards, ['suozhang']);
  });

  group('PromptChips 的 preferredTrans', () {
    // 生造词,免得撞上别的用例往全局反查缓存里灌的译名
    const covered = 'zzq codex covered tag';
    const missing = 'zzq codex missing tag';
    const tables = CodexTagZh(TagZhShard(d: {covered: '对照表译名'}));

    Future<List<List<String>>> pumpChips(
      WidgetTester tester, {
      required bool loading,
    }) async {
      final asked = <List<String>>[];
      final svc = TagTranslationService(
        enabled: true,
        baseUrl: 'https://x.test',
        client: MockClient((req) async {
          asked.add([
            for (final t in jsonDecode(req.body)['tags'] as List) '$t',
          ]);
          return http.Response(jsonEncode({'translations': {}}), 200);
        }),
      );
      addTearDown(svc.dispose);
      Widget chips(bool loading) => ProviderScope(
        overrides: [tagTranslationServiceProvider.overrideWithValue(svc)],
        child: MaterialApp(
          home: Scaffold(
            body: PromptChips(
              sections: const [(label: null, body: '$covered, $missing')],
              preferredTrans: loading ? null : tables.lookup,
              preferredTransLoading: loading,
            ),
          ),
        ),
      );
      await tester.pumpWidget(chips(loading));
      await tester.pump(const Duration(seconds: 1)); // 过防抖(700ms)
      if (loading) {
        expect(asked, isEmpty, reason: '对照表在路上时先不问后端');
        await tester.pumpWidget(chips(false)); // 表到了
        await tester.pump(const Duration(seconds: 1));
      }
      return asked;
    }

    testWidgets('对照表有的直接显示,只把表里没有的交给后端', (tester) async {
      final asked = await pumpChips(tester, loading: false);
      expect(find.text('对照表译名'), findsOneWidget);
      expect(asked, [
        [missing],
      ]);
    });

    testWidgets('表在路上不问后端,到货后只问剩下的', (tester) async {
      final asked = await pumpChips(tester, loading: true);
      expect(find.text('对照表译名'), findsOneWidget);
      expect(asked, [
        [missing],
      ]);
    });
  });
}
