import 'dart:math' as math;

import 'package:flutter/gestures.dart'
    show GestureDisposition, OneSequenceGestureRecognizer;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'
    show SliverConstraints, SliverGridGeometry, SliverGridLayout;

import '../theme/app_theme.dart';
import '../util/haptics.dart';

/// 双指捏合换网格列数。页面 State 混入它之后做四件事:
///   1. 网格区域外面包一层 [pinchLayer];
///   2. 网格本身(以及一切按 [gridColumns] 算尺寸的东西)在 [pinchBuilder] 里建;
///   3. SliverGrid 的 gridDelegate 走 [zoomGridDelegate];
///   4. 这条列表的 physics 走 [pinchPhysics]。
///
/// **手势只负责触发,不负责驱动**:指间距过阈值就换一档,过渡自己跑完。全程跟手
/// 的版本(进度实时跟着指间距走)会把手指的微抖一分不差地变成网格几何,整片图跟着
/// 颤,死区、增益、低通三道一起上也压不干净 —— 换一档本来就是个离散决定,拿连续量
/// 去驱动它是自找的麻烦。
///
/// 过渡是网格几何的插值(见 [ZoomGridDelegate]):每一格从旧位置连续走到新位置,
/// 不是整片画面缩放再交叉淡化。
mixin PinchColumnsMixin<T extends StatefulWidget> on State<T>, TickerProvider {
  // ---- 由页面提供 ----

  /// 起始列数(一般读自偏好)。initState 里读一次;之后要换走 [jumpGridColumns]。
  int get initialGridColumns;

  int get minGridColumns;
  int get maxGridColumns;

  /// 换档时按焦点回正的那条列表。页里有好几条时给眼下看得见的那条。
  ScrollController? get pinchScrollController;

  /// 捏出新的一档时回调,值是目标列数。页面在这里落盘 —— 过渡一起步就写,
  /// 不等它跑完:半路关页、换走都不会把这一档丢了。
  void onGridColumnsChanged(int cols);

  // ---- 状态 ----

  /// 触发一档所需的指间距倍率。取对数看两个方向基本对称(±0.22)。
  static const _kZoomIn = 1.25; // 撑开到 1.25 倍 → 少一列
  static const _kZoomOut = .8; // 收拢到 0.8 倍 → 多一列

  late int _cols;

  /// 过渡中的目标列数;null = 没在过渡。
  int? _toCols;

  /// 起点 → 目标的进度 0..1,网格几何按它插值。只由 [_morph] 驱动。
  double _t = 0;

  late final AnimationController _morph;

  final _pointers = <int, Offset>{};
  double? _span0; // 基准指间距;每换一档就重取,于是可以一路捏下去

  // 锚定:把「触发那一刻焦点落在内容里的相对位置」钉住,否则列数一变内容总高
  // 跟着变,画面会整体上下漂。
  double _anchorOff = 0, _anchorContent = 0, _focalY = 0;
  bool _reanchorQueued = false;

  /// 网格该重建的时刻:进出捏合、过渡的每一帧、落定、程序换列数。只通知
  /// [pinchBuilder] 里那一块,见那里。
  final _gridPing = _Ping();

  /// 当前列数。过渡中是**起点**那一档 —— 要按列数算尺寸的旁路(比如图片解码宽)
  /// 跟它走,换档那几百毫秒里就不会每帧变一次。
  int get gridColumns => _cols;

  @override
  void initState() {
    super.initState();
    _cols = initialGridColumns.clamp(minGridColumns, maxGridColumns);
    _morph = AnimationController(vsync: this, duration: Motion.medium)
      ..addListener(_onMorphTick)
      ..addStatusListener(_onMorphStatus);
  }

  @override
  void dispose() {
    _morph.dispose();
    _gridPing.dispose();
    super.dispose();
  }

  /// 直接换到 [cols],不走过渡(比如换了个分类,各记各的列数)。
  void jumpGridColumns(int cols) {
    _morph.stop();
    _anchorContent = 0; // 排队中的回正作废:它量的是换走之前那份内容
    _cols = cols.clamp(minGridColumns, maxGridColumns);
    _toCols = null;
    _t = 0;
    _gridPing.ping();
  }

  /// 网格(以及一切按 [gridColumns] 算尺寸的东西)包在这里面建。捏合、过渡、
  /// 落定时只重建这一块。
  ///
  /// 不走整页 setState:页面 build 里常有整份列表的筛选与排序(灵感页画风按编号
  /// 自然序排,上千条就是几十毫秒;法典一本上万条),过渡期间每帧跑一遍就是一路
  /// 掉帧。
  Widget pinchBuilder(WidgetBuilder builder) => ListenableBuilder(
    listenable: _gridPing,
    builder: (context, _) => builder(context),
  );

  /// 网格几何的插值代理:没在两档之间就是当前列数的普通代理,不绕路。
  ///
  /// [of] 按列数造一份普通代理 —— 各页格子的尺寸算法不同,由调用方给。
  SliverGridDelegate zoomGridDelegate(
    SliverGridDelegate Function(int cols) of,
  ) {
    final to = _toCols;
    if (to == null || _t <= 0) return of(_cols);
    return ZoomGridDelegate(of, _cols, to, _t);
  }

  /// 双指按住、以及换档过渡跑完之前,列表换成冻结的物理(见 [_FrozenScrollPhysics]);
  /// 其余时候原样用 [normal]。
  ScrollPhysics? pinchPhysics([ScrollPhysics? normal]) =>
      _pointers.length >= 2 || _morph.isAnimating
      ? const _FrozenScrollPhysics()
      : normal;

  /// 捏合手势层,包在网格区域外面。一个 State 只挂一层。
  ///
  /// 判定走 Listener 旁听原始指针,不走 GestureDetector(onScale*):后者会把
  /// **单指**拖动也拉进竞技场,和列表自己的竖向滚动抢,滚动就废了。
  ///
  /// 竞技场里只垫一个 [_TwoFingerClaim]:第二根手指落下的那一刻把两根一起认领。
  /// 不认领的话,两指底下的卡片照常按点按 / 长按结算 —— 捏得轻、没挪出点按容差,
  /// 松手就成了点了一下;两指按住不动够久,还会在其中一张上弹出长按。
  ///
  /// 捏到一半这层被拆掉(比如搜索落地、结果变空,网格换成了空态)也不会把「两指
  /// 按住」卡死:手指移动、抬起按**按下时的命中路径**派发,拆掉的那层照样收得到。
  Widget pinchLayer({required Widget child}) => RawGestureDetector(
    gestures: {
      _TwoFingerClaim: GestureRecognizerFactoryWithHandlers<_TwoFingerClaim>(
        () => _TwoFingerClaim(debugOwner: this),
        (_) {},
      ),
    },
    child: Listener(
      onPointerDown: _pinchDown,
      onPointerMove: _pinchMove,
      onPointerUp: _pinchUp,
      onPointerCancel: _pinchUp,
      child: child,
    ),
  );

  double get _span {
    final p = _pointers.values.toList();
    return (p[0] - p[1]).distance;
  }

  Offset get _mid {
    final p = _pointers.values.toList();
    return (p[0] + p[1]) / 2;
  }

  void _pinchDown(PointerDownEvent e) {
    _pointers[e.pointer] = e.position;
    if (_pointers.length != 2) return;
    _span0 = _span;
    _gridPing.ping(); // 进入捏合:冻结滚动
  }

  void _pinchMove(PointerMoveEvent e) {
    if (!_pointers.containsKey(e.pointer)) return;
    _pointers[e.pointer] = e.position;
    final s0 = _span0;
    if (_pointers.length != 2 || s0 == null || s0 < 1) return;

    final r = _span / s0;
    if (r < _kZoomIn && r > _kZoomOut) return; // 没到阈值,什么都不做
    // 重取基准:再捏同样的幅度就是下一档。到头时也要重取,否则会一直卡在
    // 阈值以外,手指一抖就反复触发。
    _span0 = _span;

    // 撑开 = 图变大 = 列变少。从**目标**那一档起算:上一档还在过渡时接着捏,
    // 按起点算会原地踏步(算出来的正是目标),反着捏还会一步跨两档。
    final from = _toCols ?? _cols;
    final want = (r >= 1 ? from - 1 : from + 1).clamp(
      minGridColumns,
      maxGridColumns,
    );
    if (want == from) return; // 到头了
    _startMorph(want);
  }

  void _pinchUp(PointerEvent e) {
    final was = _pointers.length >= 2;
    _pointers.remove(e.pointer);
    if (!was) return;
    if (_pointers.length >= 2) {
      _span0 = _span; // 三指落回两指:重新取基准,免得拿旧间距算出一次误触发
      return;
    }
    _span0 = null;
    _gridPing.ping(); // 退出捏合:放开滚动(过渡还没跑完的话,等 _endMorph 放)
  }

  /// 起一次换档过渡。上一档还没跑完就先把它落定,再从新的一档起步 ——
  /// 一路捏下去时不会两段过渡叠在一起。
  void _startMorph(int to) {
    if (_morph.isAnimating) _endMorph();
    _takeAnchor();
    _toCols = to;
    _t = 0;
    Haptics.selection();
    onGridColumnsChanged(to);
    _morph.forward(from: 0); // 同步回调一次 _onMorphTick,由它通知网格
  }

  /// 过渡每一帧:推进插值进度并回正滚动位置。
  void _onMorphTick() {
    _t = Motion.emphasized.transform(_morph.value);
    _gridPing.ping();
    _reanchorAfterLayout();
  }

  void _onMorphStatus(AnimationStatus st) {
    if (st == AnimationStatus.completed) _endMorph();
  }

  /// 落定:目标列数坐实成当前列数。中途被新的一档打断时也走这里。
  void _endMorph() {
    final to = _toCols;
    if (to == null) return;
    _cols = to;
    _toCols = null;
    _t = 0;
    _gridPing.ping();
  }

  ScrollPosition? get _position {
    final c = pinchScrollController;
    // 同一个控制器挂着两份 position(比如骨架↔内容淡入淡出的那一下)时不碰
    if (c == null || !c.hasClients || c.positions.length != 1) return null;
    final p = c.position;
    return p.hasContentDimensions && p.hasViewportDimension ? p : null;
  }

  /// 记下锚点:触发那一刻焦点落在**内容**里的相对位置。
  void _takeAnchor() {
    final pos = _position;
    if (pos == null) {
      _anchorContent = 0;
      return;
    }
    // 焦点按列表视口自己的坐标量:视口上方要是还垫着别的东西,拿手势层的坐标会
    // 差出那一截。
    final box = pos.context.notificationContext?.findRenderObject();
    _focalY = box is RenderBox && box.hasSize && _pointers.length >= 2
        ? box.globalToLocal(_mid).dy
        : 0;
    _anchorOff = pos.pixels;
    _anchorContent = pos.maxScrollExtent + pos.viewportDimension;
  }

  /// 按锚点回正滚动位置。**必须在布局之后跑**(见下)。
  ///
  /// 列数一变内容总高就变,而 ScrollPosition 只认像素 —— 不回正的话,焦点上方
  /// 的内容长高/缩矮多少,画面就整体漂多少。这里保持**焦点在内容里的比例**不变。
  /// 内容总高取实测(`maxScrollExtent + viewportDimension`),不按列数推算:
  /// 带段头、分组的网格高度构成各不一样,推不准。
  ///
  /// ⚠ 放在指针事件 / 动画 tick 里算是**错的**,而且是会抖的那种错:那时拿到的
  /// 总高还是上一帧的(布局还没跟着新进度跑),按它算出的像素又会成为下一帧布局
  /// 的输入 —— 一来一回构成反馈环,整片网格每帧上下弹。放在帧后就没有环:总高与
  /// 当前进度对得上,跳完只改像素不改总高,下一次算出来就等于当前值,一帧收敛。
  void _reanchor() {
    final pos = _position;
    if (pos == null || _anchorContent <= 0) return;
    final content = pos.maxScrollExtent + pos.viewportDimension;
    if (content <= 0) return;
    final want = ((_anchorOff + _focalY) * content / _anchorContent - _focalY)
        .clamp(pos.minScrollExtent, pos.maxScrollExtent);
    if ((want - pos.pixels).abs() > 1.5) pos.jumpTo(want);
  }

  void _reanchorAfterLayout() {
    if (_reanchorQueued) return;
    _reanchorQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _reanchorQueued = false;
      if (mounted) _reanchor();
    });
  }
}

