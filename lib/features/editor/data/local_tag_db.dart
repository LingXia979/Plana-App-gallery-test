import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'suggestions.dart';
import 'tag_index.dart';

/// 离线 Danbooru 标签库(源数据 `assets/danbooru.tsv`,**含中文翻译**,已按热度降序;
/// 进包的是构建期编好的索引,见 [TagIndex])。
/// 用户在设置里显式选了「离线词库」时的英文补全走这里——**完全离线**,不碰网络,
/// 天然绕开 Cloudflare。(2026-08-25 前它还是「未授权模式」的兜底,门禁解除后不再是。)
/// 行格式(tab 分隔):`tag<TAB>post_count<TAB>中文<TAB>alias1,alias2<TAB>category`;
/// tag 用下划线,app 内展示/插入转空格;中文来自社区词库(ChinaGPT 10w + byzod 精选合并)。
///
/// **category 列(2026-09-05 补)**:Danbooru 类目编号,目前只填 4(角色),
/// 共 26,083 行(count≥50 的目标集里 23,983 行,占 26.3%)。来源是后端两份建库
/// 产物的并集 —— `tags_enhanced.csv` 的 category=4(20,169)+
/// `role_tag_mapping.json` 的 role_en(28,335);两者交叉验证 19,263 条**完全一致**,
/// 所以并集可直接用。画师(类目 1)与 meta(5)**上游没有**,要另跑 Danbooru
/// `tags.json?search[category]=1` 采集,本轮没做;作品(3)只有 `tags_enhanced`
/// 那 5,225 条可信 —— `role_tag_mapping.origin_en` 抽样只有 71% 真是作品
/// (19.7% 其实是普通标签、9.2% 是角色,`kantoku`/`rella` 这种画师限定符被误提升),
/// 故未采用。空 category = **未定类**,不等于「普通标签」。
class LocalTagDb {
  Future<TagIndex?>? _index;

  /// 读进索引。Android 端这个 asset 不压缩存(见 android/app/build.gradle.kts),
  /// 引擎直接 mmap,拿到的 ByteData 就是那段映射 —— 不拷贝、不解析,几毫秒。
  /// 压缩存的话,引擎会在 UI 线程上把近 10MB 整份解压出来。
  ///
  /// 读不出来(不该发生)时各查询一律按查不到处理。
  Future<TagIndex?> get _ready => _index ??= () async {
    try {
      return TagIndex(await rootBundle.load(kTagIndexAsset));
    } catch (e) {
      debugPrint('离线词库索引读取失败:$e');
      return null;
    }
  }();

  /// 读进索引并装给注音层 / 词条栏的同步反查([translationOf] / [countOf])。
  /// 开机在 runApp 之前调,从第一帧起就查得到。
  Future<void> install() async {
    offlineTagMeta = await _ready;
  }

  /// 前缀匹配:标签名命中优先、别名命中次之。取前 [limit] 条。见 [TagIndex.search]。
  Future<List<Suggestion>> search(String query, {int limit = 15}) async =>
      (await _ready)?.search(query, limit: limit) ?? const [];

  // ---- 角色反查(离线) ----

  /// 提示词分词集合 → 命中的角色标签,**按热度降序**(库本身即热度序)。
  ///
  /// 分词用 `tokenizeSet`,与索引的键同走 `cleanPromptToken`,下划线/括号/权重
  /// 记号两边同归一。词库读不出来时得空表,调用方按「没有角色」处理即可,不必区分。
  Future<List<CharacterTag>> charactersIn(Set<String> tokens) async {
    if (tokens.isEmpty) return const [];
    return (await _ready)?.charactersIn(tokens) ?? const [];
  }

  // ---- 帖子数反查(图库归类加权用) ----

  /// 分词后的词(`cleanPromptToken` 口径)→ 词库帖子数;词库没收、或冷门到
  /// 建库时被滤掉的回 0。
  ///
  /// 图库按角色 / 画风归类时拿它掂量灵感库条目里每个词的分量:「1girl」几百万帖,
  /// 「红冠鹤主题」一帖没有,两者对「这张图用没用这个 OC」的说服力差着数量级。
  Future<Map<String, int>> postCountsOf(Iterable<String> tokens) async {
    final idx = await _ready;
    return {for (final t in tokens) t: idx?.postCountOf(t) ?? 0};
  }
}

/// 全局单例。main 里开机就 new 一个、装好再注进来;没注的地方(测试)第一次查询时懒加载。
final localTagDbProvider = Provider<LocalTagDb>((ref) => LocalTagDb());
