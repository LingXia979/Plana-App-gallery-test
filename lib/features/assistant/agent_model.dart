/// AI 助手用哪个 LLM 渠道。
///
/// 候选来自后端 `GET /api/agent/models`(即 `server/config.py` 的 `MODEL_CHOICES`),
/// **不在 app 里写死** —— 那张表上线下线很频繁(半年里 kimi、mimo、minimax 三个
/// 来了又走),写死就得跟着发版,而且发完老版本还在选一个已经不存在的渠道。
///
/// 选中的只存 key,发请求时原样带上。key 过期(渠道被下架)也不用特判:后端
/// `_normalize_model_key` 认不出就回落全局默认,最坏结果是「换了个模型答」,
/// 不会报错。
///
/// **没有 Bot 授权时后端渠道一概不给**,只能用自定义接口(见 [assistantBotAuthorizedProvider])。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/bot_session_store.dart';
import '../../core/net/backend_client.dart';
import '../../core/store/app_stores.dart';
import '../../core/store/prefs_store.dart';
import 'custom_endpoint.dart';

/// label 里括号那段(线路/渠道说明)。中英文括号都收。
final _paren = RegExp(r'[（(].*?[)）]');

class AgentModelChoice {
  const AgentModelChoice({
    required this.key,
    required this.name,
    this.recommended = false,
  });

  /// 发给后端的 `model`(MODEL_CHOICES 的 key)。
  final String key;

  /// 完整型号名,如 `GLM 5.3 Flash`。界面上一律显示这个,不显示 key,
  /// 也不显示 `short_label` —— 「GLM」「豆包」这种简称看不出是哪一代。
  final String name;

  /// 后端标了推荐:列表里挂角标并排在前面。纯展示,别的照常能选。
  final bool recommended;
}

class AgentModelList {
  const AgentModelList({this.choices = const [], this.active = ''});

  /// 已按「推荐在前」排好,同档保持后端给的顺序。
  final List<AgentModelChoice> choices;

  /// 后端当前的全局默认。用户没自己选过时就显示它。
  final String active;

  AgentModelChoice? byKey(String key) {
    for (final c in choices) {
      if (c.key == key) return c;
    }
    return null;
  }
}

/// 一条 choice 的完整型号名。
///
/// 与 bot 端 `core/nai_agent._agent_model_display_name` 同一套规则:优先 `name`,
/// 没有就把 `label` 的括号说明去掉,再没有就退回 key。**规则要跟着那边走** ——
/// 同一个渠道在 bot 里叫一个名、在 app 里叫另一个名,用户会以为是两个模型。
String modelDisplayName(String key, Map<String, dynamic> choice) {
  final name = choice['name']?.toString().trim() ?? '';
  if (name.isNotEmpty) return name;
  final label = choice['label']?.toString() ?? '';
  final cleaned = label.replaceAll(_paren, '').trim();
  return cleaned.isNotEmpty ? cleaned : key;
}

/// `GET /api/agent/models` 的响应 → 选项列表。
///
/// 后端那张表是给 bot 和 web 一起用的,字段比 app 需要的多(别名、registry key、
/// 预设变体),这里只挑三样。缺字段一律 fail-soft:少一条选项好过整页打不开。
AgentModelList parseAgentModels(Map<String, dynamic> j) {
  final raw = j['choices'];
  if (raw is! Map) return const AgentModelList();
  final out = <AgentModelChoice>[];
  raw.forEach((k, v) {
    final key = k.toString();
    if (key.isEmpty || v is! Map) return;
    final choice = v.cast<String, dynamic>();
    out.add(
      AgentModelChoice(
        key: key,
        name: modelDisplayName(key, choice),
        recommended: choice['recommended'] == true,
      ),
    );
  });
  // 稳定排序:推荐的提到前面,同档保持后端顺序(那个顺序本身有含义 ——
  // 第一条通常就是 ACTIVE_MODEL)。
  final recommended = [
    for (final c in out)
      if (c.recommended) c,
  ];
  final rest = [
    for (final c in out)
      if (!c.recommended) c,
  ];
  return AgentModelList(
    choices: [...recommended, ...rest],
    active: j['active']?.toString() ?? '',
  );
}

