import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/util/prompt_tokens.dart';
import 'package:plana_app/features/editor/data/local_tag_db.dart';
import 'package:plana_app/features/editor/data/suggestions.dart';

/// S3-02 的回归:词库解析搬进了后台 isolate(`compute`),
/// 而 `_Entry` 是个普通 Dart 类 —— 9 万个对象能不能跨 isolate 传回来,
/// 只有真跑一次才知道,静态分析看不出来。
///
/// 顺带把这个模块的基本检索行为钉住:此前它零测试覆盖。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    '后台 isolate 解析 + 结果传回主 isolate(S3-02 回归)',
    () async {
      final db = LocalTagDb();
      final r = await db.search('1girl');
      expect(r, isNotEmpty, reason: '整条 compute 链路必须能把解析结果送回来');
      expect(r.first.text, '1girl');
      expect(r.first.kind, SuggestionKind.tag);
      expect(r.first.count, greaterThan(0), reason: '热度字段应随对象一起过来');
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  // 注意:结果是 [标签名命中..., 别名命中...] 两段拼接,**各段内**按热度降序,
  // 整体并非全局有序(实现注释明写)。所以这里不断言全局降序 —— 一个冷门的
  // 标签名命中本来就应该排在热门的别名命中前面。
  test('前缀匹配:标签名命中优先,下划线转空格', () async {
    final db = LocalTagDb();
    final r = await db.search('long_h', limit: 5);
    expect(r, isNotEmpty);
    expect(r.first.text, isNot(contains('_')), reason: '展示用空格而非下划线');
    expect(r.first.text, startsWith('long h'), reason: '标签名命中排在别名命中之前');
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('查询短于 2 字符不检索(省得每敲一个字符扫全库)', () async {
    final db = LocalTagDb();
    expect(await db.search('a'), isEmpty);
  }, timeout: const Timeout(Duration(seconds: 60)));

  // 回归:`cacheTagMeta` 的上限原本是 20000,而灌注要塞进 7 万条译文 /
  // 9 万条热度,满了又是**整表清空** —— 词库按热度降序,于是灌完只剩尾部那截
  // 最冷门的标签,1girl 这种最常用的反查全落空。断言拿热度第一的标签来问。
  test('warmTagMeta 之后,最热门的标签也还在反查缓存里', () async {
    final db = LocalTagDb();
    await db.warmTagMeta();
    // 特意挑内置占位词库里**没有**的词:1girl / long hair 那些即使缓存被清空
    // 也能从 `_tags` 兜底答出来,拿它们断言等于什么都没测。
    expect(translationOf('highres'), isNotNull, reason: '灌注不能把自己灌没了');
    expect(countOf('highres'), greaterThan(1000000));
    expect(translationOf('blush'), isNotNull);
  }, timeout: const Timeout(Duration(seconds: 120)));

  test('transOf:自带译名优先,缺则反查;画师/OC 不反查', () {
    cacheTagMeta('cache only tag', trans: '只在缓存里');
    const own = Suggestion(
      text: 'cache only tag',
      kind: SuggestionKind.tag,
      trans: '自带的',
    );
    expect(transOf(own), '自带的');
    expect(
      transOf(const Suggestion(text: 'cache only tag', kind: SuggestionKind.tag)),
      '只在缓存里',
      reason: 'D 站来的行没有 trans,得回头查缓存',
    );
    expect(
      transOf(
        const Suggestion(text: 'cache only tag', kind: SuggestionKind.artist),
      ),
      isNull,
      reason: '画师串的名字不是 Danbooru 标签,反查只会串味',
    );
  });

  test('firstZh:多译只取第一个', () {
    expect(LocalTagDb.firstZh('少女,女孩'), '少女');
    expect(LocalTagDb.firstZh('长发、黑发'), '长发');
    expect(LocalTagDb.firstZh('a/b'), 'a');
    expect(LocalTagDb.firstZh(null), isNull);
    expect(LocalTagDb.firstZh(' , '), isNull);
    // 竖线是 byzod 那半边词表的分隔符,原先漏在名单外 —— smile、ribbon、
    // panties 这些百万热度的词整串「微笑|笑容」画进了注音层。
    expect(LocalTagDb.firstZh('微笑|笑容'), '微笑');
    expect(LocalTagDb.firstZh('张开腿|M字张腿|桃色蹲姿'), '张开腿');
    expect(LocalTagDb.firstZh('心｜心形'), '心');
    // 括号内的分隔符不算数:Fate/型月系的作品名自带斜杠,原先切在半括号上,
    // 「玉藻前（命运/额外）」变成「玉藻前（命运」,83 条角色名都是这么断的。
    expect(LocalTagDb.firstZh('玉藻前（命运/额外）'), '玉藻前（命运/额外）');
    expect(LocalTagDb.firstZh('珊璞 (乱马 1/2)'), '珊璞 (乱马 1/2)');
    expect(LocalTagDb.firstZh('莫德雷德 (Fate/Apocrypha),红saber'), '莫德雷德 (Fate/Apocrypha)');
    // 括号外照切
    expect(LocalTagDb.firstZh('户外/野战'), '户外');
    // 只有右括号(数据脏)不能把深度带成负数,否则后面的分隔符就切不掉了
    expect(LocalTagDb.firstZh('甲)乙,丙'), '甲)乙');
  });

  test('firstZh:标签自身带斜杠时,译名里的斜杠算名字不算分隔符', () {
    // 不给 tag 就按老规矩切 —— 「命运/大订单」削成「命运」,跟 fate_(series) 撞了
    expect(LocalTagDb.firstZh('Fate/Zero'), 'Fate');
    expect(LocalTagDb.firstZh('Fate/Zero', tag: 'fate/zero'), 'Fate/Zero');
    expect(LocalTagDb.firstZh('乱马1/2', tag: 'ranma_1/2'), '乱马1/2');
    expect(LocalTagDb.firstZh('22/7', tag: '22/7'), '22/7');
    // 斜杠豁免只对斜杠生效,别的分隔符照切
    expect(LocalTagDb.firstZh('K/DA,女团', tag: 'k/da_(league_of_legends)'), 'K/DA');
    // 标签不含斜杠时,斜杠仍是多译分隔符
    expect(LocalTagDb.firstZh('伪娘/变装', tag: 'crossdressing'), '伪娘');
  });

  test('静态兜底表只放离线库没有的词:灌注前后不跳字', () async {
    // translationOf 先查缓存、缺了才扫静态表。两边都有同一个词、译名却不同的话,
    // 用户会在灌注完成那一刻看到注音**跳字**(清理前实测 6 条:red eyes 红眼→红眼睛、
    // bad anatomy 解剖错误→身体结构崩坏、yuuki asuna 结城明日奈→亚丝娜…)。
    const conflicted = ['red eyes', 'bad anatomy', 'bad hands', 'jpeg artifacts',
        'chiaroscuro', 'yuuki asuna'];
    final before = {for (final w in conflicted) w: translationOf(w)};
    await LocalTagDb().warmTagMeta();
    for (final w in conflicted) {
      final after = translationOf(w);
      expect(after, isNotNull, reason: '$w 灌注后该有译名');
      if (before[w] != null) {
        expect(before[w], after, reason: '$w 灌注前后不能变字');
      }
    }
    // 库里天生没有的质量词仍要秒出(它们不是 Danbooru 标签)
    expect(translationOf('masterpiece'), isNotNull);
    expect(translationOf('best quality'), isNotNull);
  });

  test('渐进灌注:第一片就能查到最热的词,不必等整轮', () async {
    // 整轮灌注在手机上要一两秒。词库按热度降序,所以前几片就覆盖了真实提示词里
    // 大部分的词 —— 编辑器据此提前刷注音,否则首屏是"提示词先出来、注音过一会儿
    // 整片冒出来"。这里钉住:回调时热门词必须已经可查。
    final db = LocalTagDb();
    final atFirstChunk = <String, String?>{};
    var chunks = 0;
    await db.warmTagMeta(
      onChunk: () {
        if (chunks++ == 0) {
          atFirstChunk['1girl'] = translationOf('1girl');
          atFirstChunk['solo'] = translationOf('solo');
          atFirstChunk['long hair'] = translationOf('long hair');
        }
      },
    );
    expect(chunks, 3, reason: '只在前三个进度点刷,刷太勤注音层会反复重排');
    // 多个调用者各自的 onChunk 都要收到 —— 编辑器和同屏若干 PromptChips 会各调
    // 一次,记忆化写成 `_warming ??=` 的话只有头一个能收到,其余只能干等整轮。
    final db2 = LocalTagDb();
    var a = 0, b = 0;
    final f = db2.warmTagMeta(onChunk: () => a++);
    unawaited(db2.warmTagMeta(onChunk: () => b++));
    await f;
    expect(a, 3);
    expect(b, 3, reason: '第二个调用者也要收到分片回调');
    expect(atFirstChunk['1girl'], isNotNull);
    expect(atFirstChunk['solo'], isNotNull);
    expect(atFirstChunk['long hair'], isNotNull);
  });

  test('别名也进反查缓存:hires / 1girls / oppai 这类写法认得', () async {
    await LocalTagDb().warmTagMeta();
    // 别名是同一个标签的另一种写法,译名和热度都该跟着正名走
    expect(translationOf('hires'), translationOf('highres'));
    expect(countOf('hires'), countOf('highres'));
    expect(translationOf('1girls'), translationOf('1girl'));
    expect(translationOf('longhair'), translationOf('long hair'));
    expect(translationOf('oppai'), translationOf('breasts'));
    // 下划线写法同样走 metaKey 归一
    expect(translationOf('high_res'), translationOf('highres'));
    // 正名优先:别名不能盖掉一个本身就是正式标签的词
    expect(translationOf('solo'), isNotNull);
  });

  test('反查键归一:下划线/连续空白/大小写三种写法都命中', () {
    // 灌注写进去的是空格形态(warmTagMeta 用 e.tag.replaceAll('_', ' ')),
    // 而从 Danbooru 复制来的提示词是下划线形态 —— 2026-08-28 之前后者一条都
    // 命中不了:注音层整条空白、词条栏没热度,还会把这些词全白送去后端问一遍。
    cacheTagMeta('zzz long hair', trans: '长发', count: 4350743);
    for (final form in [
      'zzz long hair',
      'zzz_long_hair',
      'zzz  long   hair',
      'ZZZ_Long_Hair',
      '  zzz long hair  ',
    ]) {
      expect(translationOf(form), '长发', reason: form);
      expect(countOf(form), 4350743, reason: form);
    }
  });

  // ---- 角色反查(danbooru.tsv 第 5 列 category)----

  test('charactersIn:认出角色标签,普通标签/作品/画师都不算', () async {
    final db = LocalTagDb();
    final hit = await db.charactersIn(
      tokenizeSet('1girl, hakurei_reimu, long hair, highres, touhou, wlop'),
    );
    expect(hit.map((e) => e.tag), ['hakurei_reimu']);
    expect(hit.single.zh, '博丽灵梦');
    // touhou 是作品(类目 3)、wlop 是画师(类目 1)—— 本轮 category 只填了角色,
    // 这两类留空,不能被当成角色捞出来。
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('charactersIn:下划线/括号两种写法同归一', () async {
    final db = LocalTagDb();
    for (final form in [
      'ganyu_(genshin_impact)',
      'ganyu (genshin impact)',
      'Ganyu_(Genshin_Impact)',
      '1.3::ganyu_(genshin_impact)::',
    ]) {
      final hit = await db.charactersIn(tokenizeSet(form));
      expect(hit.map((e) => e.tag), ['ganyu_(genshin_impact)'], reason: form);
    }
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('charactersIn:别名也认(reimu_hakurei → 博丽灵梦)', () async {
    final db = LocalTagDb();
    final hit = await db.charactersIn(tokenizeSet('reimu_hakurei'));
    expect(hit.map((e) => e.tag), ['hakurei_reimu']);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('charactersIn:多角色按热度降序,空输入零命中', () async {
    final db = LocalTagDb();
    final hit = await db.charactersIn(
      tokenizeSet('hakurei_reimu, hatsune_miku, 1girl'),
    );
    expect(hit.map((e) => e.tag), ['hatsune_miku', 'hakurei_reimu']);
    expect(hit.first.count, greaterThan(hit.last.count));
    expect(await db.charactersIn(const {}), isEmpty);
    expect(await db.charactersIn(tokenizeSet('1girl, solo')), isEmpty);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('cacheTagMeta:译名等于标签本身不收,刻意排版过的专有名词照收', () {
    cacheTagMeta('rwby', trans: 'rwby');
    expect(translationOf('rwby'), isNull, reason: '原样透传等于没翻译,占坑会挡住后端');
    cacheTagMeta('pixiv id', trans: 'pixiv id');
    expect(translationOf('pixiv id'), isNull, reason: '下划线转空格后仍是原样');
    cacheTagMeta('zzz_echo_tag', trans: 'zzz echo tag');
    expect(translationOf('zzz_echo_tag'), isNull, reason: '两边归一后相同,同样是没翻译');

    cacheTagMeta('vocaloid', trans: 'VOCALOID');
    expect(translationOf('vocaloid'), 'VOCALOID', reason: '专有名词保持原文就是正确答案');
    cacheTagMeta('muv-luv', trans: 'Muv-Luv');
    expect(translationOf('muv-luv'), 'Muv-Luv');
  });
}
