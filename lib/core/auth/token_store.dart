import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'nai_keys.dart';

/// 本机加密存储的 NovelAI 访问令牌(直连 NAI 用)。
///
/// 真正的存储在 [naiKeysStoreProvider](可存多把);这里是它的**主账号视图**
/// —— 「一次只能对一个账号」的调用点(点数读数、超分、标签预览、JWT 续期)
/// 都读它。生成不走这里:那条按槽位轮着用全部 Key,见 [naiKeysProvider]。
final tokenProvider = AsyncNotifierProvider<TokenNotifier, String?>(
  TokenNotifier.new,
);

/// 已保存的 NAI Key 全集 —— 直连的并发上限就是它的长度,「每条任务独占一把
/// Key」也按它分配。NAI 是**按账号限流**的,同一把 Key 并发只会自己打自己
/// (429),所以上限不能拍脑袋给个常数。见 `core/net/nai_gate.dart`。
final naiKeysProvider = FutureProvider<List<String>>((ref) async {
  final keys = await ref.watch(naiKeysStoreProvider.future);
  return [for (final k in keys) k.token];
});

/// 主账号那把的**完整条目**。需要连接口地址一起知道的调用点用它(查点数、
/// Vibe 编码):光有令牌不够,第三方那把得打它自己那台机器。
final primaryNaiKeyProvider = FutureProvider<NaiKey?>(
  (ref) async => naiPrimaryKey(await ref.watch(naiKeysStoreProvider.future)),
);

class TokenNotifier extends AsyncNotifier<String?> {
  @override
  Future<String?> build() async {
    return naiPrimaryKey(await ref.watch(naiKeysStoreProvider.future))?.token;
  }

  /// 保存一把令牌(空串等同清除)。
  ///
  /// 一把都没存时就是「存上第一把」;已经有了则**追加**成新的一把 —— 引导页和
  /// 邮箱登录都走这里,它们的语义本来就是「把这把加进来能用」。要替换某一把
  /// 请用 [NaiKeysNotifier.replaceToken],要清空用 [clear]。
  Future<void> save(String token, {String? accessKey}) async {
    final t = token.trim();
    if (t.isEmpty) {
      await clear();
      return;
    }
    await ref.read(naiKeysStoreProvider.notifier).add(t, accessKey: accessKey);
  }

  /// 清空**全部** Key(「清除令牌」那颗按钮的语义)。
  Future<void> clear() => ref.read(naiKeysStoreProvider.notifier).clearAll();
}