/// 两套网格几何之间的线性插值代理。
///
/// 这是「图片真的在挪窝」的全部实现:每一格的位置与尺寸,都从 [colsA] 列下的值
/// 连续走到 [colsB] 列下的值。整张画面缩放做不到这件事 —— 那样所有格子只是被
/// 一起放大,相对关系纹丝不动,而换列数恰恰是**相对关系**在变(第 4 张从第一行
/// 末尾挪到第二行开头)。
class ZoomGridDelegate extends SliverGridDelegate {
  const ZoomGridDelegate(this.of, this.colsA, this.colsB, this.t);

  /// 按列数造一份普通代理。
  final SliverGridDelegate Function(int cols) of;
  final int colsA, colsB;
  final double t;

  @override
  SliverGridLayout getLayout(SliverConstraints constraints) => _LerpGridLayout(
    of(colsA).getLayout(constraints),
    of(colsB).getLayout(constraints),
    t,
  );

  @override
  bool shouldRelayout(covariant ZoomGridDelegate old) =>
      old.t != t || old.colsA != colsA || old.colsB != colsB;
}

class _LerpGridLayout extends SliverGridLayout {
  const _LerpGridLayout(this.a, this.b, this.t);

  final SliverGridLayout a, b;
  final double t;

  double _l(double x, double y) => x + (y - x) * t;

