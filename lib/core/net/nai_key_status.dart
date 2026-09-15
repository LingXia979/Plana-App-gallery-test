import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/nai_keys.dart';
import 'nai_client.dart';

/// 一次直连查询要打谁:哪把令牌、打哪台机器(空串 = 官方)。
typedef NaiTarget = ({String token, String base});

/// 一把 Key 的查询目标。地址跟着 Key 走,调用点各拼各的迟早漏一个。
NaiTarget naiTargetOf(NaiKey k) => (token: k.token, base: k.endpoint);

/// 单把 Key 的账户状态(档位 / Anlas / V5 额度)—— 账号页每行下方那条读数。
///
/// 按**(令牌, 地址)**做 family 而不是按 Key 的 id:换令牌(手动重贴、JWT 续期)
/// 之后显示的必须是新账号的数,按 id 缓存会把旧账号的读数一直挂在那儿。地址也
/// 进键,是因为同一串 key 打两台机器就是两个账号。
///
/// 不走 [NaiGate]:这是只读的 `/user/subscription`,排在生成后面的话开一次页面
/// 要等好几张图跑完才出数,而它并不占那条「同 Key 不许并发」的生成额度。
///
/// `autoDispose` —— 离开账号页就丢掉,下次进来重新拉。点数是会变的,
/// 缓存一份旧的比不显示更糟。
final naiKeyStatusProvider = FutureProvider.autoDispose
    .family<NaiSubscription, NaiTarget>((ref, t) async {
      return ref.watch(naiClientProvider(t.base)).subscription(t.token);
    });
