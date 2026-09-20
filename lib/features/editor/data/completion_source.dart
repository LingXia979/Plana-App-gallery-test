import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/store/app_stores.dart';
import '../../../core/store/prefs_store.dart';

/// 补全来源。
///  - `enhanced`:走后端 `/api/tags/*`(Danbooru 代理 + 中文翻译 + 中文搜词)。
///  - `danbooru`:内置离线 Danbooru 词库(含中文),本地匹配、不联网(手机直连被 Cloudflare 挡死,改离线)。
enum CompletionSource { enhanced, danbooru }

/// 偏好键。**2026-08-25 从 `completion_source` 换到这个新键,存量值就此作废**。
///
/// 增强补全解除 Bot 授权门禁的同时要让所有人都落到增强档,包括老用户 —— 而老
/// 存档里那个 `danbooru` 多半不是主动选的:门禁在时「增强」那一档是灰的,设置里
/// 只有离线可点,点一下(哪怕它本来就选中着)就把偏好写死了。与其加一段迁移代码
/// 去猜哪次是主动、哪次是顺手,不如换个键让旧值整体失效:所有人重新从默认(增强)
/// 起步,之后**主动**切到离线的会写进新键并照常保持。
const _key = 'completion_source_v2';

/// 换键前的旧键,读到就顺手删掉,不在存储里留垃圾。
const _legacyKey = 'completion_source';

/// 用户在设置里显式选择的补全来源;`null` = 未选(走默认)。
final completionSourcePrefProvider =
    AsyncNotifierProvider<CompletionSourcePrefNotifier, CompletionSource?>(
      CompletionSourcePrefNotifier.new,
    );

class CompletionSourcePrefNotifier extends AsyncNotifier<CompletionSource?> {
  PrefsStore get _storage => ref.read(prefsStoreProvider);

  @override
  Future<CompletionSource?> build() async {
    try {
      // 旧键清场:值不再参考,只是别把它一直留在存储里
      unawaited(_storage.delete(key: _legacyKey));
      final v = await _storage.read(key: _key);
      return switch (v) {
        'enhanced' => CompletionSource.enhanced,
        'danbooru' => CompletionSource.danbooru,
        _ => null,
      };
    } catch (_) {
      return null;
    }
  }

  Future<void> set(CompletionSource source) async {
    try {
      await _storage.write(key: _key, value: source.name);
      state = AsyncData(source);
    } catch (e, st) {
      state = AsyncError(e, st);
    }
  }
}

/// 生效补全来源。**不再要求 Bot 授权**(2026-08-25):补全用到的后端接口
/// —— `/api/tags/autocomplete`、`/search`、`/wiki`、`/wiki-preview`、`/related`、
/// `/tags/translate`、`/tags/naturalize` —— 实测全是公开的,无会话照样 200。
/// 当初卡会话是照搬「后端功能 = 要授权」的惯例,并非接口本身的要求。
///
/// 无会话时唯一拿不到的是**公共库的画师串 / OC**(`/api/artists/list`、`/api/oc/list`
/// 返 401)—— 那两个接口要登录,[ArtistOcLibrary] 对空会话已经 fail-soft 返空,
/// 不会报错也不会拖慢别的分组;本机灵感库里的 OC 照样补得出来。
///
/// 所以现在一律默认增强;用户仍可在设置里显式切到离线词库(自建后端不可达、
/// 或就是不想让打字联网的场景)。
final effectiveCompletionSourceProvider = Provider<CompletionSource>((ref) {
  return ref.watch(completionSourcePrefProvider).value ??
      CompletionSource.enhanced;
});
