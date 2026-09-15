// 编辑页滚动收起顶栏与权重面板(ChromeScrollTracker)。
//
// 整页挂不起来(存储 / 分词器 / 后端全要注入),这里搭一个同构的骨架:会收起
// 的顶栏 + 正文滚动视图 + 会收起的面板 + 底栏。收放动画、视口变高、越界回弹
// 都真跑 —— 判定里的坑恰恰全在这些布局联动上,光喂通知测不出来。
//
// 第一版在「收起后正文还剩多少可滚」上加了道门槛,结果键盘一弹、面板一开,
// 常见长度的提示词全被挡在门外,真机上滚了等于没滚。下面的「中等长度」那条
// 就是钉这个的。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/features/editor/chrome_scroll.dart';

const _content = Key('content');

class _Harness extends StatefulWidget {
  const _Harness({required this.contentHeight, this.showAfter = 28});

  final double contentHeight;
  final double showAfter;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  late final _tracker = ChromeScrollTracker(showAfter: widget.showAfter);
  bool hidden = false;

  Widget _collapsible(Alignment alignment, double height) => ClipRect(
    child: AnimatedAlign(
      duration: const Duration(milliseconds: 200),
      alignment: alignment,
      heightFactor: hidden ? 0 : 1,
      child: SizedBox(height: height, width: double.infinity),
    ),
  );

  @override
  Widget build(BuildContext context) {
    // 测试画布 800×600:顶栏 52 + 面板 150 + 底栏 48,正文视口放出时 350、收起时 550
    return MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            _collapsible(Alignment.bottomCenter, 52),
            Expanded(
              child: NotificationListener<ScrollNotification>(
                onNotification: (n) {
                  final v = _tracker.update(n, hidden: hidden);
                  if (v != null) setState(() => hidden = v);
                  return false;
                },
                // 真正文里点击手势和滚动抢同一根手指(芯片 / 文本框 / 点空白),
                // 滚动得先越过起拖门槛才认账。不垫这一层,竞技场里只剩滚动,
                // 按下即赢,轻轻一抖也整段算成滚动。
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {},
                  child: SingleChildScrollView(
                    key: _content,
                    physics: const AlwaysScrollableScrollPhysics(),
                    child: SizedBox(
                      height: widget.contentHeight,
                      width: double.infinity,
                    ),
                  ),
                ),
              ),
            ),
            _collapsible(Alignment.topCenter, 150),
            const SizedBox(height: 48),
          ],
        ),
      ),
    );
  }
}

bool _hidden(WidgetTester tester) =>
    tester.state<_HarnessState>(find.byType(_Harness)).hidden;

double _offset(WidgetTester tester) => tester
    .state<ScrollableState>(
      find.descendant(
        of: find.byKey(_content),
        matching: find.byType(Scrollable),
      ),
    )
    .position
    .pixels;

/// 慢拖:分十步挪,每步一帧,停一下再松手 —— 不带惯性。
/// [dy] < 0 是手指往上推(往下翻)。
Future<void> _slowDrag(WidgetTester tester, double dy) async {
  final g = await tester.startGesture(tester.getCenter(find.byKey(_content)));
  for (var i = 0; i < 10; i++) {
    await g.moveBy(Offset(0, dy / 10));
    await tester.pump(const Duration(milliseconds: 16));
  }
  await tester.pump(const Duration(milliseconds: 120));
  await g.up();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('长正文:往下翻收起,往回翻放出', (tester) async {
    await tester.pumpWidget(const _Harness(contentHeight: 3000));
    await _slowDrag(tester, -200);
    expect(_hidden(tester), isTrue);
    await _slowDrag(tester, 120);
    expect(_hidden(tester), isFalse);
  });

  testWidgets('手指轻轻一抖不收', (tester) async {
    await tester.pumpWidget(const _Harness(contentHeight: 3000));
    await _slowDrag(tester, -30);
    expect(_hidden(tester), isFalse);
  });

  testWidgets('中等长度:收起后一屏放得下也照收,松手回弹不会又放出来', (tester) async {
    // 放出时只多出 100 可滚;收起后视口 550,整段 450 一屏放下
    await tester.pumpWidget(const _Harness(contentHeight: 450));
    await _slowDrag(tester, -120);
    expect(_hidden(tester), isTrue);
    expect(_offset(tester), 0); // 越界位置已弹回顶
    // 在顶上往下拽:放出来
    await _slowDrag(tester, 80);
    expect(_hidden(tester), isFalse);
    // 放出来之后照样还能再收
    await _slowDrag(tester, -120);
    expect(_hidden(tester), isTrue);
  });

  testWidgets('一屏放得下的短正文:怎么推都不收', (tester) async {
    await tester.pumpWidget(const _Harness(contentHeight: 200));
    await _slowDrag(tester, -150);
    expect(_hidden(tester), isFalse);
  });

  testWidgets('翻回顶上就放,哪怕只回了一小段', (tester) async {
    await tester.pumpWidget(const _Harness(contentHeight: 3000));
    await _slowDrag(tester, -40);
    expect(_hidden(tester), isTrue);
    await _slowDrag(tester, 60);
    expect(_offset(tester), 0);
    expect(_hidden(tester), isFalse);
  });

  testWidgets('往回一甩、惯性甩到顶:放出', (tester) async {
    // 放出门槛调到够不着:手指拖的那段放不出来,只剩「惯性到顶」这一条路
    await tester.pumpWidget(
      const _Harness(contentHeight: 3000, showAfter: 100000),
    );
    await _slowDrag(tester, -400);
    expect(_hidden(tester), isTrue);
    await tester.fling(find.byKey(_content), const Offset(0, 150), 4000);
    await tester.pumpAndSettle();
    expect(_offset(tester), 0);
    expect(_hidden(tester), isFalse);
  });

  testWidgets('往下一甩收起后,惯性停在半路:保持收起', (tester) async {
    await tester.pumpWidget(const _Harness(contentHeight: 6000));
    await tester.fling(find.byKey(_content), const Offset(0, -150), 3000);
    await tester.pumpAndSettle();
    expect(_offset(tester), greaterThan(0));
    expect(_hidden(tester), isTrue);
  });
}
