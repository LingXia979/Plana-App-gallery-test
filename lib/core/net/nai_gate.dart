import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/nai_keys.dart';
import 'gen_abort.dart';

/// 闸门发出的一次通行证:用第几把(下标)、用哪个令牌、打哪台机器。
///
/// [base] 跟着那把 Key 走(空串 = 官方):挑哪把是闸门定的,调用方无从自己
/// 查地址 —— 两处各查一次会在中途增删 Key 时错位,打到别人那台机器上去。
///
/// [token] 为 null = 一把可用的都没有。调用方照常往下走,让它撞到「没有令牌」
/// 那个错误 —— 卡在等位里没有下文的话,界面上就是「点了没反应」。
typedef NaiPass = ({int slot, String? token, String base});

/// 直连 NAI 的并发闸门 —— **全 app 共用一份**。
///
/// NAI 按账号限流:同一把 Key 同时打两个请求,第二个直接 429。所以
///  · 一把 Key 同时只跑一条 —— 槽位就是**这把 Key 在列表里的下标**;
///  · 并发上限就是能出图的把数(主账号 + 勾了「并发生成」的副账号)——
///    没有单独的并发设置,加一把、勾一个就自己涨。
///
/// 闸门单独放在这里、而不是留在生成控制器里,是因为**吃这条限额的不止生成**:
/// 图库的 NAI 超分、灵感页的标签预览打的是同一个账号、同一个限流桶。原先只有
/// 生成之间排队,生成中点一次超分照样能撞 429。
///
/// bot 线不走这里:那条打的是后端、花的是服务账号,并发由 `kMaxRunningBot` 管。
class NaiGate {
  NaiGate(this._ref);

  final Ref _ref;

  /// 占用中的**全局 Key 下标**。用全局下标而不是「第几个可用的」:
  /// 免费单和付费单看到的可用集合不一样(付费要滤掉关了点数开关的),
  /// 按可用集内的序号记账,两个集合会把同一把 Key 认成两个槽而放行两条。
  final _busy = <int>{};
  final _waiters = <Completer<void>>[];

  Future<List<NaiKey>> _all() async {
    try {
      return await _ref.read(naiKeysStoreProvider.future);
    } catch (_) {
      return const [];
    }
  }

  /// 并发上限 = **主账号 + 开了「并发生成」的副账号**,也就是能出图的把数。
  /// 没有单独的并发设置 —— 加一把、勾一个,并发自己就涨上去了。
  ///
  /// 一把都没存时给 1:让任务照常跑到「没有令牌」那个错误上,而不是卡在等位里
  /// 没有下文(那种卡法在界面上就是「点了没反应」)。
  ///
  /// **不按这一单的可用集合算**:免费单能用 3 把、付费单只能用 1 把时,若各按
  /// 各的算上限,免费单占掉 1 个名额后付费单会看到「1 个名额已满」而永远排队
  /// —— 明明还有一把闲着。名额是全局的,能不能用某一把由下面的可用集合决定。
  Future<int> limit() async => _cap(await _all());

  int _cap(List<NaiKey> all) {
    final n = all.where((k) => k.forGenerate).length;
    return n < 1 ? 1 : n;
  }

  /// 取一张通行证,满了就排队等别人释放。
  ///
  /// [paid] = 这一趟要扣 Anlas(关了点数开关的 Key 会被跳过)。
  /// 等位期间被取消时返回 slot = -1。
  Future<NaiPass> acquire({bool paid = false, GenAbort? abort}) async {
    final all = await _all();
    final usable = naiKeysForGenerate(all, paid: paid);
    if (usable.isEmpty) return (slot: -1, token: null, base: '');

    // 可用 Key 的全局下标,顺序即优先级 —— 首位那把的点数先被花。
    final idx = [for (final k in usable) all.indexWhere((e) => e.id == k.id)];
    final cap = _cap(all);

    while (abort?.aborted != true) {
      if (_busy.length < cap) {
        for (var i = 0; i < idx.length; i++) {
          if (_busy.add(idx[i])) {
            return (
              slot: idx[i],
              token: usable[i].token,
              base: usable[i].endpoint,
            );
          }
        }
      }
      final w = Completer<void>();
      _waiters.add(w);
      // 等位期间被取消也要醒过来,否则这条会一直挂着
      abort?.whenAbort(() {
        if (!w.isCompleted) w.complete();
      });
      await w.future;
    }
    return (slot: -1, token: null, base: '');
  }

  void release(int slot) {
    if (slot < 0) return;
    _busy.remove(slot);
    // 唤醒下一个等位的。跳过已完成的:那是等位期间被取消的任务留下的空壳。
    while (_waiters.isNotEmpty) {
      final w = _waiters.removeAt(0);
      if (!w.isCompleted) {
        w.complete();
        return;
      }
    }
  }

  /// 占着槽跑一段 —— 超分、标签预览这类「一次一趟」的直连调用用它,
  /// 不必自己配对 acquire/release(漏掉 release 会把闸门永久焊死)。
  ///
  /// 拿不到令牌时 [body] 收到 null,由调用方决定报什么错。第二个参数是这把
  /// Key 的接口地址,直接喂 `naiClientProvider` —— 别另查一次。
  Future<T> run<T>(
    Future<T> Function(String? token, String base) body, {
    bool paid = false,
    GenAbort? abort,
  }) async {
    final pass = await acquire(paid: paid, abort: abort);
    try {
      return await body(pass.token, pass.base);
    } finally {
      release(pass.slot);
    }
  }

  /// 仅供测试观察。
  int get busyCount => _busy.length;
}

/// 闸门是进程级单例:provider 体内不 watch 任何东西,保证不会被重建。
/// 重建 = 丢掉正在占用的槽位,等于闸门失效。
final naiGateProvider = Provider<NaiGate>(NaiGate.new);