  @override
  SliverGridGeometry getGeometryForChildIndex(int index) {
    final ga = a.getGeometryForChildIndex(index);
    final gb = b.getGeometryForChildIndex(index);
    return SliverGridGeometry(
      scrollOffset: _l(ga.scrollOffset, gb.scrollOffset),
      crossAxisOffset: _l(ga.crossAxisOffset, gb.crossAxisOffset),
      mainAxisExtent: _l(ga.mainAxisExtent, gb.mainAxisExtent),
      crossAxisExtent: _l(ga.crossAxisExtent, gb.crossAxisExtent),
    );
  }

  @override
  double computeMaxScrollOffset(int childCount) => _l(
    a.computeMaxScrollOffset(childCount),
    b.computeMaxScrollOffset(childCount),
  );

  // 可见区间取两套布局的**并集**:插值后的位置一定夹在两者之间,取并集才不会
  // 把边缘上那一两格漏建(漏了就是滚动到边界时凭空出现一块空白)。
  @override
  int getMinChildIndexForScrollOffset(double scrollOffset) => math.min(
    a.getMinChildIndexForScrollOffset(scrollOffset),
    b.getMinChildIndexForScrollOffset(scrollOffset),
  );

  @override
  int getMaxChildIndexForScrollOffset(double scrollOffset) => math.max(
    a.getMaxChildIndexForScrollOffset(scrollOffset),
    b.getMaxChildIndexForScrollOffset(scrollOffset),
  );
}

