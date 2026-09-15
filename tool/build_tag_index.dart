/// 由 `assets/danbooru.tsv` 生成进包的离线词库索引(格式与口径见
/// lib/features/editor/data/tag_index.dart)。
///
///     dart run tool/build_tag_index.dart
///
/// 改了 TSV 或建库口径后重跑;`test/tag_index_test.dart` 会校验进包的文件是否同步。
library;

import 'dart:io';

import 'package:plana_app/features/editor/data/tag_index.dart';

void main() {
  final spec = TagIndexSpec.fromTsv(File(kTagTsv).readAsStringSync());
  final bytes = spec.encode();
  File(kTagIndexAsset).writeAsBytesSync(bytes);
  stdout.writeln(
    '$kTagIndexAsset  ${(bytes.length / 1e6).toStringAsFixed(2)} MB  '
    '${spec.rows.length} 行 · 注音键 ${spec.metaRow.length} · '
    '帖子数键 ${spec.postRow.length} · 角色键 ${spec.charRow.length}',
  );
}
