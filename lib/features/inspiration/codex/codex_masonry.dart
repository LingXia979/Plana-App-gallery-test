import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/rendering.dart';

import 'codex_models.dart';

/// 法典浏览器的瀑布流几何:按顺序把每条词条塞进当时最矮的一列(一样矮取靠左),
/// 卡片高 = 列宽 / 封面比例,上下左右都隔 [gap]。
///
/// 卡片高度不用布局就算得出来 —— 法典卡就是一张定比例的图,标题叠在图上 ——
/// 所以整批位置一次算好,交给 SliverGrid 按下标取。瀑布流这才能套用
/// `ZoomGridDelegate` 做逐格的几何插值:换列数时每一张从旧列、旧尺寸连续走到
/// 新列、新尺寸。原先两个 SliverList 并排的写法做不到这一点。
class CodexMasonryLayout extends SliverGridLayout {
  factory CodexMasonryLayout(
    List<CodexEntry> entries, {
    required int cols,
    required double width,
    required double gap,
  }) {
    final n = entries.length;
    final colW = math.max(0.0, (width - gap * (cols - 1)) / cols);
    final col = Uint8List(n);
    final top = Float64List(n), height = Float64List(n), reach = Float64List(n);
    final next = List<double>.filled(cols, 0); // 每列下一张的顶边
    var far = 0.0;
    for (var i = 0; i < n; i++) {
      var c = 0;
      for (var k = 1; k < cols; k++) {
        if (next[k] < next[c]) c = k;
      }
      final h = colW / entries[i].aspect;
      col[i] = c;
      top[i] = next[c];
      height[i] = h;
      next[c] += h + gap;
      far = math.max(far, top[i] + h);
      reach[i] = far;
    }
    return CodexMasonryLayout._(colW, gap, col, top, height, reach);
  }

  const CodexMasonryLayout._(
    this.columnWidth,
    this._gap,
    this._col,
    this._top,
    this._height,
    this._reach,
  );

  final double columnWidth;
  final double _gap;
  final Uint8List _col;

  /// 各条顶边。**单调不减**:每条进的是当时最矮的那列,而列只会越排越高。
  final Float64List _top;
  final Float64List _height;

  /// 第 0..i 条里最靠下的底边。底边本身不单调(矮列里后来的一条可能比高列里
  /// 前面那条还靠上),取前缀最大才能二分。
  final Float64List _reach;

  /// 第一条底边越过 [offset] 的下标(再往前的都整个在它上方)。
  int _firstReachingPast(double offset) {
    var lo = 0, hi = _reach.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_reach[mid] > offset) {
        hi = mid;
      } else {
        lo = mid + 1;
      }
    }
    return lo;
  }

  /// 第一条顶边不早于 [offset] 的下标(从它起都整个在它下方)。
  int _firstStartingAt(double offset) {
    var lo = 0, hi = _top.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_top[mid] < offset) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  @override
  int getMinChildIndexForScrollOffset(double scrollOffset) =>
      _firstReachingPast(scrollOffset);

  @override
  int getMaxChildIndexForScrollOffset(double scrollOffset) {
    if (_top.isEmpty) return 0;
    // 兜底不小于同一位置的 min:RenderSliverGrid 断言末位不早于首位。正常视口下
    // 用不上 —— 要可见区矮过一道缝才会出现上下两段都够不着的空当。
    return math.min(
      _top.length - 1,
      math.max(
        _firstStartingAt(scrollOffset) - 1,
        _firstReachingPast(scrollOffset),
      ),
    );
  }

  @override
  SliverGridGeometry getGeometryForChildIndex(int index) {
    // 越界的下标 RenderSliverGrid 只拿来试探「还有没有下一个」,给个末尾的空格子
    if (index >= _top.length) {
      return SliverGridGeometry(
        scrollOffset: computeMaxScrollOffset(_top.length),
        crossAxisOffset: 0,
        mainAxisExtent: 0,
        crossAxisExtent: columnWidth,
      );
    }
    return SliverGridGeometry(
      scrollOffset: _top[index],
      crossAxisOffset: _col[index] * (columnWidth + _gap),
      mainAxisExtent: _height[index],
      crossAxisExtent: columnWidth,
    );
  }

  @override
  double computeMaxScrollOffset(int childCount) =>
      _reach.isEmpty ? 0 : _reach.last;
}

/// 按列数给瀑布流几何,背后按(词条批次, 列数, 可用宽)缓存。
///
/// 缓存是必需的:换档过渡每帧要起点、目标两套布局,滚动时每帧也取一次;一本法典
/// 上万条,每帧现算就是每帧几十万字节的数组分配。换了一批词条(搜索、换分类、
/// 换法典都会给一份新列表)整份作废。
class CodexMasonry {
  CodexMasonry({required this.gap});

  final double gap;

  List<CodexEntry>? _batch;
  final _layouts = <(int, double), CodexMasonryLayout>{};

  CodexMasonryLayout layout(List<CodexEntry> entries, int cols, double width) {
    if (!identical(entries, _batch)) {
      _batch = entries;
      _layouts.clear();
    }
    return _layouts[(cols, width)] ??= CodexMasonryLayout(
      entries,
      cols: cols,
      width: width,
      gap: gap,
    );
  }

  SliverGridDelegate delegate(List<CodexEntry> entries, int cols) =>
      _MasonryDelegate(this, entries, cols);
}

class _MasonryDelegate extends SliverGridDelegate {
  const _MasonryDelegate(this.masonry, this.entries, this.cols);

  final CodexMasonry masonry;
  final List<CodexEntry> entries;
  final int cols;

  @override
  SliverGridLayout getLayout(SliverConstraints constraints) =>
      masonry.layout(entries, cols, constraints.crossAxisExtent);

  @override
  bool shouldRelayout(_MasonryDelegate old) =>
      old.cols != cols ||
      !identical(old.entries, entries) ||
      !identical(old.masonry, masonry);
}
