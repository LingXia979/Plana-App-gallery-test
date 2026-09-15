// 令牌管理页的下拉刷新。这块**只靠肉眼验不出来**:查询期间每行显示的还是上一次
// 的旧数(`when` 默认 skipLoadingOnRefresh),点数又常常跟刚才一样 —— 真去打了
// 请求和压根没打,屏幕上看着一模一样。所以这里数的是「发出去几次请求」。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plana_app/core/auth/nai_keys.dart';
import 'package:plana_app/core/net/nai_client.dart';
import 'package:plana_app/features/profile/token_manage_page.dart';

/// 只读的 Key 列表(不碰真的安全存储)。
class _FakeKeys extends NaiKeysNotifier {
  _FakeKeys(this._seed);
  final List<NaiKey> _seed;
  @override
  Future<List<NaiKey>> build() async => _seed;
}

/// 数请求次数的假客户端;每查一次 Anlas 就加一,好看出屏幕上换没换数。
class _CountingClient extends NaiClient {
  final calls = <String, int>{};

  /// 非空时查询卡在这儿,由测试决定什么时候放行 —— 用来模拟「请求还在路上」。
  Completer<void>? gate;

  @override
  Future<NaiSubscription> subscription(String token) async {
    final n = (calls[token] ?? 0) + 1;
    calls[token] = n;
    if (gate != null) await gate!.future;
    return (
      anlas: 1000 * n,
      fixedAnlas: 1000 * n,
      purchasedAnlas: 0,
      isOpus: true,
      tier: 3,
      usage: null,
    );
  }
}

void main() {
  testWidgets('下拉刷新:每把令牌都重新查一次账户状态', (tester) async {
    final client = _CountingClient();
    final keys = [
      const NaiKey(id: 'a', token: 'tok-a', label: '主号', primary: true),
      const NaiKey(id: 'b', token: 'tok-b', label: '小号'),
    ];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          naiKeysStoreProvider.overrideWith(() => _FakeKeys(keys)),
          naiClientProvider.overrideWith((ref, base) => client),
        ],
        child: const MaterialApp(home: TokenManagePage()),
      ),
    );
    await tester.pumpAndSettle();

    // 开页各查一次,两把的读数都摆出来了
    expect(client.calls, {'tok-a': 1, 'tok-b': 1});
    expect(find.textContaining('Anlas 1,000'), findsNWidgets(2));

    // 下拉:拖过触发距离再松手
    await tester.fling(
      find.byType(ReorderableListView),
      const Offset(0, 320),
      1000,
    );
    await tester.pumpAndSettle();

    expect(client.calls, {'tok-a': 2, 'tok-b': 2}, reason: '两把都该重查一遍');
    expect(
      find.textContaining('Anlas 2,000'),
      findsNWidgets(2),
      reason: '重查回来的新数要顶掉旧的',
    );
  });

  // 这条才是「下拉了好像没反应」的正主:光 invalidate 不等,指示器转半圈就收,
  // 而查询期间每行显示的还是旧数(skipLoadingOnRefresh),点数又常常没变 ——
  // 屏幕上就是什么都没发生。指示器必须一直转到请求真的回来。
  testWidgets('请求没回来之前,指示器不许收', (tester) async {
    final client = _CountingClient();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          naiKeysStoreProvider.overrideWith(
            () => _FakeKeys([
              const NaiKey(id: 'a', token: 'tok-a', primary: true),
            ]),
          ),
          naiClientProvider.overrideWith((ref, base) => client),
        ],
        child: const MaterialApp(home: TokenManagePage()),
      ),
    );
    await tester.pumpAndSettle();

    client.gate = Completer<void>(); // 从这儿起,查询卡在半路
    await tester.fling(
      find.byType(ReorderableListView),
      const Offset(0, 320),
      1000,
    );
    // 三拍:起手 → 吸附动画走完(走完 RefreshIndicator 才会调 onRefresh)
    // → 再给一秒,够收起动画跑完好几趟了。
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));

    expect(client.calls['tok-a'], 2, reason: '请求已经发出去了');
    expect(
      find.byType(RefreshProgressIndicator),
      findsOneWidget,
      reason: '请求还在路上,指示器不能提前收',
    );

    client.gate!.complete();
    await tester.pumpAndSettle();
    expect(find.byType(RefreshProgressIndicator), findsNothing);
  });

  // 用户看得见的那一半:光有指示器还不够 —— 查询期间每一行都得退回「查询账户
  // 状态…」,再换成新读数。旧数一直挂着不动的话,点数没变的时候(常态)整页
  // 从头到尾一个像素都不动,下拉了跟没下拉一样。
  testWidgets('刷新期间每一行都退回「查询中」,回来再换成新读数', (tester) async {
    final client = _CountingClient();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          naiKeysStoreProvider.overrideWith(
            () => _FakeKeys([
              const NaiKey(id: 'a', token: 'tok-a', label: '主号', primary: true),
              const NaiKey(id: 'b', token: 'tok-b', label: '小号'),
              const NaiKey(id: 'c', token: 'tok-c', label: '三号'),
            ]),
          ),
          naiClientProvider.overrideWith((ref, base) => client),
        ],
        child: const MaterialApp(home: TokenManagePage()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Anlas 1,000'), findsNWidgets(3));
    expect(find.text('查询账户状态…'), findsNothing);

    client.gate = Completer<void>();
    await tester.fling(
      find.byType(ReorderableListView),
      const Offset(0, 320),
      1000,
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(
      find.text('查询账户状态…'),
      findsNWidgets(3),
      reason: '三行全都该退回查询中,而不是留着旧读数不动',
    );
    expect(find.textContaining('Anlas'), findsNothing, reason: '旧读数不该还挂着');

    client.gate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('查询账户状态…'), findsNothing);
    expect(find.textContaining('Anlas 2,000'), findsNWidgets(3));
  });
}
