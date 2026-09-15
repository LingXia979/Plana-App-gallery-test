import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/util/prompt_tokens.dart';
import 'package:plana_app/features/editor/data/tag_index.dart';

/// 离线词库索引:进包的文件与 TSV 同步,读取端与建库口径逐键一致。
void main() {
  final spec = TagIndexSpec.fromTsv(File(kTagTsv).readAsStringSync());
  final built = spec.encode();
  final idx = TagIndex(ByteData.sublistView(built));

  test('进包的索引与 TSV 同步', () {
    final shipped = File(kTagIndexAsset).readAsBytesSync();
    var same = shipped.length == built.length;
    for (var i = 0; same && i < built.length; i++) {
      same = shipped[i] == built[i];
    }
    expect(
      same,
      isTrue,
      reason: '改了 TSV 或建库口径要重跑 dart run tool/build_tag_index.dart',
    );
  });

  test('注音 / 帖子数 / 角色三张表逐键一致,查不到的回空', () {
    final bad = <String>[];
    void check(String what, Object? got, Object? want) {
      if (got != want && bad.length < 20) bad.add('$what: $got ≠ $want');
    }

    final keys = {
      ...spec.metaRow.keys,
      ...spec.postRow.keys,
      ...spec.charRow.keys,
    };
    for (final k in keys) {
      final meta = spec.metaRow[k];
      check('trans $k', idx.transOf(k), spec.transOf(k));
      check(
        'count $k',
        idx.countOf(k),
        meta == null ? null : spec.rows[meta].count,
      );
      final post = spec.postRow[k];
      check(
        'post $k',
        idx.postCountOf(k),
        post == null ? 0 : spec.rows[post].count,
      );
      final char = spec.charRow[k];
      final hit = idx.charactersIn({k});
      check(
        'char $k',
        hit.map((e) => e.tag).join(),
        char == null ? '' : spec.rows[char].tag,
      );
      if (char != null && hit.isNotEmpty) {
        check('char zh $k', hit.single.zh, spec.rows[char].zh);
        check('char count $k', hit.single.count, spec.rows[char].count);
      }
      final miss = '$k|无此键|';
      check('miss $k', idx.transOf(miss) ?? idx.countOf(miss), null);
    }
    expect(bad, isEmpty);
  });

  test('帖子数与角色的口径跟着分词走', () {
    final toks = tokenizeSet(
      '1.2::long_hair::, {{hires}}, Ganyu_(Genshin_Impact), 独一无二的描述',
    );
    expect(idx.postCountOf('long hair'), greaterThan(100000));
    expect(
      idx.postCountOf('hires'),
      idx.postCountOf('highres'),
      reason: '别名记正名的帖子数',
    );
    expect(idx.postCountOf('独一无二的描述'), 0);
    expect(idx.postCountOf(''), 0);
    expect(idx.charactersIn(toks).map((e) => e.tag), [
      'ganyu_(genshin_impact)',
    ]);
  });

  test('补全与逐行扫描的结果一致', () {
    // 对照:按行的字符串版本(旧实现同一段逻辑)
    List<String> scan(String query, int limit) {
      final q = query.trim().toLowerCase().replaceAll(' ', '_');
      if (q.length < 2) return const [];
      final primary = <TagRow>[];
      final secondary = <TagRow>[];
      final seen = <String>{};
      for (final e in spec.rows) {
        if (e.tag.startsWith(q)) {
          if (seen.add(e.tag)) primary.add(e);
          if (primary.length >= limit) break;
        } else if (secondary.length < limit &&
            e.aliases.any((a) => a.startsWith(q))) {
          if (seen.add(e.tag)) secondary.add(e);
        }
      }
      return [
        for (final e in [...primary, ...secondary].take(limit))
          '${e.tag.replaceAll('_', ' ')}|${e.zh}|${e.count}',
      ];
    }

    final queries = <String>{
      'hires',
      'longhair',
      'oppai',
      'Long H',
      'a',
      'qx',
      ' Blue ',
    };
    for (final r in spec.rows.take(200)) {
      queries.add(r.tag.length > 3 ? r.tag.substring(0, 3) : r.tag);
    }
    for (final r in spec.rows.skip(20000).take(40)) {
      if (r.aliases.isNotEmpty && r.aliases.first.length >= 3) {
        queries.add(r.aliases.first.substring(0, 3));
      }
    }
    for (final q in queries) {
      final got = [
        for (final s in idx.search(q, limit: 12))
          '${s.text}|${s.trans}|${s.count}',
      ];
      expect(got, scan(q, 12), reason: q);
    }
  });
}
