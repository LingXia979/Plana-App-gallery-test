import 'package:flutter/material.dart';

import '../../../core/net/remote_image.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/ui/fade_in_once.dart';
import 'codex_models.dart';

/// 法典的共用卡片与图片渐显。
///
/// 单独成文件是为了**断开 import 环**:浏览器(codex_view)与弹层(codex_sheets)
/// 都要用它,而两者本来就是单向依赖(view → sheets)。把共用件留在任一侧,
/// 另一侧反过来 import 就成了环。

/// 网络图渐显:与灵感页画师/角色卡同款——帧到达前透明,到达后淡入。
Widget codexFadeIn(
  BuildContext context,
  Widget child,
  int? frame,
  bool wasSync,
) {
  if (wasSync) return child;
  return AnimatedOpacity(
    opacity: frame == null ? 0 : 1,
    duration: Motion.medium,
    curve: Curves.easeOut,
    child: child,
  );
}

/// 瀑布流卡:例图(cover)+ 底部渐变标题;无图退成配色块 + 居中标题。
/// 收藏夹也用它(那边给 [fixedAspect] 走等比网格,不做瀑布流)。
class CodexCard extends StatelessWidget {
  const CodexCard({
    super.key,
    required this.codex,
    required this.entry,
    required this.media,
    required this.onTap,
    this.fixedAspect,
    this.decodeWidth,
  });

  final CodexMeta codex;
  final CodexEntry entry;
  final CodexMedia media;
  final VoidCallback onTap;

  /// 覆盖词条自身比例(等比网格用);null = 按词条比例(瀑布流)。
  final double? fixedAspect;

  /// 例图的解码宽(逻辑像素);null = 按布局宽。能换列数的网格按落定的列宽给,
  /// 换档过渡途中不变 —— 按实时格宽解码的话,那几百毫秒里每一帧都是一路新解码。
  final double? decodeWidth;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    // 捏到三四列以后卡片很窄:标题收成一行、小一号,不然两行字的渐变条能把
    // 横图整张盖住。按宽度判,同一屏卡片的字号一致。
    builder: (context, c) => _card(context, compact: c.maxWidth < 130),
  );

  Widget _card(BuildContext context, {required bool compact}) {
    final scheme = context.scheme;
    final url = codexImageUrl(codex, entry, media);
    final aspect = fixedAspect ?? (entry.aspect <= 0 ? 0.75 : entry.aspect);
    return Material(
      color: scheme.surfaceContainer,
      clipBehavior: Clip.antiAlias,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        child: Stack(
          children: [
            AspectRatio(
              aspectRatio: aspect,
              child: url == null
                  ? _placeholder(context)
                  : FadeInOnce(
                      source: url,
                      builder: (_, frame) => RemoteImage(
                        url,
                        fit: BoxFit.cover,
                        decodeWidth: decodeWidth,
                        gaplessPlayback: true,
                        frameBuilder: frame,
                        errorBuilder: (_, _, _) => _placeholder(context),
                      ),
                    ),
            ),
            if (url != null)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  padding: compact
                      ? const EdgeInsets.fromLTRB(8, 12, 8, 6)
                      : const EdgeInsets.fromLTRB(10, 16, 10, 8),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Colors.black.withValues(alpha: .66),
                      ],
                    ),
                  ),
                  child: Text(
                    entry.title,
                    maxLines: compact ? 1 : 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: compact ? 11.5 : 12.5,
                      height: 1.25,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            if (entry.isNew)
              Positioned(
                left: 7,
                top: 7,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 1.5,
                  ),
                  decoration: BoxDecoration(
                    color: scheme.tertiary,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    'NEW',
                    style: context.texts.labelSmall!.copyWith(
                      color: scheme.onTertiary,
                      fontWeight: FontWeight.w800,
                      fontSize: 9,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _placeholder(BuildContext context) {
    final scheme = context.scheme;
    return ColoredBox(
      color: scheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Center(
          child: Text(
            entry.title,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: context.texts.bodySmall!.copyWith(
              color: scheme.onSecondaryContainer,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}
