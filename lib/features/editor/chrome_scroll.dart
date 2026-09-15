import 'package:flutter/widgets.dart';

/// 正文滚动 → 顶栏与权重面板该收还是该放(浏览器地址栏同款):往下翻收起;
/// 往回翻、翻回顶上、或在顶上继续往下拽,放出来。
///
/// 纯判定,不碰界面:页面把正文的 [ScrollNotification] 喂给 [update],拿回
/// 新状态(null = 不变),自己去收放。单独拎出来是为了能脱离整页单测 —— 这里
/// 的坑全是「收起那一下视口变高、位置被夹回」这种只有真滚起来才碰得到的。
///
/// 正文的滚动视图要配 [AlwaysScrollableScrollPhysics]:收起之后正文可能一屏
/// 就放得下,那时滚动视图不再接拖动,「顶上往下拽」这条放出的路就断了。
class ChromeScrollTracker {
  ChromeScrollTracker({this.hideAfter = 16, this.showAfter = 28});

  /// 同一方向上连续拖多远才收 / 才放。放比收多要一截:往下翻的途中手指
  /// 稍微回一下,不该让两块东西闪出来。
  final double hideAfter;
  final double showAfter;

  /// 本次手势里同向连续拖动的累计位移(带符号,正 = 往下翻)。
  double _run = 0;

  /// [hidden] 是眼下收着没有。
  bool? update(ScrollNotification n, {required bool hidden}) {
    // 只认正文自己那一层:芯片输入框、文本框内部的滚动都在更深处
    if (n.depth != 0 || n.metrics.axis != Axis.vertical) return null;
    final m = n.metrics;
    final atTop = m.pixels <= m.minScrollExtent;
    switch (n) {
      case ScrollStartNotification():
        _run = 0; // 每次起手重攒,不沿用上一把
      case OverscrollNotification(:final overscroll, :final dragDetails):
        // 已经在顶上还往下拽:没有「往回翻」的距离可攒了,直接放
        if (hidden && dragDetails != null && overscroll < 0) return false;
      case ScrollUpdateNotification(:final scrollDelta, :final dragDetails):
        if (dragDetails == null) {
          // 惯性 / 回弹:只有往回甩、一路甩到顶才放。往下翻收起后视口变高,
          // 越界的位置会被弹回去,弹到顶也算「到顶」—— 可那时攒的是往下翻,
          // 这时候放出来就是收起 → 弹回顶 → 又放出,来回闪。
          if (hidden && atTop && _run < 0) return false;
          return null;
        }
        final d = scrollDelta ?? 0;
        if (d == 0) return null;
        if ((d > 0) != (_run > 0)) _run = 0; // 换向重攒
        _run += d;
        if (!hidden && _run >= hideAfter) return true;
        if (hidden && (_run <= -showAfter || atTop)) return false;
    }
    return null;
  }
}