/// 捏合期间给列表用的滚动物理:**照常参与手势竞技场,但不产生位移**。
///
/// 为什么不用 `NeverScrollableScrollPhysics`:它的 `shouldAcceptUserOffset`
/// 返回 false,Scrollable 会把自己的拖动识别器撤掉 —— 竞技场里少了它,外层的
/// 拖动(弹层的下拉关闭之类)就赢了,捏一下整个浮窗被拽下去。捏合时既要列表别动,
/// 又要它继续占着这个手势不放,两件事得分开:accept 照给,位移给 0。
///
/// 顺带,不给弹道模拟 —— 否则松手那一下还会甩出一段惯性。
class _FrozenScrollPhysics extends ScrollPhysics {
  const _FrozenScrollPhysics({super.parent});

  @override
  _FrozenScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      _FrozenScrollPhysics(parent: buildParent(ancestor));

  /// 恒真:内容不足一屏时也要占住手势。
  @override
  bool shouldAcceptUserOffset(ScrollMetrics position) => true;

  @override
  double applyPhysicsToUserOffset(ScrollMetrics position, double offset) => 0;

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) => null;
}

/// 第二根手指落下即认领在场全部手指的识别器;只有一根手指时从不出手,
/// 单指的点按、滚动照旧。
///
/// 它不产出任何回调,捏合本身由 [PinchColumnsMixin.pinchLayer] 里的 Listener 判;
/// 它在竞技场里的用处只是把两指底下的点按、长按、列表拖动一并判负。
///
/// 先单指滚起来、再落第二指的情形它认领不到:第一根已经判给了列表的拖动,第二根
/// 落下时也会被那个拖动当场收走 —— 那时靠 [_FrozenScrollPhysics] 让列表不动。
class _TwoFingerClaim extends OneSequenceGestureRecognizer {
  _TwoFingerClaim({super.debugOwner});

  final _down = <int>{};

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    _down.add(event.pointer);
    if (_down.length >= 2) resolve(GestureDisposition.accepted);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      _release(event.pointer);
    }
  }

  @override
  void rejectGesture(int pointer) => _release(pointer);

  void _release(int pointer) {
    _down.remove(pointer);
    stopTrackingPointer(pointer);
  }

  @override
  void didStopTrackingLastPointer(int pointer) {}

  @override
  String get debugDescription => 'two-finger claim';
}

class _Ping extends ChangeNotifier {
  void ping() => notifyListeners();
}
