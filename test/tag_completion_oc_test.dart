// 补全里的 OC 两处来源:本机灵感库的角色条目(底行「本地库」)排在前面,
// 公共库的接在后面(底行写作者昵称,查不到昵称写归属 id,连归属都没有写「公共库」)。
// 公共库里本地已经有的那份(收藏 / 发布的副本,或同名)只出本地的。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:plana_app/features/editor/data/artist_oc_library.dart';
import 'package:plana_app/features/editor/data/completion_source.dart';
import 'package:plana_app/features/editor/data/local_tag_db.dart';
import 'package:plana_app/features/editor/data/tag_completion.dart';
import 'package:plana_app/features/inspiration/tag_models.dart';

const _base = 'http://backend.test';

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

final _client = MockClient((req) async {
  switch (req.url.path) {
    case '/api/oc/list':
      return _json({
        'ocs': [
          // 本地那份是从这条收藏来的(publicId 对得上)
          {
            'en_name': 'oc_xueli',
            'zh_name': '雪莉',
            'tag_group': 'public copy',
            'owner_id': '10001',
          },
          {
            'en_name': 'oc_xuetu',
            'zh_name': '雪兔',
            'tag_group': 'rabbit',
            'owner_id': '10001',
          },
          // 老数据:没有 owner_id,归属在 created_by,目录里也没有昵称
          {
            'en_name': 'oc_xuemei',
            'zh_name': '雪梅',
            'tag_group': 'plum',
            'created_by': '10002',
          },
          {'en_name': 'oc_xuehua', 'zh_name': '雪花', 'tag_group': 'flake'},
          // 和本地一个 OC 同名
          {
            'en_name': 'oc_dongxue',
            'zh_name': '冬雪',
            'tag_group': 'winter',
            'owner_id': '10001',
          },
        ],
      });
    case '/api/public/authors':
      return _json({
        'authors': [
          {'user_id': '10001', 'nickname': '小明'},
          {'user_id': '10002', 'nickname': null},
        ],
      });
    case '/api/artists/list':
      return _json({'artists': []});
    case '/api/tags/search':
      return _json({'results': []});
  }
  return http.Response('{}', 404);
});

TagEntry _oc(String id, String name, String positive, {String? publicId}) =>
    TagEntry(
      id: id,
      category: TagCategory.character,
      name: name,
      positive: positive,
      publicId: publicId,
      origin: publicId == null ? TagOrigin.local : TagOrigin.favorited,
    );

final _local = [
  _oc('character_1', '雪莉', 'local copy', publicId: 'oc_xueli'),
  _oc('character_2', '初雪', 'first snow'),
  _oc('character_3', '冬雪', 'my winter'),
  _oc('character_4', '晴天', 'sunny'),
];

TagCompletion _completion({String? session}) => TagCompletion(
  source: CompletionSource.enhanced,
  baseUrl: _base,
  localDb: LocalTagDb(),
  artistOcLib: ArtistOcLibrary(_base, session, _client),
  localOcs: Future.value(_local),
  client: _client,
);

void main() {
  test('本地库排前、底行写「本地库」;公共库底行写作者', () async {
    final ocs = (await _completion(session: 'sid').query('雪')).ocs;
    expect(ocs.map((s) => s.text), ['雪莉', '初雪', '冬雪', '雪兔', '雪梅', '雪花']);
    expect(ocs.map((s) => s.source), [
      '本地库',
      '本地库',
      '本地库',
      '小明',
      '10002',
      '公共库',
    ]);
    expect(ocs.map((s) => s.local), [true, true, true, false, false, false]);
  });

  test('公共库里本地已有的(publicId 或同名)只出本地那份', () async {
    final ocs = (await _completion(session: 'sid').query('雪')).ocs;
    expect(ocs.singleWhere((s) => s.text == '雪莉').insertText, 'local copy');
    expect(ocs.singleWhere((s) => s.text == '冬雪').insertText, 'my winter');
  });

  test('没登录拿不到公共库,本地库照样补', () async {
    final ocs = (await _completion().query('雪')).ocs;
    expect(ocs.map((s) => s.text), ['雪莉', '初雪', '冬雪']);
  });
}
