/// 二级页的转场:左右滑动。点进来从右边滑入,返回往右滑出,底下那页带一点视差。
///
/// 为什么不用 Flutter 在安卓上的默认转场:那套是预测性返回,拖动时整页缩小,松手之后
/// 页面**直接消失**,和点进来时的动画接不上,用起来很怪。
///
/// 滑动本身复用 [CupertinoPageTransition](横向滑入 + 视差 + 边缘阴影),但**不跟手**:
///   · 不接系统的预测性返回事件 —— 返回手势松手确认后才开始往右滑出,拖动过程中页面不动;
///   · 也不用 iOS 那个左缘拖动识别器([CupertinoPageTransitionsBuilder] 自带的那个)——
///     安卓全面屏手势本来就占着屏幕边缘,两个一起开会抢手势。
library;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Durations;

class SlideBackPageTransitionsBuilder extends PageTransitionsBuilder {
  const SlideBackPageTransitionsBuilder();

  // 进场稍慢、离场稍快,与原先 shared-axis 那版同一个节奏(Motion.slow / medium)。
  // 直接写 Durations 而不引 app_theme:主题要引这个文件,反过来引会绕成环。
  @override
  Duration get transitionDuration => Durations.medium4;

  @override
  Duration get reverseTransitionDuration => Durations.medium2;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return CupertinoPageTransition(
      primaryRouteAnimation: animation,
      secondaryRouteAnimation: secondaryAnimation,
      linearTransition: false,
      child: child,
    );
  }
}
