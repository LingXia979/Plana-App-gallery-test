import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_mode.dart';
import '../auth/bot_session_store.dart';
import '../auth/token_store.dart';
import 'backend_client.dart';
import 'backend_config.dart';
import 'nai_client.dart';

/// 点数信息(Anlas + 是否 Opus + NAI 5 额度电池)。按接入方式取源:
///  - token 直连:NAI `/user/subscription`(用户账户剩余 Anlas)。
///  - bot 授权:后端 `/api/anlas`(共享服务账户余额,对齐 web,isOpus 恒 true;
///    NAI 5 额度由服务端把主池各 Opus 号合并成一块水位再回来)。
/// 模式/令牌/后端地址变化自动重拉;失败回退 null。
final anlasProvider = AsyncNotifierProvider<AnlasNotifier, NaiSubscription?>(
  AnlasNotifier.new,
);

class AnlasNotifier extends AsyncNotifier<NaiSubscription?> {
  @override
  Future<NaiSubscription?> build() async {
    // await 依赖(而非取 .value):懒加载 storage 首读期间 .value 是 null,
    // 会先空跑一轮返回 null、再等重建,首帧点数/Opus 状态平白慢一拍。
    final mode = await ref.watch(authModeProvider.future);
    if (mode == AuthMode.bot) {
      final base = await ref.watch(backendBaseProvider.future);
      if (base.isEmpty) return null;
      try {
        final res = await ref.read(backendClientProvider).getAnlas();
        // 后端只回一个点数合计,分不出订阅额/已购额,整笔按订阅额记(界面于是
        // 只显示一个数,不会摊成「x+0」)。NAI 5 额度那边已按主池合并好再回来。
        return (
          anlas: res.anlas,
          fixedAnlas: res.anlas,
          purchasedAnlas: 0,
          isOpus: true,
          tier: 3,
          usage: res.usage,
        );
      } catch (_) {
        return null;
      }
    }
    final key = await ref.watch(primaryNaiKeyProvider.future);
    if (key == null || key.token.isEmpty) return null;
    try {
      // watch:换了主账号、或它打的机器变了,客户端跟着换,这里重查一次
      // (读到的是另一台机器上的账户读数,留着旧数就是错数)。
      return await ref
          .watch(naiClientProvider(key.endpoint))
          .subscription(key.token);
    } catch (_) {
      return null;
    }
  }

  /// 主动刷新(顶栏点按 / 生成后):**静默**拉新,成功才替换。
  /// 不置 loading——那会让所有消费端瞬间丢值:点数闪没、isOpus 丢失导致
  /// 免费图的费用胶囊闪现 20 Anlas 再变回免费(真机反馈修复)。
  Future<void> refresh() async {
    try {
      final mode = ref.read(authModeProvider).value;
      final NaiSubscription? next;
      if (mode == AuthMode.bot) {
        final base = await ref.read(backendBaseProvider.future);
        if (base.isEmpty) return;
        final res = await ref.read(backendClientProvider).getAnlas();
        next = (
          anlas: res.anlas,
          fixedAnlas: res.anlas,
          purchasedAnlas: 0,
          isOpus: true,
          tier: 3,
          usage: res.usage,
        );
      } else {
        final key = await ref.read(primaryNaiKeyProvider.future);
        if (key == null || key.token.isEmpty) return;
        next = await ref
            .read(naiClientProvider(key.endpoint))
            .subscription(key.token);
      }
      state = AsyncData(next);
    } catch (_) {} // 拉失败保留旧值(旧行为会把显示清掉,更糟)
  }
}

/// V5 的免费尺寸**现在还免不免**:true = 额度已见底,免费尺寸转按 Anlas 计价。
///
/// V5 的免费尺寸图吃的是 Opus 充电式额度([NaiUsage]),额度见底后 NAI **不报错**,
/// 而是安静地改用 Anlas 计费 —— 界面上那个「免费」得跟着变回真实点数,不然用户
/// 是在不知情的状态下花钱,而且下一眼看到的是余额莫名其妙少了一截。
///
/// **只对 token 直连线成立**:bot 线花的是共享号池,服务端取号时就把见底的号排除
/// 了(全见底直接拒绝出图,回 `NO_V5_QUOTA_MSG`),那条线上的免费是真免费 ——
/// 报个点数出来反而是假的。
final v5ChargedProvider = Provider<bool>((ref) {
  if (ref.watch(authModeProvider).value != AuthMode.token) return false;
  final usage = ref.watch(anlasProvider).asData?.value?.usage;
  return usage != null && usage.isNegative;
});

/// 我的 NAI 5 出图额度(`GET /api/user/quota`,**bot 授权线专有**)。
///
/// token 直连线没有这回事:那条线花的是自己账户的 Opus 电池
/// ([NaiSubscription.usage]),不经我们发配额,所以这里恒 null。
///
/// 与 [anlasProvider] 分开而不是并进同一个 notifier:两者来源不同(一个公开
/// 端点、一个要会话),任一失败都不该把另一个也拖没 —— 点数拉不到时至少还能
/// 告诉用户「还能出几张」,反过来也一样。
final naiQuotaProvider = AsyncNotifierProvider<NaiQuotaNotifier, NaiQuota?>(
  NaiQuotaNotifier.new,
);

class NaiQuotaNotifier extends AsyncNotifier<NaiQuota?> {
  @override
  Future<NaiQuota?> build() async {
    final mode = await ref.watch(authModeProvider.future);
    if (mode != AuthMode.bot) return null;
    final session = await ref.watch(botSessionProvider.future);
    if (session == null) return null;
    return _fetch(session.sessionId);
  }

  /// 主动刷新(弹层打开 / 点刷新 / 生成后):**静默**拉新,理由同
  /// [AnlasNotifier.refresh] —— 置 loading 会让读数先闪没再回来。
  Future<void> refresh() async {
    if (ref.read(authModeProvider).value != AuthMode.bot) return;
    final session = await ref.read(botSessionProvider.future);
    if (session == null) return;
    final next = await _fetch(session.sessionId);
    if (next != null) state = AsyncData(next); // 拉失败保留旧值
  }

  /// 拿不到就 null:老服务端根本没有这个端点(404),那时整块不显示,
  /// 而不是弹一个用户什么也做不了的错。
  Future<NaiQuota?> _fetch(String sessionId) async {
    try {
      return await ref.read(backendClientProvider).myNaiQuota(sessionId);
    } catch (_) {
      return null;
    }
  }
}
