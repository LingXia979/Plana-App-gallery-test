/// 结果条上那颗 `+7 −2` 读数,以及差异用的两支固定色。
///
/// **条上不逐条列 tag**。试过三版:双行芯片、一行一条的 IDE 行版、单行芯片
/// 压成两行 —— 最后一版一行也就摆得下两三颗,而「+7 −2」已经把「改了多少」
/// 说全了,剩下两三个 tag 名字既凑不成完整认知、又占掉一大块。明细一律走弹层
/// (见 `proposal_sheet.dart`),那儿高度管够、用的是全 app 的标准芯片。
library;

import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';

/// 差异的红绿**不跟随主题种子色**。
///
/// 「+ 是绿、− 是红」是跨工具的既成约定,用 `scheme.primary` 的话换个种子色
/// 新增就变成粉的或棕的,读者得重新学一遍。这与 [FixedSemantic] 的立意一致
/// (语义必须固定的那几处),所以直接借它那两支。
///
/// 弹层那边的组标题也用这两支 —— 同一件事在两处必须同色。
const diffAddColor = FixedSemantic.ok;
const diffDelColor = FixedSemantic.danger;

/// 头部那颗 `+7 −2` 读数。比「加 7 删 2」省一半宽度,而且和下面每颗芯片同色。
class DiffCount extends StatelessWidget {
  const DiffCount({super.key, required this.added, required this.removed});

  final int added;
  final int removed;

  @override
  Widget build(BuildContext context) {
    final style = context.texts.labelMedium!.copyWith(
      fontWeight: FontWeight.w700,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (added > 0)
          Text('+$added', style: style.copyWith(color: diffAddColor)),
        if (added > 0 && removed > 0) const SizedBox(width: 6),
        // 用真减号 U+2212 而不是连字符:与 `+` 等宽,两行读数不会一高一低。
        if (removed > 0)
          Text('−$removed', style: style.copyWith(color: diffDelColor)),
      ],
    );
  }
}
