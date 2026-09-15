/// 弹层、对话框、菜单、新页面关掉之后,别把焦点还给之前那个输入框。
///
/// Flutter 的默认行为是路由关掉之后恢复推它之前的焦点,于是「输入框点过(键盘收了
/// 焦点还在)→ 打开弹层 → 关掉」会把软键盘重新顶出来,而用户只是去弹层里看了一眼、
/// 点了个东西。以前是每个弹层后面各补一句 `dropFocusSoon()`,补不全:灵感页、法典、
/// 图库、Vibe 库、LoRA 管理这些带搜索框的页面全漏着。挂在 MaterialApp 上统一收掉。
///
/// 只管一种情况:**推路由的那一刻焦点正在某个输入框里**,关掉之后焦点又回到了同一个
/// 输入框 —— 这时把它放掉,键盘不弹。
///
/// 真要关掉弹层接着打字的地方不受影响,只要照编辑器的写法:推之前先收焦点,关掉之后
/// 自己再要回来 —— 推的时候焦点不在输入框里,这里不记,也就不碰。关掉之后要回的
/// 恰好是推之前那个输入框的,放到下一帧再要(见 AI 助手的「编辑该消息」)。
library;

import 'package:flutter/widgets.dart';

class InputFocusGuard extends NavigatorObserver {
  /// 每个路由推上来时正聚焦的输入框。弱引用挂在路由上,漏了 pop 也不攒。
  final _focusedAtPush = Expando<FocusNode>();

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    final node = FocusManager.instance.primaryFocus;
    if (node != null && _isTextInput(node)) _focusedAtPush[route] = node;
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _settle(route);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _settle(route);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (oldRoute != null) _focusedAtPush[oldRoute] = null;
  }

  void _settle(Route<dynamic> route) {
    final node = _focusedAtPush[route];
    if (node == null) return;
    _focusedAtPush[route] = null;
    // 焦点是在关路由的收尾里还回去的,当帧还没回来:下一帧看它是不是回到了那个输入框
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (FocusManager.instance.primaryFocus == node) node.unfocus();
    });
  }

  static bool _isTextInput(FocusNode node) =>
      node.context?.findAncestorStateOfType<EditableTextState>() != null;
}
