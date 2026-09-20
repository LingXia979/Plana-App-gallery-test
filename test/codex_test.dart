import 'package:flutter/foundation.dart' show compute;
import 'package:flutter_test/flutter_test.dart';

import 'package:plana_app/features/inspiration/codex/codex_models.dart';
import 'package:plana_app/features/inspiration/codex/codex_service.dart';

/// 法典只读接入:URL 构造(默认图床 vs relative 外部源)、版本号、编码、
/// nsfw 门控标记、索引↔JSON 元信息合并 —— 拼错就整片裂图/漏门,全钉死。
void main() {
  const media =
      CodexMedia.fallback; // assets.quicktagcloud.com / images / originals

  group('图片 URL — 默认模式(图床/images/法典id/文件名)', () {
    const meta = CodexMeta(
      id: 'composition_style',
      type: CodexType.string,
      title: '构图风格',
    );
    const e = CodexEntry(
      id: 'composition_style_0001',
      title: '运河小船上的静谧时刻',
      tags: 'sitting in a small wooden boat',
      image: 'composition_style_0001.jpg',
      original: 'composition_style_0001.png',
      assetRev: 'e1d9fa43f9a6d14e',
    );

    test('封面 URL = 图床 + images/法典id/文件名 + ?v=rev', () {
      expect(
        codexImageUrl(meta, e, media),
        'https://assets.quicktagcloud.com/images/composition_style/'
        'composition_style_0001.jpg?v=e1d9fa43f9a6d14e',
      );
    });

    test('原图走 originals 前缀', () {
      expect(
        codexImageUrl(meta, e, media, original: true),
        'https://assets.quicktagcloud.com/originals/composition_style/'
        'composition_style_0001.png?v=e1d9fa43f9a6d14e',
      );
    });

    test('无 assetRev 时不挂 ?v=', () {
      const e2 = CodexEntry(id: 'x', title: 'x', tags: 'x', image: 'x.jpg');
      expect(
        codexImageUrl(meta, e2, media),
        'https://assets.quicktagcloud.com/images/composition_style/x.jpg',
      );
    });

    test('无图返回 null', () {
      const e2 = CodexEntry(id: 'x', title: 'x', tags: 'x');
      expect(codexImageUrl(meta, e2, media), isNull);
      expect(e2.hasImage, isFalse);
    });
  });

  group('图片 URL — relative 模式(每部自带 assetBaseUrl)', () {
    const meta = CodexMeta(
      id: 'mengshen_r18',
      type: CodexType.codex,
      title: '梦神R18',
      nsfw: true,
      assetBaseUrl: 'https://prompt-vault-gallery.pages.dev',
      assetPathMode: 'relative',
    );

    test('图路径直接挂 assetBaseUrl(不插 images/法典id)', () {
      const e = CodexEntry(
        id: 'v1',
        title: 't',
        tags: 't',
        image: 'images/foo/bar.webp',
        assetRev: 'abc',
      );
      expect(
        codexImageUrl(meta, e, media),
        'https://prompt-vault-gallery.pages.dev/images/foo/bar.webp?v=abc',
      );
    });

    test('relative 模式下路径分段编码但保留 /', () {
      const e = CodexEntry(
        id: 'v2',
        title: 't',
        tags: 't',
        image: 'img/带 空格/名字.jpg',
      );
      final u = codexImageUrl(meta, e, media)!;
      expect(
        u.startsWith('https://prompt-vault-gallery.pages.dev/img/'),
        isTrue,
      );
      expect(u.contains('%20'), isTrue); // 空格被编码
      expect(u.split('/').length, greaterThan(4)); // 斜杠结构保留
    });
  });

  test('绝对 URL 的图原样直传(只补 ?v=)', () {
    const meta = CodexMeta(id: 'x', type: CodexType.codex, title: 'x');
    const e = CodexEntry(
      id: 'e',
      title: 't',
      tags: 't',
      image: 'https://cdn.example.com/a.png',
      assetRev: 'r1',
    );
    expect(codexImageUrl(meta, e, media), 'https://cdn.example.com/a.png?v=r1');
  });

  test('默认模式:含 CJK/空格的 id 与文件名被编码', () {
    const meta = CodexMeta(id: '构图 x', type: CodexType.codex, title: 't');
    const e = CodexEntry(id: 'e', title: 't', tags: 't', image: 'a b.jpg');
    final u = codexImageUrl(meta, e, media)!;
    // 图床 + images/ + 编码(构图 x)/ + 编码(a b.jpg)
    expect(u.startsWith('https://assets.quicktagcloud.com/images/'), isTrue);
    expect(u.contains('%20'), isTrue);
    expect(u.contains(' '), isFalse);
  });

  group('解析', () {
    test('CodexMeta.fromJson:nsfw / 贡献者 / dataUrl / aliases', () {
      final m = CodexMeta.fromJson({
        'id': 'suozhang_r18',
        'type': 'codex',
        'title': '所长R18',
        'version': '2026.7.15',
        'author': '戒红所',
        'entryCount': 11084,
        'nsfw': true,
        'aliases': ['a1', 'a2'],
        'contributors': [
          {'name': '戒红所', 'role': '原作者'},
        ],
      });
      expect(m.id, 'suozhang_r18');
      expect(m.type, CodexType.codex);
      expect(m.nsfw, isTrue);
      expect(m.entryCount, 11084);
      expect(m.aliases, ['a1', 'a2']);
      expect(m.contributors.single.name, '戒红所');
    });

    test('类型:composition 认作「构图」,不认识的不给角标', () {
      expect(CodexType.parse('composition'), CodexType.composition);
      expect(CodexType.composition.label, '构图');
      expect(CodexType.parse('whatever'), CodexType.unknown);
      expect(CodexType.unknown.label, isEmpty);
    });

    test('CodexEntry.fromJson:tags / path / images / rev / isNew', () {
      final e = CodexEntry.fromJson({
        'id': 'c_0001',
        'title': '标题',
        'tags': '1.3::a::, b',
        'path': ['构图风格'],
        'image': 'c_0001.jpg',
        'imageWidth': 901,
        'imageHeight': 616,
        'assetRev': 'rev1',
        'isNew': true,
        'images': [
          {'path': 'c_0001.jpg', 'original': 'c_0001.png'},
        ],
      });
      expect(e.tags, '1.3::a::, b');
      expect(e.path, ['构图风格']);
      expect(e.image, 'c_0001.jpg');
      expect(e.aspect, closeTo(901 / 616, 1e-9));
      expect(e.isNew, isTrue);
      expect(e.images.single.original, 'c_0001.png');
    });

    test('无尺寸时给竖图默认 aspect(不塌成 0 高)', () {
      const e = CodexEntry(id: 'x', title: 't', tags: 't', image: 'a.jpg');
      expect(e.aspect, greaterThan(0));
    });
  });

  group('CodexData.parse 与索引合并', () {
    test('顶层 dict:entries / tree 解析,topCategories 取 tree 顶层', () {
      final d = CodexData.parse({
        'id': 'composition_style',
        'type': 'string',
        'title': '构图风格',
        'tree': [
          {'name': '构图风格', 'count': 64, 'children': []},
        ],
        'entries': [
          {
            'id': 'e1',
            'title': 't1',
            'tags': 'a',
            'path': ['构图风格'],
          },
          {
            'id': 'e2',
            'title': 't2',
            'tags': 'b',
            'path': ['构图风格'],
          },
        ],
      });
      expect(d.entries, hasLength(2));
      expect(d.topCategories, ['构图风格']);
    });

    test('层级筛选:前缀匹配,选父级含所有子级', () {
      // 词条 path 是完整层级(实测 suozhang:["OC杂项","单机角色"] 等)
      const oc1 = ['OC杂项', '单机角色'];
      const oc2 = ['OC杂项', '网络角色'];
      const other = ['各种风格'];
      // 空 = 全部
      expect(codexPathUnder(oc1, const []), isTrue);
      // 选父级「OC杂项」→ 两个子级都命中,别的不中
      expect(codexPathUnder(oc1, const ['OC杂项']), isTrue);
      expect(codexPathUnder(oc2, const ['OC杂项']), isTrue);
      expect(codexPathUnder(other, const ['OC杂项']), isFalse);
      // 选到叶子「OC杂项/单机角色」→ 只中它
      expect(codexPathUnder(oc1, const ['OC杂项', '单机角色']), isTrue);
      expect(codexPathUnder(oc2, const ['OC杂项', '单机角色']), isFalse);
      // 选中路径比词条还深 → 不中
      expect(codexPathUnder(const ['OC杂项'], const ['OC杂项', '单机角色']), isFalse);
    });

    test('effectiveTree:无 tree 时从词条 path 首级合成扁平树(带计数)', () {
      final d = CodexData.parse({
        'id': 'x',
        'type': 'codex',
        'title': 'x',
        'entries': [
          {
            'id': 'e1',
            'title': 't',
            'tags': 'a',
            'path': ['甲', '子'],
          },
          {
            'id': 'e2',
            'title': 't',
            'tags': 'b',
            'path': ['甲', '丑'],
          },
          {
            'id': 'e3',
            'title': 't',
            'tags': 'c',
            'path': ['乙'],
          },
        ],
      });
      final t = d.effectiveTree;
      expect(t.map((n) => n.name), ['甲', '乙']);
      expect(t.firstWhere((n) => n.name == '甲').count, 2);
    });

    test('tree 缺失时 topCategories 从词条 path 首级兜底', () {
      final d = CodexData.parse({
        'id': 'x',
        'type': 'codex',
        'title': 'x',
        'entries': [
          {
            'id': 'e1',
            'title': 't',
            'tags': 'a',
            'path': ['甲', '子'],
          },
          {
            'id': 'e2',
            'title': 't',
            'tags': 'b',
            'path': ['乙'],
          },
        ],
      });
      expect(d.topCategories, ['甲', '乙']);
    });

    test('外部源 JSON 缺 nsfw/assetBaseUrl:以索引 meta 兜底,门控与出图不失守', () {
      const idx = CodexMeta(
        id: 'mengshen_r18',
        type: CodexType.codex,
        title: '梦神R18',
        nsfw: true,
        assetBaseUrl: 'https://prompt-vault-gallery.pages.dev',
        assetPathMode: 'relative',
      );
      // 外部数据源的 JSON 只有 entries,没有门控/图床字段
      final d = CodexData.parse({
        'entries': [
          {'id': 'e1', 'title': 't', 'tags': 'a', 'image': 'p/q.webp'},
        ],
      }, indexMeta: idx);
      expect(d.meta.nsfw, isTrue, reason: 'nsfw 不能被外部 JSON 覆没');
      expect(d.meta.isRelativeAssets, isTrue);
      // 出图仍走 relative + assetBaseUrl
      expect(
        codexImageUrl(d.meta, d.entries.single, media),
        'https://prompt-vault-gallery.pages.dev/p/q.webp',
      );
    });
  });

  test('media fallback 常量与原站现值一致', () {
    expect(CodexMedia.fallback.baseUrl, 'https://assets.quicktagcloud.com');
    expect(CodexMedia.fallback.imagePrefix, 'images');
    expect(CodexMedia.fallback.originalPrefix, 'originals');
  });

  // compute 真跑一次 isolate:确认 CodexData(含 record 的贡献者/链接、词条列表)
  // 能跨 isolate 边界无损传回 —— 大 JSON 的 fetchCodex 全靠这条路。
  test('isolate 往返:codexParsePayload 经 compute 返回完整 CodexData', () async {
    const raw =
        '{"id":"t","type":"codex","title":"样本","version":"1",'
        '"contributors":[{"name":"甲","role":"作者"}],'
        '"tree":[{"name":"分区","count":1,"children":[]}],'
        '"entries":[{"id":"e1","title":"标题","tags":"1.3::a::, b",'
        '"path":["分区"],"image":"e1.jpg","assetRev":"r1"}]}';
    final idx = {'id': 't', 'type': 'codex', 'title': '样本', 'nsfw': true};

    final d = await compute(codexParsePayload, <Object?>[raw, idx]);

    expect(d.entries, hasLength(1));
    expect(d.entries.single.title, '标题');
    expect(d.entries.single.tags, '1.3::a::, b');
    expect(d.topCategories, ['分区']);
    expect(d.meta.contributors.single.name, '甲'); // record 往返无损
    expect(d.meta.nsfw, isTrue); // 索引 meta 合并生效
    expect(
      codexImageUrl(d.meta, d.entries.single, CodexMedia.fallback),
      'https://assets.quicktagcloud.com/images/t/e1.jpg?v=r1',
    );
  });
}