/// 可选渠道。后端基址变了自动重取(provider 依赖 client)。
final agentModelsProvider = FutureProvider<AgentModelList>((ref) async {
  final j = await ref.watch(backendClientProvider).agentModels();
  return parseAgentModels(j);
});

/// 选中自定义接口时,存的是这个前缀加接口 id。
///
/// 与后端渠道共用一个偏好键:两者是**互斥的一次选择**,分两个键存就会出现
/// 「都选着」这种表达不出来的状态,界面还得再判一次谁优先。
const kCustomKeyPrefix = 'custom:';

String customModelKey(String endpointId) => '$kCustomKeyPrefix$endpointId';

/// 选中的是不是自定义接口;是就给出接口 id。
String? customEndpointIdOf(String key) => key.startsWith(kCustomKeyPrefix)
    ? key.substring(kCustomKeyPrefix.length)
    : null;

const _key = 'assistant_model';

/// 用户**自己选过**的渠道 key;空串 = 没选过,跟着后端默认走。
///
/// 不把后端默认写进偏好:那样后端换了默认,没主动选过的用户会被钉在旧渠道上,
/// 而且他从来不知道自己「选过」。
final assistantModelPrefProvider =
    AsyncNotifierProvider<AssistantModelPrefNotifier, String>(
      AssistantModelPrefNotifier.new,
    );

class AssistantModelPrefNotifier extends AsyncNotifier<String> {
  PrefsStore get _storage => ref.read(prefsStoreProvider);

  @override
  Future<String> build() async {
    try {
      return await _storage.read(key: _key) ?? '';
    } catch (_) {
      return '';
    }
  }

  Future<void> set(String key) async {
    state = AsyncData(key);
    try {
      await _storage.write(key: _key, value: key);
    } catch (_) {
      // 存不下只影响下次冷启动,这一程照常按新选择走
    }
  }
}

/// 这一轮实际要发的 `model`。没选过就发空串,让后端用它的全局默认。
/// 选的是自定义接口时后端渠道用不上,发空串即可(那条根本不打后端出词)。
final assistantModelKeyProvider = Provider<String>((ref) {
  final k = ref.watch(assistantModelPrefProvider).value ?? '';
  return customEndpointIdOf(k) == null ? k : '';
});

/// 有没有 Bot 授权。没有也能用助手,但只能用自定义接口,资料只给本地库;
/// 预设照常从后端取。
final assistantBotAuthorizedProvider = Provider<bool>(
  (ref) => ref.watch(botSessionProvider).value != null,
);

/// 界面上该显示哪一条。选过就是选的那条;没选过显示后端默认那条;
/// 列表还没到货(或拿不到)就是 null,界面按「未知」显示。
/// 没有 Bot 授权时后端渠道不算:没选自定义接口就是 null。
final assistantModelProvider = Provider<AgentModelChoice?>((ref) {
  final pinned = ref.watch(assistantModelPrefProvider).value ?? '';
  // 自定义接口不在后端那张表里,名字从本机的接口列表取
  final custom = customEndpointIdOf(pinned);
  if (custom != null) {
    for (final e in ref.watch(customEndpointsProvider).value ?? const []) {
      if (e.id == custom) {
        return AgentModelChoice(key: pinned, name: e.displayName);
      }
    }
  }
  if (!ref.watch(assistantBotAuthorizedProvider)) return null;
  final list = ref.watch(agentModelsProvider).value;
  if (list == null) return null;
  return list.byKey(pinned) ?? list.byKey(list.active);
});

/// 这一轮该走哪条路:非 null = 直连这个自定义接口,null = 走 Plana 后端。
final assistantEndpointProvider = Provider<CustomEndpoint?>((ref) {
  final id = customEndpointIdOf(
    ref.watch(assistantModelPrefProvider).value ?? '',
  );
  if (id == null) return null;
  for (final e in ref.watch(customEndpointsProvider).value ?? const []) {
    // 填不全的不算数:发出去必然失败,不如当没选,回落后端那条
    if (e.id == id && e.usable) return e;
  }
  return null;
});
