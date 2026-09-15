// AI 助手里两处最容易写错的逻辑。
//
// 一是 tag 差集:整套「看得出改了什么」的设计全靠它,算错了回执就是假的。
// 二是站位继承:AI 只在用户明说方位时才给坐标,其余留空 —— 空的当成「放正中」
// 会让「让她笑一下」这种无关改动把用户摆好的构图重排掉。
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/features/assistant/agent_model.dart';
import 'package:plana_app/features/assistant/agent_trace.dart';
import 'dart:convert';
import 'dart:typed_data';

import 'package:plana_app/core/net/backend_client.dart' show AgentCharacter;
import 'package:plana_app/features/assistant/assistant_mode.dart';
import 'package:plana_app/features/assistant/assistant_models.dart';
import 'package:plana_app/features/assistant/assistant_settings.dart';
import 'package:plana_app/features/assistant/custom_endpoint.dart';
import 'package:plana_app/features/assistant/custom_endpoint_api.dart';
import 'package:plana_app/features/assistant/direct_agent.dart';
import 'package:plana_app/features/assistant/prompt_diff.dart';
import 'package:plana_app/features/assistant/assistant_state.dart';
import 'package:plana_app/features/assistant/widgets/reply_body.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/inspiration/codex/codex_char_split.dart';
import 'package:plana_app/features/generate/models.dart';

Directory _tempRoot() {
  final root = Directory.systemTemp.createTempSync('plana_assistant');
  addTearDown(() async {
    for (var i = 0; i < 10; i++) {
      try {
        root.deleteSync(recursive: true);
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  });
  return root;
}

Future<GenerateNotifier> _notifier() async {
  final stores = await AppStores.open(rootOverride: _tempRoot());
  final c = ProviderContainer(
    overrides: [appStoresProvider.overrideWithValue(stores)],
  );
  addTearDown(c.dispose);
  return c.read(generateProvider.notifier);
}

AssistantChange _change(String before, String after) => AssistantChange(
  before: PromptSnapshot(positive: before),
  after: PromptSnapshot(positive: after),
);

void main() {
  group('tag 差集', () {
    test('加了什么、删了什么,按 after 的顺序报', () {
      final c = _change(
        'masterpiece, 1girl, cherry blossoms, standing',
        'masterpiece, ciloranko, 1girl, cherry_blossom_tree, falling_petals, standing',
      );
      expect(c.added, ['ciloranko', 'cherry_blossom_tree', 'falling_petals']);
      expect(c.removed, ['cherry blossoms']);
    });

    test('空格与下划线是两个不同的 tag,不能归一成「没变」', () {
      // NAI 眼里 `cat girl` 和 `cat_girl` 是两条不同的 tag,把它们算成同一个
      // 会让一次真实的改写在回执上显示成「什么都没做」。
      final c = _change('cat girl', 'cat_girl');
      expect(c.added, ['cat_girl']);
      expect(c.removed, ['cat girl']);
    });

    test('顺序变了但内容没变 = 没有增删', () {
      final c = _change('a, b, c', 'c, a, b');
      expect(c.added, isEmpty);
      expect(c.removed, isEmpty);
    });

    test('重排角色时回执以角色为准 —— 那是比改几个 tag 大得多的动作', () {
      final c = AssistantChange(
        before: const PromptSnapshot(positive: 'a'),
        after: PromptSnapshot(
          positive: 'a, b',
          characters: [
            for (var i = 0; i < 3; i++)
              CharacterPrompt(id: '$i', name: '角色$i', positive: 'p$i'),
          ],
        ),
      );
      expect(c.charsChanged, isTrue);
      expect(c.charCount, 3);
    });
  });

  group('撤销的冲突判定', () {
    test('一字不差才算同步;正向词改一个字就不同步', () {
      const a = PromptSnapshot(positive: '1girl, solo', negative: 'lowres');
      expect(
        a.sameAs(
          const PromptSnapshot(positive: '1girl, solo', negative: 'lowres'),
        ),
        isTrue,
      );
      expect(
        a.sameAs(
          const PromptSnapshot(
            positive: '1girl, solo, cat',
            negative: 'lowres',
          ),
        ),
        isFalse,
      );
    });

    test('站位开关也算在内 —— AI 替用户开过它,撤销要连它一起还原', () {
      const a = PromptSnapshot(positive: 'x', useCoords: true);
      expect(a.sameAs(const PromptSnapshot(positive: 'x')), isFalse);
    });

    test('角色的站位变了就算不同步', () {
      final a = PromptSnapshot(
        positive: 'x',
        characters: [const CharacterPrompt(id: '1', name: 'A', position: 'B2')],
      );
      final b = PromptSnapshot(
        positive: 'x',
        characters: [const CharacterPrompt(id: '1', name: 'A', position: 'D3')],
      );
      expect(a.sameAs(b), isFalse);
    });
  });

  group('applyAgentCharacters 只认 AI 这一份', () {
    test('不从画布继承站位 —— 画布和 AI 两边彻底分开', () async {
      // 原先 AI 没给站位的角色会按位继承画布上同位旧角色的坐标。那是一次没人按过
      // 的「读画布」:用户没点引用,AI 也没见过这些坐标,结果却带着它们。
      final n = await _notifier();
      n.applyAgentCharacters([
        (
          name: '芙兰',
          positive: 'flandre',
          negative: '',
          position: '0.2000,0.5000',
        ),
        (
          name: '蕾米',
          positive: 'remilia',
          negative: '',
          position: '0.8000,0.5000',
        ),
      ]);

      // 第二轮 AI 一个坐标都没给。
      final placed = n.applyAgentCharacters([
        (name: '芙兰', positive: 'flandre, smile', negative: '', position: ''),
        (name: '蕾米', positive: 'remilia, smile', negative: '', position: ''),
      ]);
      expect(placed, isFalse, reason: 'AI 没摆位,不该报告摆过');
      expect(
        n.state.characters.map((c) => c.position).toList(),
        isNot(['0.2000,0.5000', '0.8000,0.5000']),
        reason: '上一份的坐标不该被悄悄继承过来',
      );
    });

    test('AI 一个角色都没给 = 清空,不是「保持原样」', () async {
      final n = await _notifier();
      n.applyAgentCharacters([
        (name: 'A', positive: 'a', negative: '', position: ''),
      ]);
      n.applyAgentCharacters(const []);
      expect(n.state.characters, isEmpty);
    });

    test('AI 摆了位就返回 true(调用方据此打开 use_coords)', () async {
      final n = await _notifier();
      final placed = n.applyAgentCharacters([
        (name: 'A', positive: 'a', negative: '', position: '0.3000,0.7000'),
      ]);
      expect(placed, isTrue);
      expect(n.state.characters.single.position, '0.3000,0.7000');
    });

    test('是替换不是追加 —— 聊三轮不会攒出十二个角色', () async {
      final n = await _notifier();
      for (var i = 0; i < 3; i++) {
        n.applyAgentCharacters([
          (name: 'A', positive: 'a', negative: '', position: ''),
          (name: 'B', positive: 'b', negative: '', position: ''),
        ]);
      }
      expect(n.state.characters.length, 2);
    });

    test('新角色比旧的多时,多出来的挑空格而不是撞在一起', () async {
      final n = await _notifier();
      n.applyAgentCharacters([
        (name: 'A', positive: 'a', negative: '', position: ''),
        (name: 'B', positive: 'b', negative: '', position: ''),
        (name: 'C', positive: 'c', negative: '', position: ''),
      ]);
      final pos = n.state.characters.map((c) => c.position).toList();
      expect(pos.whereType<String>().toSet().length, 3, reason: '三个角色不该落同一格');
    });
  });

  group('图片生成模型的档位映射', () {
    // 后端只看三件事:是不是 anima、是不是 krea、是不是以 nai_v5 开头,
    // 其余一律回落 4.5(agent_router/router.py:resolve_preset_and_backend)。
    // 映射错了不会报错,只会静默拿到错代次的预设 —— krea 尤其致命:
    // 它吃的是连贯自然语言,喂 4.5 的 tag 串预设基本等于没写提示词。
    test('三个父类各自映射到后端认得的档位', () {
      expect(agentImageModel('Anima XL 3.0'), 'anima');
      expect(agentImageModel('Krea 2'), 'krea');
      expect(agentImageModel('NAI 5.0 Full'), startsWith('nai_v5'));
      expect(agentImageModel('NAI 5.0 Curated'), startsWith('nai_v5'));
    });

    test('4.x 与认不出的一律回落 4.5,且不能误撞 nai_v5 前缀', () {
      for (final m in ['NAI 4.5 Full', 'NAI 4.5 Curated', 'NAI 4.0 Full', '']) {
        final got = agentImageModel(m);
        expect(got.startsWith('nai_v5'), isFalse, reason: '$m 被误判成 V5');
        expect(got, 'nai_v45_full');
      }
    });
  });

  group('历史回带', () {
    // AI 轮要带着当初那个 nai_draw 围栏一起回去。只回正文的话模型看不见自己
    // 上一轮写了什么,下一句「把头发改成金色」得从头推一遍 —— 连角色、画风
    // 都要重新查一次工具,用户看到的就是「怎么又查了一遍」。
    const draw = DrawProposal(
      positive: '1girl, plana_(blue_archive), halo',
      negative: 'bad hands',
    );

    test('有提议的那轮:正文 + 围栏', () {
      const m = AssistantMsg(
        id: 'x',
        role: MsgRole.ai,
        text: '改好了喵~',
        at: 1,
        draw: draw,
      );
      final out = replayText(m);
      expect(out, startsWith('改好了喵~'));
      expect(out, contains('```nai_draw'));
      // 围栏里必须是**完整提示词**,不是增量 —— 最新那条就等于当前这幅画的全部
      expect(out, contains('plana_(blue_archive)'));
      expect(out, contains('bad hands'));
      expect(out.trimRight(), endsWith('```'));
    });

    test('围栏里是合法 JSON,字段名与模型写的一致', () {
      const m = AssistantMsg(
        id: 'x',
        role: MsgRole.ai,
        text: 'ok',
        at: 1,
        draw: draw,
      );
      final body = replayText(m).split('```nai_draw\n')[1].split('\n```')[0];
      final j = jsonDecode(body) as Map<String, dynamic>;
      expect(j['positive'], draw.positive);
      expect(j['negative'], draw.negative);
      expect(j.containsKey('characters'), isTrue);
    });

    AssistantMsg ai(String id, {bool drawn = true}) => AssistantMsg(
      id: id,
      role: MsgRole.ai,
      text: 'ok',
      at: 1,
      draw: drawn ? draw : null,
    );
    AssistantMsg user(String id) =>
        AssistantMsg(id: id, role: MsgRole.user, text: '改一下', at: 1);

    test('只留最近两个有产出的 AI 轮', () {
      final msgs = [
        user('u1'),
        ai('a1'),
        user('u2'),
        ai('a2'),
        user('u3'),
        ai('a3'),
      ];
      expect(historyFenceIds(msgs, 2), {'a2', 'a3'});
    });

    test('纯聊天轮不占名额 —— 它本来就没围栏可留', () {
      final msgs = [
        user('u1'),
        ai('a1'),
        user('u2'),
        ai('a2', drawn: false),
        user('u3'),
        ai('a3', drawn: false),
      ];
      // 往前一直数到真有产出的那条,不能被两条闲聊挡住
      expect(historyFenceIds(msgs, 2), {'a1'});
    });

    test('不足两个就有几个算几个', () {
      expect(historyFenceIds([user('u1'), ai('a1')], 2), {'a1'});
      expect(historyFenceIds([user('u1')], 2), isEmpty);
      expect(historyFenceIds(const [], 2), isEmpty);
    });

    test('keep 为 0 就一个都不留', () {
      expect(historyFenceIds([user('u1'), ai('a1')], 0), isEmpty);
    });

    test('纯聊天轮原样返回,不凭空造一个空围栏', () {
      const m = AssistantMsg(
        id: 'x',
        role: MsgRole.ai,
        text: '这串 tag 挺好的喵',
        at: 1,
      );
      expect(replayText(m), '这串 tag 挺好的喵');
    });

    test('角色连 position 一起带回去', () {
      const m = AssistantMsg(
        id: 'x',
        role: MsgRole.ai,
        text: 'ok',
        at: 1,
        draw: DrawProposal(
          positive: '2girls',
          characters: [
            AgentCharacter(
              name: '普拉娜',
              positive: 'smile',
              position: '0.5000,0.4000',
            ),
          ],
        ),
      );
      // 不带的话下一轮模型重写 characters 会丢站位,用户摆好的构图被重排
      expect(replayText(m), contains('0.5000,0.4000'));
    });
  });

  group('直接生成的快照:沿用参数和 Vibe,其余只认 AI', () {
    // 原先是「拿画布当底、AI 给了的字段盖上去」。AI 没写角色分区时,出图会带上
    // 画布里原有的角色 —— 用户没点引用,AI 也没见过它们,图里却有。
    final canvas = GenerateState.initial().copyWith(
      prompt: 'miku, rin',
      negativePrompt: 'my curated negatives',
      promptRaw: 'miku, rin',
      characters: const [
        CharacterPrompt(id: 'c1', name: '初音', positive: 'hatsune_miku'),
        CharacterPrompt(id: 'c2', name: '镜音铃', positive: 'kagamine_rin'),
      ],
      params: const GenParams(
        model: 'nai-diffusion-4-5-full',
        width: 1216,
        height: 832,
        steps: 28,
        useCoords: true,
      ),
    );

    GenerateState send(DrawProposal r) {
      var i = 0;
      return proposalSendState(canvas, r, newId: () => 'p${i++}');
    }

    test('AI 没写角色分区,出图就没有分区', () {
      final s = send(const DrawProposal(positive: '1girl, cat ears'));
      expect(s.characters, isEmpty, reason: '画布上的初音和镜音铃不能混进来');
    });

    test('AI 没写负向,负向就是空', () {
      final s = send(const DrawProposal(positive: '1girl'));
      expect(s.negativePrompt, '');
    });

    test('正向词只认 AI 的,编辑器草稿也不带', () {
      final s = send(const DrawProposal(positive: '1girl'));
      expect(s.prompt, '1girl');
      expect(s.promptRaw, '', reason: '草稿是画布那份的,留着会和定稿对不上');
    });

    test('四个图像模块只留 Vibe', () {
      // 角色参考、图生图、重绘是冲着某张具体的图、某个具体的角色配的,
      // 套到 AI 写的新画面上只会拧在一起;Vibe 管的是画风,套谁都成立。
      final withModules = canvas.copyWith(
        vibes: const [VibeItem(id: 'v1', name: 'style')],
        charRefs: const [CharRefItem(id: 'r1')],
        img2img: const Img2ImgConfig(strength: 0.5),
      );
      var i = 0;
      final s = proposalSendState(
        withModules,
        const DrawProposal(positive: '1girl'),
        newId: () => 'p${i++}',
      );
      expect(s.vibes.single.id, 'v1');
      expect(s.charRefs, isEmpty);
      expect(s.img2img, isNull);
      expect(s.inpaint, isNull);
    });

    test('尺寸、步数这些参数沿用创作页', () {
      final s = send(const DrawProposal(positive: '1girl'));
      expect(s.params.model, 'nai-diffusion-4-5-full');
      expect(s.params.width, 1216);
      expect(s.params.height, 832);
      expect(s.params.steps, 28);
    });

    test('坐标开关跟着 AI 这份走,不留画布上的旧值', () {
      // 画布开着坐标、AI 没摆位:沿用的话发出去的是几个默认空格,
      // 被模型当成用户指定的站位。
      expect(
        send(const DrawProposal(positive: '1girl')).params.useCoords,
        isFalse,
      );
      final placed = send(
        const DrawProposal(
          positive: '1girl',
          characters: [
            AgentCharacter(name: 'A', positive: 'a', position: '0.3000,0.5000'),
          ],
        ),
      );
      expect(placed.params.useCoords, isTrue);
      expect(placed.characters.single.position, '0.3000,0.5000');
    });

    test('AI 给了角色分区就原样用', () {
      final s = send(
        const DrawProposal(
          positive: '2girls',
          characters: [
            AgentCharacter(name: '芙兰', positive: 'flandre_scarlet'),
            AgentCharacter(name: '蕾米', positive: 'remilia_scarlet'),
          ],
        ),
      );
      expect(s.characters.map((c) => c.positive), [
        'flandre_scarlet',
        'remilia_scarlet',
      ]);
    });
  });

  group('回复里的代码', () {
    // 预设的写 tag 模式会把 tag 包进代码块,气泡原先是纯文本,
    // 用户看到的是字面的反引号,复制也复制不干净。
    test('围栏里的是代码块,语言标注不算内容', () {
      const raw =
          '查到了,就是这条喵~\n\n```text\nsakayori_iroha_(tsukuyomi)\n```\n\n别弄混了喵';
      expect(splitCodeFences(raw), [
        (text: '查到了,就是这条喵~', block: false),
        (text: 'sakayori_iroha_(tsukuyomi)', block: true),
        (text: '别弄混了喵', block: false),
      ]);
    });

    test('没有围栏就是一整段文字', () {
      expect(splitCodeFences('好的喵'), [(text: '好的喵', block: false)]);
    });

    test('没收尾的围栏:剩下的当代码,那串 tag 至少还能完整复制', () {
      expect(splitCodeFences('给你:\n```\n1girl, solo'), [
        (text: '给你:', block: false),
        (text: '1girl, solo', block: true),
      ]);
    });

    test('代码保留缩进和多行,只去掉首尾空行', () {
      expect(splitCodeFences('```\n\nchar1: a\n  char2: b\n\n```'), [
        (text: 'char1: a\n  char2: b', block: true),
      ]);
    });

    test('Windows 换行也认', () {
      expect(splitCodeFences('看:\r\n```text\r\nabc\r\n```\r\n'), [
        (text: '看:', block: false),
        (text: 'abc', block: true),
      ]);
    });

    test('行内反引号拆出来', () {
      expect(splitInlineCode('挂的是 `_(tsukuyomi)` 而不是作品名'), [
        (text: '挂的是 ', code: false),
        (text: '_(tsukuyomi)', code: true),
        (text: ' 而不是作品名', code: false),
      ]);
    });

    test('一行里写的三个反引号也当行内,不拆成一堆符号', () {
      expect(splitInlineCode('就是 ```miku``` 喵'), [
        (text: '就是 ', code: false),
        (text: 'miku', code: true),
        (text: ' 喵', code: false),
      ]);
    });

    test('落单的反引号原样留着', () {
      expect(splitInlineCode('这个 ` 是手滑'), [(text: '这个 ` 是手滑', code: false)]);
    });
  });

  group('提示词差异', () {
    // NAI5 的提示词是 tag 和句子混写的,句子里本来就有逗号。一律按逗号切的话,
    // 一句话碎成好几截:改一个词报出一串增删,弹层里还把半句话画成芯片。
    List<String> units(String s) => [for (final u in promptUnits(s)) u.text];

    test('纯 tag 串照旧按逗号切', () {
      expect(units('1girl, solo, long hair, 1.2::silver hair::'), [
        '1girl',
        'solo',
        'long hair',
        '1.2::silver hair::',
      ]);
    });

    test('一整句是一个单元,句子里的逗号不切', () {
      expect(
        units(
          'A girl sits on the windowsill, her knees drawn up. '
          'Rain streaks the glass, and grey light outlines her profile.',
        ),
        [
          'A girl sits on the windowsill, her knees drawn up.',
          'Rain streaks the glass, and grey light outlines her profile.',
        ],
      );
    });

    test('句子前头挂着的画师串、tag 还是一枚一枚的', () {
      expect(
        units(
          'artist:foo, 1girl, A girl sits by the window, rain on the glass.',
        ),
        [
          'artist:foo',
          '1girl',
          'A girl sits by the window, rain on the glass.',
        ],
      );
    });

    test('句号只是分隔的不算句子,tag 上的句号去掉', () {
      expect(
        units(
          '2girls, manga, monochrome. Read right to left, then top to bottom.',
        ),
        [
          '2girls',
          'manga',
          'monochrome',
          'Read right to left, then top to bottom.',
        ],
      );
    });

    test('一个句号都没有的混排,短句照旧是逗号分隔的成分', () {
      expect(
        units(
          '1girl, she sits on the windowsill, looking out at the rain, very aesthetic',
        ),
        [
          '1girl',
          'she sits on the windowsill',
          'looking out at the rain',
          'very aesthetic',
        ],
      );
    });

    test('小写开头的句子只合句末连着的长截,不把前面的 tag 吞进去', () {
      expect(
        units(
          '1girl, very aesthetic, soft light filters through the curtains, '
          'casting long shadows.',
        ),
        [
          '1girl',
          'very aesthetic',
          'soft light filters through the curtains, casting long shadows.',
        ],
      );
    });

    test('数里的点、夹在 tag 中间的问号叹号不是句末', () {
      expect(units('1.2::smile::, !?, ?, 1girl'), [
        '1.2::smile::',
        '!?',
        '?',
        '1girl',
      ]);
      expect(units('1girl, ?'), ['1girl', '?']);
    });

    test('单元的区间指回原文', () {
      const s = '1girl,  A girl sits by the window.\nRain streaks the glass.';
      for (final u in promptUnits(s)) {
        expect(s.substring(u.start, u.end), u.text);
      }
    });

    test('句子里改一个词是 +1 −1,不是一串', () {
      final d = diffPrompt(
        'A girl with long silver hair sits by the window, looking outside. '
            'Rain streaks the glass.',
        'A girl with long golden hair sits by the window, looking outside. '
            'Rain streaks the glass.',
      );
      expect(d.added.map((u) => u.text), [
        'A girl with long golden hair sits by the window, looking outside.',
      ]);
      expect(d.removed.map((u) => u.text), [
        'A girl with long silver hair sits by the window, looking outside.',
      ]);
    });

    test('只动了句首大小写、空白、句末标点,不算改', () {
      expect(
        diffPrompt(
          '1girl. She smiles at the viewer.',
          '1girl, she  smiles at the viewer',
        ).isEmpty,
        isTrue,
      );
    });

    test('改过的句子只标出改掉的词', () {
      const before = 'A girl with long silver hair sits by the window.';
      const after = 'A girl with long golden hair sits by the window.';
      final w = markChangedWords(diffPrompt(before, after));
      String cut(String s, List<(int, int)>? r) =>
          [for (final (a, b) in r!) s.substring(a, b)].join(' ');
      expect(cut(after, w.added.single), 'golden');
      expect(cut(before, w.removed.single), 'silver');
    });

    test('tag 数:一句话算一个,角色分区一并算上', () {
      expect(
        countTags(
          '1girl, solo. A girl sits by the window, rain on the glass.',
          ['silver hair, blue eyes', ''],
        ),
        5,
      );
    });

    test('历史列表的 tag 数和结果条同一个数法', () {
      AssistantMsg ai(
        String id, {
        DrawProposal? draw,
        AssistantChange? change,
      }) => AssistantMsg(
        id: id,
        role: MsgRole.ai,
        text: 'ok',
        at: 1,
        draw: draw,
        change: change,
      );
      const draw = DrawProposal(
        positive: '2girls. Two girls share an umbrella, walking in the rain.',
        characters: [AgentCharacter(name: 'A', positive: 'red hair, smile')],
      );
      expect(
        ArchivedSession(id: 1, at: 1, msgs: [ai('a', draw: draw)]).tagCount,
        4,
      );
      // 导入过的按写进创作页的那份数,关掉的角色不算
      final change = AssistantChange(
        before: const PromptSnapshot(),
        after: PromptSnapshot(
          positive: 'a, b',
          characters: [
            CharacterPrompt(id: '1', name: 'A', positive: 'c'),
            CharacterPrompt(id: '2', name: 'B', positive: 'd', enabled: false),
          ],
        ),
      );
      expect(
        ArchivedSession(
          id: 1,
          at: 1,
          msgs: [ai('a', draw: draw, change: change)],
        ).tagCount,
        3,
      );
    });

    test('对不上的句子不配对,整句都算新写的', () {
      final w = markChangedWords(
        diffPrompt(
          'A girl sits by the window.',
          'Neon signs flicker over a wet street at night.',
        ),
      );
      expect(w.added.single, isNull);
      expect(w.removed.single, isNull);
    });
  });

  group('差异基线', () {
    // 结果条上那对读数说的是「AI 这轮相对上轮改了什么」,和创作页无关。
    // 原先未导入时拿当前画布当基线,新对话里会凭空算出一堆「移除」——
    // 那些词 AI 根本没见过。
    const d1 = DrawProposal(positive: 'a, b');
    const d2 = DrawProposal(positive: 'a, c');

    AssistantMsg ai(String id, {DrawProposal? draw}) =>
        AssistantMsg(id: id, role: MsgRole.ai, text: 'ok', at: 1, draw: draw);

    test('取上一份提议,不是上一条消息', () {
      final msgs = [
        ai('a1', draw: d1),
        const AssistantMsg(id: 'u1', role: MsgRole.user, text: '再聊聊', at: 1),
        ai('a2'), // 纯聊天轮,没出图
        const AssistantMsg(id: 'u2', role: MsgRole.user, text: '改一下', at: 1),
        ai('a3', draw: d2),
      ];
      expect(prevProposal(msgs, 'a3'), same(d1));
    });

    test('第一份提议没有上一轮', () {
      expect(prevProposal([ai('a1', draw: d1)], 'a1'), isNull);
    });

    test('认不出的 id 当没有', () {
      expect(prevProposal([ai('a1', draw: d1)], 'nope'), isNull);
    });

    test('只往前找,不会捞到后面那份', () {
      final msgs = [ai('a1', draw: d1), ai('a2', draw: d2)];
      expect(prevProposal(msgs, 'a1'), isNull);
      expect(prevProposal(msgs, 'a2'), same(d1));
    });
  });

  group('沿用资源账本', () {
    // 预匹配是逐条消息做的:用户这轮没再提「A1」,[画师串] 块就不出现,画风的出处
    // 断在那儿 —— 下一句「换个姿势」模型就不知道该保留哪串了。账本由服务端算、
    // 按「还在不在这幅画里」筛,客户端负责存和回传(这条链路没有服务端会话)。
    const ledger = {
      'artist': {'A1': 'wlop, as109'},
      'oc': {'OC_小星': 'star hair ornament'},
    };

    test('挂在最新那条 AI 消息上', () {
      final msgs = [
        const AssistantMsg(id: 'u1', role: MsgRole.user, text: '画', at: 1),
        const AssistantMsg(
          id: 'a1',
          role: MsgRole.ai,
          text: 'ok',
          at: 1,
          resources: ledger,
        ),
        const AssistantMsg(id: 'u2', role: MsgRole.user, text: '再改', at: 1),
      ];
      // 末尾那条是用户消息,得往前找到 AI 那条
      expect(latestResources(msgs)['artist'], {'A1': 'wlop, as109'});
    });

    test('一轮都没跑过就是空的', () {
      expect(latestResources(const []), isEmpty);
      expect(
        latestResources(const [
          AssistantMsg(id: 'u1', role: MsgRole.user, text: '画', at: 1),
        ]),
        isEmpty,
      );
    });

    test('取的是最新那条,不是最早那条', () {
      final msgs = [
        const AssistantMsg(
          id: 'a1',
          role: MsgRole.ai,
          text: 'ok',
          at: 1,
          resources: ledger,
        ),
        const AssistantMsg(id: 'a2', role: MsgRole.ai, text: 'ok', at: 2),
      ];
      // 后一轮把画风换掉了(服务端筛完是空的),就该跟着空
      expect(latestResources(msgs), isEmpty);
    });

    test('存得下也读得回来', () {
      const m = AssistantMsg(
        id: 'a1',
        role: MsgRole.ai,
        text: 'ok',
        at: 1,
        resources: ledger,
      );
      final back = AssistantMsg.fromJson(m.toJson());
      expect(back.resources['artist'], {'A1': 'wlop, as109'});
      expect(back.resources['oc'], {'OC_小星': 'star hair ornament'});
    });

    test('形状不对当空,别让整段会话打不开', () {
      expect(decodeResources(null), isEmpty);
      expect(decodeResources('nope'), isEmpty);
      expect(decodeResources(const {'artist': 'nope'}), isEmpty);
      // 空槽不留,免得回传一堆空对象
      expect(decodeResources(const {'artist': {}}), isEmpty);
    });

    test('老存档没这个字段,读成空', () {
      expect(
        AssistantMsg.fromJson(const {
          'id': 'a1',
          'role': 'ai',
          'text': 'ok',
          'at': 1,
        }).resources,
        isEmpty,
      );
    });
  });

  group('对话模式', () {
    test('记在用户消息上,存得下也读得回来;老存档没这个字段读成正常', () {
      const m = AssistantMsg(
        id: 'u1',
        role: MsgRole.user,
        text: '画个四格',
        at: 1,
        mode: AssistantMode.comic,
      );
      expect(AssistantMsg.fromJson(m.toJson()).mode, AssistantMode.comic);
      // 正常模式不写字段,老存档读回来一个样
      const plain = AssistantMsg(
        id: 'u2',
        role: MsgRole.user,
        text: 'x',
        at: 1,
      );
      expect(plain.toJson().containsKey('mode'), isFalse);
      expect(
        AssistantMsg.fromJson(const {
          'id': 'u3',
          'role': 'user',
          'text': 'x',
          'at': 1,
          'mode': 'nope',
        }).mode,
        AssistantMode.normal,
      );
    });

    test('一段对话的模式取最后一条用户消息的:中途换过就以换完的为准', () {
      expect(conversationMode(const []), AssistantMode.normal);
      final msgs = [
        const AssistantMsg(
          id: 'u1',
          role: MsgRole.user,
          text: 'a',
          at: 1,
          mode: AssistantMode.comic,
        ),
        const AssistantMsg(id: 'a1', role: MsgRole.ai, text: 'ok', at: 2),
        const AssistantMsg(
          id: 'u2',
          role: MsgRole.user,
          text: 'b',
          at: 3,
          mode: AssistantMode.natural,
        ),
        const AssistantMsg(id: 'e1', role: MsgRole.error, text: '断了', at: 4),
      ];
      expect(conversationMode(msgs), AssistantMode.natural);
    });

    test('纯文本格式记在回复上,和模式互不相干;存得下,早先当成模式存的也认', () {
      const m = AssistantMsg(
        id: 'a1',
        role: MsgRole.ai,
        text: 'ok',
        at: 1,
        mode: AssistantMode.comic,
        noDraw: true,
      );
      final back = AssistantMsg.fromJson(m.toJson());
      expect((back.mode, back.noDraw), (AssistantMode.comic, true));
      const off = AssistantMsg(id: 'a2', role: MsgRole.ai, text: 'x', at: 1);
      expect(off.toJson().containsKey('noDraw'), isFalse);
      final legacy = AssistantMsg.fromJson(const {
        'id': 'u3',
        'role': 'user',
        'text': 'x',
        'at': 1,
        'mode': 'noDraw',
      });
      expect((legacy.mode, legacy.noDraw), (AssistantMode.normal, true));
    });

    test('开新对话回到正常', () async {
      final stores = AppStores.ephemeral();
      final c = ProviderContainer(
        overrides: [appStoresProvider.overrideWithValue(stores)],
      );
      addTearDown(() async {
        c.dispose();
        stores.flushNow();
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      final n = c.read(assistantProvider.notifier);
      expect(c.read(assistantProvider).mode, AssistantMode.normal);
      n.setMode(AssistantMode.comic);
      expect(c.read(assistantProvider).mode, AssistantMode.comic);
      n.archiveCurrent();
      expect(c.read(assistantProvider).mode, AssistantMode.normal);
    });

    const draw = DrawProposal(
      positive: '2girls, park',
      negative: 'lowres',
      characters: [
        AgentCharacter(name: '芙兰', positive: 'flandre scarlet, smile'),
        AgentCharacter(
          name: '蕾米',
          positive: 'remilia scarlet',
          negative: 'hat',
        ),
      ],
    );

    test('纯文本格式那一轮的提议显示成纯文本;看的是那一轮开没开,不是现在的开关', () {
      const noDraw = AssistantMsg(
        id: 'a1',
        role: MsgRole.ai,
        text: 'ok',
        at: 1,
        draw: draw,
        noDraw: true,
      );
      expect(noDraw.promptAsText, isTrue);
      // 存盘读回来还是纯文本那种
      expect(AssistantMsg.fromJson(noDraw.toJson()).promptAsText, isTrue);
      // 正常模式的照常出卡;没有提议的纯聊天轮无所谓显示成什么
      const normal = AssistantMsg(
        id: 'a2',
        role: MsgRole.ai,
        text: 'ok',
        at: 1,
        draw: draw,
      );
      expect(normal.promptAsText, isFalse);
      const chat = AssistantMsg(
        id: 'a3',
        role: MsgRole.ai,
        text: 'ok',
        at: 1,
        noDraw: true,
      );
      expect(chat.promptAsText, isFalse);
    });

    test('纯文本写法:全局正向在前,角色一行一个 charN:,角色负向跟在后面,全局负向单列', () {
      final t = promptTextOf(draw);
      expect(
        t.positive,
        '2girls, park\n'
        'char1: flandre scarlet, smile\n'
        'char2: remilia scarlet\n'
        '[char2-] hat',
      );
      expect(t.negative, 'lowres');
      // 和法典 / web 的 charN 解析器是同一套写法:复制出去再贴回来,角色拆得开
      final back = splitCodexCharacters(t.positive);
      expect(back.base, '2girls, park');
      expect(
        [for (final c in back.characters) c.positive],
        ['flandre scarlet, smile', 'remilia scarlet'],
      );
      expect(back.characters[1].negative, 'hat');
      // 单角色场景没有 characters,就只有正向那一行
      expect(
        promptTextOf(const DrawProposal(positive: '1girl')).positive,
        '1girl',
      );
    });
  });

  group('画师串标记', () {
    // 发了 web_artists 的那些轮,服务端会把正向词里认出来的画师串包成
    // <<artist:名字:内容>> 给 web 渲染芯片。app 不渲染芯片,不剥就把尖括号
    // 原样写进用户的提示词。
    test('剥掉包装只留内容', () {
      expect(
        stripArtistMarkers('1girl, <<artist:A1:wlop, as109>>, smile'),
        '1girl, wlop, as109, smile',
      );
    });

    test('一行里多颗都要剥', () {
      expect(
        stripArtistMarkers('<<artist:A1:aaa>>, <<artist:B2:bbb>>'),
        'aaa, bbb',
      );
    });

    test('内容里带权重语法也不能吃掉', () {
      // 画师串里 `1.2::tag::` 这种写法很常见,冒号不能把正则截断
      expect(
        stripArtistMarkers('<<artist:A1:1.2::wlop::, as109>>'),
        '1.2::wlop::, as109',
      );
    });

    test('没有标记就原样返回', () {
      const raw = '1girl, solo, looking at viewer';
      expect(stripArtistMarkers(raw), raw);
    });

    test('用户自己写的尖括号不能被当成标记吃掉', () {
      const raw = 'a << b, c >> d';
      expect(stripArtistMarkers(raw), raw);
    });
  });

  group('画师串占位符(自定义接口那条)', () {
    const a1 = '[[artist:as109]],{{artist:wlop}},1.3::artist:hiten::';
    const tokens = {'__ARTIST_A1__': a1, '__ARTIST_厚涂_风__': 'artist:rella'};

    test('画布和历史里逐字相同的画师串折成占位符,改过的不动', () {
      expect(
        collapseArtistStrings('positive: $a1, 1girl', tokens),
        'positive: __ARTIST_A1__, 1girl',
      );
      const edited = 'positive: [[artist:as109]], 1girl';
      expect(collapseArtistStrings(edited, tokens), edited);
    });

    test('服务端没还原成时本地兜底:认得的换回,写歪的也认,认不出的删掉', () {
      expect(
        expandArtistTokens('1.2::__ARTIST_A1__::, 1girl', tokens),
        '1.2::$a1::, 1girl',
      );
      expect(
        expandArtistTokens('__artist_a1__, __ARTIST_厚涂_风__, smile', tokens),
        '$a1, artist:rella, smile',
      );
      expect(expandArtistTokens('__ARTIST_C3__, 1girl', tokens), '1girl');
      expect(expandArtistTokens('1girl, smile', tokens), '1girl, smile');
    });

    test('正文里的占位符换成名字', () {
      expect(artistTokensToNames('用了 __ARTIST_A1__ 的画风'), '用了 A1 的画风');
    });

    test('本地库的画师按服务端同一种起名列出来,兜底能认工具查到的本地画师', () {
      final lib = libraryArtistTokens([
        {'id': '厚涂 风', 'name': '厚涂 风', 'prompt': 'artist:rella'},
        {'id': 'B2', 'name': 'B2', 'prompt': ''},
      ]);
      expect(lib, {'__ARTIST_厚涂_风__': 'artist:rella'});
      expect(
        expandArtistTokens('__ARTIST_厚涂_风__, 1girl', lib),
        'artist:rella, 1girl',
      );
    });
  });

  group('直连回复解析', () {
    // 模型写坏围栏的花样很多,而写坏的表现是「这轮没出图」——和「模型决定不出图」
    // 长得一模一样,不钉住根本分不出来。
    test('正文 + nai_draw 围栏', () {
      final r = parseDirectReply(
        '好耶,画一张芙兰喵~\n'
        '```nai_draw\n'
        '{"positive": "1girl, flandre_scarlet", "negative": "bad hands"}\n'
        '```',
      );
      expect(r.reply, '好耶,画一张芙兰喵~');
      expect(r.draw!['positive'], '1girl, flandre_scarlet');
    });

    test('<Think> 段要剥掉,不能发给用户', () {
      final r = parseDirectReply('<Think>先查一下</Think>\n好的喵~');
      expect(r.reply, '好的喵~');
    });

    test('写了两版围栏时以最后一版为准', () {
      final r = parseDirectReply(
        '```nai_draw\n{"positive": "a"}\n```\n'
        '改一下\n'
        '```nai_draw\n{"positive": "b"}\n```',
      );
      expect(r.draw!['positive'], 'b');
    });

    test('围栏里不是合法 JSON:当这轮没出图,正文照发', () {
      final r = parseDirectReply('在想喵\n```nai_draw\n{坏了\n```');
      expect(r.draw, isNull);
      expect(r.reply, '在想喵');
    });

    test('纯聊天轮没有围栏', () {
      final r = parseDirectReply('这串 tag 挺好的喵');
      expect(r.draw, isNull);
      expect(r.reply, '这串 tag 挺好的喵');
    });
  });

  group('直连工具调用解析', () {
    test('一条回复里多个 tool_call 都要认出来', () {
      final calls = parseToolCalls(
        '我查一下喵\n'
        '```tool_call\n'
        '{"name": "search_character", "arguments": {"query": "芙兰"}}\n'
        '```\n'
        '```tool_call\n'
        '{"name": "search_artist", "arguments": {"keyword": "wlop"}}\n'
        '```',
      );
      expect(
        [for (final c in calls) c.name],
        ['search_character', 'search_artist'],
      );
      expect(calls.first.args['query'], '芙兰');
    });

    test('坏掉的那一块跳过,别的照常执行', () {
      final calls = parseToolCalls(
        '```tool_call\n{坏了\n```\n'
        '```tool_call\n'
        '{"name": "lookup_tag", "arguments": {"query": "halo"}}\n'
        '```',
      );
      expect(calls.length, 1);
      expect(calls.single.name, 'lookup_tag');
    });

    test('没有 name 的不算一次调用', () {
      expect(parseToolCalls('```tool_call\n{"arguments": {}}\n```'), isEmpty);
    });

    test('没写围栏就是没调工具', () {
      expect(parseToolCalls('直接给你写好了喵'), isEmpty);
    });
  });

  group('直连响应取正文', () {
    // 三家的取文字段各不相同,认错的表现是「模型回了一段空的」,
    // 和真的空回长得一样。
    test('OpenAI:choices[0].message.content', () {
      expect(
        extractReplyText(AgentApiFormat.openai, const {
          'choices': [
            {
              'message': {'content': '喵'},
            },
          ],
        }),
        '喵',
      );
    });

    test('Google:candidates[0].content.parts[].text,要拼起来', () {
      expect(
        extractReplyText(AgentApiFormat.google, const {
          'candidates': [
            {
              'content': {
                'parts': [
                  {'text': '喵'},
                  {'text': '呜'},
                ],
              },
            },
          ],
        }),
        '喵呜',
      );
    });

    test('Anthropic:content[] 里只取 type=text 那几段', () {
      expect(
        extractReplyText(AgentApiFormat.anthropic, const {
          'content': [
            {'type': 'thinking', 'thinking': '不该拿这段'},
            {'type': 'text', 'text': '喵'},
          ],
        }),
        '喵',
      );
    });

    test('形状不对返回空串,不崩', () {
      for (final f in AgentApiFormat.values) {
        expect(extractReplyText(f, null), '');
        expect(extractReplyText(f, const {}), '');
      }
    });
  });

  group('直连请求体:附图', () {
    // 三家的图片字段各不相同,写错的表现是「模型说没看到图」,
    // 和它自己看走眼分不出来。
    CustomEndpoint ep(AgentApiFormat f) => CustomEndpoint(
      id: 'e',
      name: '',
      format: f,
      baseUrl: '',
      apiKey: 'k',
      model: 'm',
    );
    const img = (mime: 'image/jpeg', data: 'QUJD');
    List<DirectMsg> msgs({DirectImage? image, String text = '画个芙兰'}) => [
      (role: 'user', content: '上一轮', image: null),
      (role: 'assistant', content: '好的', image: null),
      (role: 'user', content: text, image: image),
    ];
    Map<String, dynamic> body(AgentApiFormat f, List<DirectMsg> m) =>
        directRequest(ep(f), system: 'sys', msgs: m, think: ThinkLevel.auto).$2;

    test('OpenAI:content 换成分段,图在前,data URL', () {
      final m =
          body(AgentApiFormat.openai, msgs(image: img))['messages'] as List;
      expect(m[1], {'role': 'user', 'content': '上一轮'}, reason: '没图的仍是字符串');
      expect(m.last, {
        'role': 'user',
        'content': [
          {
            'type': 'image_url',
            'image_url': {'url': 'data:image/jpeg;base64,QUJD'},
          },
          {'type': 'text', 'text': '画个芙兰'},
        ],
      });
    });

    test('Gemini:inlineData 在前,text 在后', () {
      final c =
          body(AgentApiFormat.google, msgs(image: img))['contents'] as List;
      expect(c.last['parts'], [
        {
          'inlineData': {'mimeType': 'image/jpeg', 'data': 'QUJD'},
        },
        {'text': '画个芙兰'},
      ]);
    });

    test('Claude:base64 的 image 块在前', () {
      final m =
          body(AgentApiFormat.anthropic, msgs(image: img))['messages'] as List;
      expect(m.last['content'], [
        {
          'type': 'image',
          'source': {
            'type': 'base64',
            'media_type': 'image/jpeg',
            'data': 'QUJD',
          },
        },
        {'type': 'text', 'text': '画个芙兰'},
      ]);
    });

    test('只发图不打字:不塞空的文字段(Claude 会拒空 text 块)', () {
      for (final f in AgentApiFormat.values) {
        final raw = jsonEncode(body(f, msgs(image: img, text: '')));
        expect(raw, isNot(contains('"text":""')), reason: f.name);
        expect(raw, contains('QUJD'), reason: f.name);
      }
    });

    test('不带图:和原来一样', () {
      expect((body(AgentApiFormat.openai, msgs())['messages'] as List).last, {
        'role': 'user',
        'content': '画个芙兰',
      });
      expect(
        (body(AgentApiFormat.google, msgs())['contents'] as List).last['parts'],
        [
          {'text': '画个芙兰'},
        ],
      );
      expect(
        (body(AgentApiFormat.anthropic, msgs())['messages'] as List).last,
        {'role': 'user', 'content': '画个芙兰'},
      );
    });

    test('图片类型按文件头认,认不出按 PNG', () {
      Uint8List head(List<int> b) =>
          Uint8List.fromList([...b, ...List.filled(16, 0)]);
      expect(imageMimeOf(head([0x89, 0x50, 0x4E, 0x47])), 'image/png');
      expect(imageMimeOf(head([0xFF, 0xD8, 0xFF, 0xE0])), 'image/jpeg');
      expect(
        imageMimeOf(
          head([...'RIFF'.codeUnits, 0, 0, 0, 0, ...'WEBP'.codeUnits]),
        ),
        'image/webp',
      );
      expect(imageMimeOf(head('GIF89a'.codeUnits)), 'image/gif');
      expect(imageMimeOf(Uint8List(0)), 'image/png');
    });

    test('没超大小的图原样发,不转码', () async {
      final jpg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 1, 2, 3]);
      final r = await prepareDirectImage(jpg);
      expect(r.mime, 'image/jpeg');
      expect(base64Decode(r.data), jpg);
    });
  });

  group('助手设置', () {
    test('默认:自动的一律关着,资料库取窄的那一档', () {
      const d = AssistantSettings();
      expect(d.autoGenerate, isFalse);
      expect(d.inlineImage, isFalse);
      expect(d.autoImport, isFalse);
      // 公共库上万条画师串,默认并进去等于把预匹配的准头让出去
      expect(d.libraryScope, LibraryScope.local);
    });

    test('存得下也读得回来', () {
      const s = AssistantSettings(
        autoGenerate: true,
        libraryScope: LibraryScope.all,
        thinkLevel: ThinkLevel.high,
      );
      final back = AssistantSettings.fromJson(s.toJson());
      expect(back.autoGenerate, isTrue);
      expect(back.libraryScope, LibraryScope.all);
      expect(back.thinkLevel, ThinkLevel.high);
    });

    test('老存档没这个字段,回落本地库', () {
      expect(
        AssistantSettings.fromJson(const {'autoGenerate': true}).libraryScope,
        LibraryScope.local,
      );
      // 认不出的值也一样,别让一个脏字段把设置页读崩
      expect(
        AssistantSettings.fromJson(const {'libraryScope': 'nope'}).libraryScope,
        LibraryScope.local,
      );
    });

    test('没有 Bot 授权选不了公共库,已经选着的按本地库算', () {
      for (final s in LibraryScope.values) {
        expect(libraryScopeAllowed(s, botAuthorized: true), isTrue);
      }
      expect(
        libraryScopeAllowed(LibraryScope.all, botAuthorized: false),
        isFalse,
      );
      expect(
        libraryScopeAllowed(LibraryScope.local, botAuthorized: false),
        isTrue,
      );
      expect(
        effectiveLibraryScope(LibraryScope.all, botAuthorized: false),
        LibraryScope.local,
      );
      expect(
        effectiveLibraryScope(LibraryScope.none, botAuthorized: false),
        LibraryScope.none,
      );
      expect(
        effectiveLibraryScope(LibraryScope.all, botAuthorized: true),
        LibraryScope.all,
      );
    });

    test('落盘存的是名字不是序号', () {
      // 将来在中间插一档,老存档不会串位
      expect(
        const AssistantSettings(
          libraryScope: LibraryScope.all,
        ).toJson()['libraryScope'],
        'all',
      );
    });

    test('由窄到宽:菜单顺序就是这个', () {
      expect(LibraryScope.values, [
        LibraryScope.none,
        LibraryScope.local,
        LibraryScope.all,
      ]);
    });

    test('发给服务端的就是枚举名', () {
      // 「不使用」这一档**必须显式发** —— 光不发库的话服务端会回落公共库,
      // 恰好和用户要的相反,所以这个取值不能错。
      expect(libraryScopeWire(LibraryScope.none), 'none');
      expect(libraryScopeWire(LibraryScope.local), 'local');
      expect(libraryScopeWire(LibraryScope.all), 'all');
    });
  });

  group('思考等级', () {
    // 三家的旋钮完全不是一回事:OpenAI 给档位字符串,另外两家要 token 预算。
    // 发错字段的表现是「请求被拒」或者「悄悄没生效」,两种都难查。
    test('滑杆顺序:关 → 自动 → 由低到高', () {
      expect(ThinkLevel.values, [
        ThinkLevel.off,
        ThinkLevel.auto,
        ThinkLevel.low,
        ThinkLevel.medium,
        ThinkLevel.high,
        ThinkLevel.ultra,
      ]);
    });

    test('自动档一个字段都不发', () {
      for (final f in AgentApiFormat.values) {
        expect(thinkFields(f, ThinkLevel.auto), isEmpty);
      }
    });

    test('OpenAI:reasoning_effort 档位字符串,两头各自封顶', () {
      expect(thinkFields(AgentApiFormat.openai, ThinkLevel.low), {
        'reasoning_effort': 'low',
      });
      // 它没有「关」,minimal 是最低;也没有「超高」,high 是最高
      expect(thinkFields(AgentApiFormat.openai, ThinkLevel.off), {
        'reasoning_effort': 'minimal',
      });
      expect(
        thinkFields(AgentApiFormat.openai, ThinkLevel.ultra),
        thinkFields(AgentApiFormat.openai, ThinkLevel.high),
      );
    });

    test('Gemini:thinkingBudget,关掉是 0 而不是不发', () {
      int budget(ThinkLevel l) {
        final f = thinkFields(AgentApiFormat.google, l);
        final cfg = (f['generationConfig'] as Map)['thinkingConfig'] as Map;
        return cfg['thinkingBudget'] as int;
      }

      expect(budget(ThinkLevel.off), 0);
      // 越往上给得越多,而且真的要递增 —— 两档撞在一起等于白给一档
      expect(budget(ThinkLevel.low), lessThan(budget(ThinkLevel.medium)));
      expect(budget(ThinkLevel.medium), lessThan(budget(ThinkLevel.high)));
      expect(budget(ThinkLevel.high), lessThan(budget(ThinkLevel.ultra)));
    });

    test('Claude:关 = 不带 thinking 字段;开着预算不低于 1024 且递增', () {
      expect(thinkFields(AgentApiFormat.anthropic, ThinkLevel.off), isEmpty);
      var prev = 0;
      for (final l in [
        ThinkLevel.low,
        ThinkLevel.medium,
        ThinkLevel.high,
        ThinkLevel.ultra,
      ]) {
        final t = thinkFields(AgentApiFormat.anthropic, l)['thinking'] as Map;
        expect(t['type'], 'enabled');
        final b = t['budget_tokens'] as int;
        // Anthropic 自己规定的下限
        expect(b, greaterThanOrEqualTo(1024));
        expect(b, greaterThan(prev));
        prev = b;
      }
    });

    test('存得下也读得回来,老存档自动档', () {
      const s = AssistantSettings(thinkLevel: ThinkLevel.ultra);
      expect(
        AssistantSettings.fromJson(s.toJson()).thinkLevel,
        ThinkLevel.ultra,
      );
      expect(AssistantSettings.fromJson(const {}).thinkLevel, ThinkLevel.auto);
      // 认不出的值回落自动,不能瞎选一档替用户花钱
      expect(
        AssistantSettings.fromJson(const {'thinkLevel': 'wat'}).thinkLevel,
        ThinkLevel.auto,
      );
    });
  });

  group('自定义接口', () {
    // 三家的模型列表字段各不相同,而**认错字段的表现是「列表空着」**,
    // 和网络失败长得一模一样 —— 不钉住的话根本分不出是哪一头的问题。
    test('OpenAI:data[].id', () {
      expect(
        parseModelList(AgentApiFormat.openai, const {
          'data': [
            {'id': 'gpt-4o'},
            {'id': 'o3-mini'},
          ],
        }),
        ['gpt-4o', 'o3-mini'],
      );
    });

    test('Google:models[].name,要把 models/ 前缀剥掉', () {
      expect(
        parseModelList(AgentApiFormat.google, const {
          'models': [
            {'name': 'models/gemini-3.7-flash'},
            {'name': 'models/gemini-3.1-flash-lite'},
          ],
        }),
        ['gemini-3.1-flash-lite', 'gemini-3.7-flash'],
      );
    });

    test('Anthropic:也是 data[].id', () {
      expect(
        parseModelList(AgentApiFormat.anthropic, const {
          'data': [
            {'id': 'claude-sonnet-4-6'},
          ],
        }),
        ['claude-sonnet-4-6'],
      );
    });

    test('形状不对就空表,不崩', () {
      expect(parseModelList(AgentApiFormat.openai, null), isEmpty);
      expect(parseModelList(AgentApiFormat.openai, const {}), isEmpty);
      expect(
        parseModelList(AgentApiFormat.openai, const {'data': 'nope'}),
        isEmpty,
      );
      expect(
        parseModelList(AgentApiFormat.openai, const {
          'data': ['x', 3],
        }),
        isEmpty,
      );
    });

    test('去重', () {
      expect(
        parseModelList(AgentApiFormat.openai, const {
          'data': [
            {'id': 'a'},
            {'id': 'a'},
          ],
        }),
        ['a'],
      );
    });

    test('基址留空用各家默认,末尾斜杠一律削掉', () {
      const e = CustomEndpoint(
        id: 'x',
        name: '',
        format: AgentApiFormat.openai,
        baseUrl: '',
        apiKey: 'k',
        model: 'gpt-4o',
      );
      expect(e.effectiveBase, 'https://api.openai.com/v1');
      expect(
        e.copyWith(baseUrl: 'http://localhost:8080/v1//').effectiveBase,
        'http://localhost:8080/v1',
      );
      // 名字留空就显示模型名 —— 列表里一行空白最难认
      expect(e.displayName, 'gpt-4o');
      expect(e.copyWith(name: '我的中转').displayName, '我的中转');
    });

    test('接口路径:留空用各家默认,Gemini 那条要把模型名替进去', () {
      const base = CustomEndpoint(
        id: 'x',
        name: '',
        format: AgentApiFormat.openai,
        baseUrl: '',
        apiKey: 'k',
        model: 'gpt-4o',
      );
      expect(base.effectivePath, '/chat/completions');
      expect(
        base.chatUri.toString(),
        'https://api.openai.com/v1/chat/completions',
      );

      final g = base.copyWith(
        format: AgentApiFormat.google,
        model: 'gemini-3.7-flash',
      );
      expect(g.effectivePath, '/models/gemini-3.7-flash:generateContent');

      final a = base.copyWith(format: AgentApiFormat.anthropic);
      expect(a.effectivePath, '/messages');
    });

    test('自己填的路径:开头没斜杠也补上,{model} 照样替换', () {
      const e = CustomEndpoint(
        id: 'x',
        name: '',
        format: AgentApiFormat.openai,
        baseUrl: 'http://localhost:8080',
        apiKey: 'k',
        model: 'qwen',
        apiPath: 'v1/chat/{model}',
      );
      expect(e.effectivePath, '/v1/chat/qwen');
      expect(e.chatUri.toString(), 'http://localhost:8080/v1/chat/qwen');
    });

    test('路径存得下也读得回来,空的不落盘', () {
      const e = CustomEndpoint(
        id: 'x',
        name: '',
        format: AgentApiFormat.openai,
        baseUrl: '',
        apiKey: 'k',
        model: 'm',
      );
      expect(e.toJson().containsKey('apiPath'), isFalse);
      expect(
        CustomEndpoint.fromJson(e.copyWith(apiPath: '/x').toJson())!.apiPath,
        '/x',
      );
    });

    test('缺 key 或缺模型都算没填全', () {
      const base = CustomEndpoint(
        id: 'x',
        name: '',
        format: AgentApiFormat.openai,
        baseUrl: '',
        apiKey: 'k',
        model: 'm',
      );
      expect(base.usable, isTrue);
      expect(base.copyWith(apiKey: ' ').usable, isFalse);
      expect(base.copyWith(model: '').usable, isFalse);
    });

    test('存得下也读得回来,坏条目跳过', () {
      const e = CustomEndpoint(
        id: 'x',
        name: 'n',
        format: AgentApiFormat.google,
        baseUrl: 'https://h/v1',
        apiKey: 'k',
        model: 'm',
      );
      final back = CustomEndpoint.fromJson(e.toJson())!;
      expect(back.format, AgentApiFormat.google);
      expect(back.baseUrl, 'https://h/v1');
      expect(back.model, 'm');
      // 没有 id 的一律丢掉:它是替换和删除的唯一依据
      expect(CustomEndpoint.fromJson(const {'name': 'x'}), isNull);
      expect(CustomEndpoint.fromJson('nope'), isNull);
      // 认不出的格式回落 OpenAI 兼容,那是最常见的一种
      expect(
        CustomEndpoint.fromJson(const {'id': 'y', 'format': 'wat'})!.format,
        AgentApiFormat.openai,
      );
    });
  });

  group('模型门禁', () {
    // Anima / Krea 的提示词体系与 NAI 是两套,助手的预设、工具、nai_draw 围栏
    // 全是按 NAI 写的。硬跑出得来东西,但对那两个模型基本等于没写。
    test('NAI 两条线放行', () {
      expect(assistantSupportsModel('NAI 4.5 Full'), isTrue);
      expect(assistantSupportsModel('NAI 5 Full'), isTrue);
      expect(assistantSupportsModel(''), isTrue);
    });

    test('Anima / Krea 挡住', () {
      expect(assistantSupportsModel('Anima'), isFalse);
      expect(assistantSupportsModel('Krea 2'), isFalse);
    });
  });

  group('助手设置', () {
    // 三项都是「把手动改成自动」,所以**默认必须全关** —— 谁都不该在没开过
    // 开关的情况下发现 AI 自己动了画布、自己花了点数。
    test('默认全关', () {
      const s = AssistantSettings();
      expect(s.autoGenerate, isFalse);
      expect(s.inlineImage, isFalse);
      expect(s.autoImport, isFalse);
      expect(s.noDraw, isFalse);
      expect(s.introDone, isFalse, reason: '首次引导没走过就得弹');
    });

    test('存得下也读得回来', () {
      const s = AssistantSettings(
        autoGenerate: true,
        inlineImage: true,
        autoImport: true,
        noDraw: true,
        introVersion: kAssistantIntroVersion,
      );
      final back = AssistantSettings.fromJson(s.toJson());
      expect(back.autoGenerate, isTrue);
      expect(back.inlineImage, isTrue);
      expect(back.autoImport, isTrue);
      expect(back.noDraw, isTrue);
      expect(back.introDone, isTrue);
      // 引导改过版,走过旧版的也得再看一次
      expect(
        const AssistantSettings(
          introVersion: kAssistantIntroVersion - 1,
        ).introDone,
        isFalse,
      );
    });

    test('老存档缺字段一律当关 —— 不能因为读不到就替用户开了', () {
      final s = AssistantSettings.fromJson(const {});
      expect(s.autoGenerate, isFalse);
      expect(s.inlineImage, isFalse);
      expect(s.autoImport, isFalse);
      expect(s.noDraw, isFalse);
      // 值不是 bool 也不能当真
      expect(
        AssistantSettings.fromJson(const {'autoGenerate': 'yes'}).autoGenerate,
        isFalse,
      );
    });

    test('老存档的 alwaysCanvas 只继承「自动导入」那一半', () {
      // 这一项原来叫「总是读写创作页」,读画布那一半已经撤了(两个方向常开会
      // 互相咬:自动写进去的词下一轮又被自动读回来当基底)。老存档里开着的,
      // 保留写那一半。
      expect(
        AssistantSettings.fromJson(const {'alwaysCanvas': true}).autoImport,
        isTrue,
      );
      expect(
        AssistantSettings.fromJson(const {'alwaysCanvas': false}).autoImport,
        isFalse,
      );
      // 新名字优先,但两个键都不认就还是关
      expect(
        AssistantSettings.fromJson(const {'autoImport': true}).autoImport,
        isTrue,
      );
    });

    test('copyWith 只动指定的那一项', () {
      const s = AssistantSettings(autoImport: true);
      final n = s.copyWith(autoGenerate: true);
      expect(n.autoGenerate, isTrue);
      expect(n.autoImport, isTrue, reason: '没提到的项不该被顺手关掉');
      expect(n.inlineImage, isFalse);
    });

    test('消息字号:默认比正文大一号,存得下读得回来,越界夹回范围', () {
      expect(const AssistantSettings().fontSize, 15);
      expect(AssistantSettings.fromJson(const {}).fontSize, 15);
      expect(
        AssistantSettings.fromJson(
          const AssistantSettings(fontSize: 18).toJson(),
        ).fontSize,
        18,
      );
      expect(
        AssistantSettings.fromJson(const {'fontSize': 99}).fontSize,
        AssistantSettings.fontSizeMax,
      );
      expect(
        AssistantSettings.fromJson(const {'fontSize': 'big'}).fontSize,
        AssistantSettings.fontSizeDefault,
      );
    });

    test('上下文轮数:默认 20 与服务端一致,存得下读得回来,越界夹回范围', () {
      expect(const AssistantSettings().historyTurns, 20);
      expect(AssistantSettings.fromJson(const {}).historyTurns, 20);
      expect(
        AssistantSettings.fromJson(
          const AssistantSettings(historyTurns: 35).toJson(),
        ).historyTurns,
        35,
      );
      expect(
        AssistantSettings.fromJson(const {'historyTurns': 999}).historyTurns,
        AssistantSettings.historyTurnsMax,
      );
      expect(
        AssistantSettings.fromJson(const {'historyTurns': 0}).historyTurns,
        AssistantSettings.historyTurnsMin,
      );
      expect(
        AssistantSettings.fromJson(const {
          'historyTurns': double.infinity,
        }).historyTurns,
        AssistantSettings.historyTurnsDefault,
      );
    });
  });

  group('上下文轮数', () {
    Map<String, String> u(String t) => {'role': 'user', 'content': t};
    Map<String, String> a(String t) => {'role': 'assistant', 'content': t};

    test('只留最近几轮,边界落在提问上', () {
      final h = [u('1'), a('答1'), u('2'), a('答2'), u('3'), a('答3')];
      expect(recentTurns(h, 2), [u('2'), a('答2'), u('3'), a('答3')]);
      expect(recentTurns(h, 1).first, u('3'));
    });

    test('不足几轮就全留', () {
      final h = [u('1'), a('答1')];
      expect(recentTurns(h, 20), h);
      expect(recentTurns(const [], 20), isEmpty);
    });
  });

  group('对话记录导出', () {
    AgentTrace sample() {
      final t =
          AgentTrace(
              startedAt: DateTime(
                2026,
                9,
                15,
                20,
                58,
                3,
              ).millisecondsSinceEpoch,
              route: AgentTrace.routeCustom,
              userText: '画个芙兰',
              settings: <String, Object?>{
                'mode': 'normal',
                'history_turns': 20,
              },
            )
            ..system = '系统提示全文'
            ..prequery = {
              'block': '[画师串]\nA1 → artist:wlop',
              'modes': ['comic'],
            }
            ..messages = [
              {'role': 'user', 'content': '画个芙兰'},
            ]
            ..endedAt = DateTime(
              2026,
              9,
              15,
              20,
              58,
              21,
            ).millisecondsSinceEpoch;
      t.hops.add({
        't': 800,
        'ms': 5200,
        'reply': '先查一下',
        'tool_calls': [
          {
            'name': 'search_character',
            'arguments': {'query': '芙兰'},
          },
        ],
        'tool_results': '[search_character] []',
      });
      t.event('final', {
        'reply': '好了',
        'draw': {'positive': 'flandre_scarlet'},
      });
      return t;
    }

    test('记录存得下也读得回来', () {
      final t = sample();
      final back = AgentTrace.fromJson(
        jsonDecode(jsonEncode(t.toJson())) as Map<String, dynamic>,
      );
      expect(jsonEncode(back.toJson()), jsonEncode(t.toJson()));
    });

    test('读坏的字段当没有,不整份作废', () {
      final t = AgentTrace.fromJson(const {
        'route': 'custom',
        'hops': 'oops',
        'events': [
          1,
          {'event': 'x'},
        ],
        'settings': 3,
      });
      expect(t.route, AgentTrace.routeCustom);
      expect(t.hops, isEmpty);
      expect(t.events.single['event'], 'x');
      expect(t.settings, isEmpty);
    });

    test('导出里有每一轮的系统提示、每一跳、失败原因,和下一轮会带的上下文', () {
      final failed =
          AgentTrace(
              startedAt: 1,
              route: AgentTrace.routeBackend,
              userText: '再来',
              settings: <String, Object?>{},
            )
            ..request = {'user_request': '再来'}
            ..endedAt = 2
            ..error = '连接后端超时';
      final text = renderTraceExport(
        traces: [sample(), failed],
        settings: const {'historyTurns': 20},
        nextHistory: const [
          {'role': 'user', 'content': '画个芙兰'},
          {'role': 'assistant', 'content': '好了'},
        ],
        resources: const {
          'artist': {'A1': 'artist:wlop'},
        },
        messages: const [],
        now: 0,
        appVersion: '9.9.9',
      );
      for (final s in [
        '第 1 轮',
        '自定义接口',
        '系统提示全文',
        '第 1 跳',
        'search_character',
        '第 2 轮',
        '后端渠道',
        '失败:连接后端超时',
        '下一轮会带上的上下文',
        'artist:wlop',
      ]) {
        expect(text, contains(s));
      }
    });

    test('调试记录落盘,重开 app 还在', () async {
      final root = _tempRoot();
      final stores = await AppStores.open(rootOverride: root);
      await stores.assistant.saveTraces([sample()]);
      final again = await AppStores.open(rootOverride: root);
      expect(again.assistant.initialTraces.single.userText, '画个芙兰');
      expect(again.assistant.initialTraces.single.hops.single['ms'], 5200);
    });
  });

  group('对话里挂的出图', () {
    test('图库 id 能落盘也能读回来', () {
      const m = AssistantMsg(
        id: 'x',
        role: MsgRole.ai,
        text: '改好了喵~',
        at: 1,
        imageIds: ['gen3', 'gen4'],
      );
      expect(AssistantMsg.fromJson(m.toJson()).imageIds, ['gen3', 'gen4']);
    });

    test('老存档没有这个字段,读成空表', () {
      expect(
        AssistantMsg.fromJson(const {
          'id': 'y',
          'role': 'ai',
          'text': '旧消息',
          'at': 1,
        }).imageIds,
        isEmpty,
      );
    });

    test('copyWith 补图时别把工具轨迹和改动弄丢', () {
      const m = AssistantMsg(
        id: 'x',
        role: MsgRole.ai,
        text: 'ok',
        at: 1,
        tools: [ToolTrace(name: 'lookup_tag', subject: 'halo')],
      );
      final n = m.copyWith(imageIds: ['gen1']);
      expect(n.imageIds, ['gen1']);
      expect(n.tools.single.subject, 'halo');
    });
  });

  group('查资料轨迹', () {
    // 这一栏的价值全在「查的是什么」上:服务端回的 summary 只有计数,
    // 说不出查的是谁。挑错字段的后果是整栏退回「查了 3 处资料」那种废话。
    test('四个工具的参数名各不相同,都要能挑出查询词', () {
      // search_character
      expect(
        toolSubject(const {'query': '普拉娜', 'origin': '蔚蓝档案', 'limit': 8}),
        '普拉娜',
      );
      // lookup_tag
      expect(toolSubject(const {'query': 'halo', 'category': ''}), 'halo');
      // search_artist:按关键词
      expect(toolSubject(const {'artist_ids': [], 'keyword': 'wlop'}), 'wlop');
      // search_artist:按 id
      expect(
        toolSubject(const {
          'artist_ids': ['A1', 'B2'],
          'keyword': '',
        }),
        'A1 B2',
      );
      // random_artist 只有个数,那也是信息
      expect(toolSubject(const {'count': 3}), '随机 3 个');
    });

    test('query 空就退到 origin —— 「画个蔚蓝档案的角色」那种问法', () {
      expect(toolSubject(const {'query': '  ', 'origin': '蔚蓝档案'}), '蔚蓝档案');
    });

    test('什么都挑不出来就空着,不编一个词出来', () {
      expect(toolSubject(const {}), '');
      expect(toolSubject(const {'limit': 8, 'count': 0}), '');
    });

    test('折叠那行只报处数', () {
      expect(
        toolHeadline(const [
          ToolTrace(name: 'search_character', subject: '普拉娜'),
          ToolTrace(name: 'lookup_tag', subject: 'halo'),
          ToolTrace(name: 'lookup_tag', subject: 'smile'),
        ]),
        '查了 3 处资料',
      );
    });

    test('降级那条不算「查资料」,不能把处数灌水', () {
      expect(
        toolHeadline(const [
          ToolTrace(name: 'lookup_tag'),
          ToolTrace(name: kDegradedTool, summary: '已降级到安全模式'),
        ]),
        '查了 1 处资料',
      );
    });

    test('一处都没查、只有降级时报降级,不能报「查了 0 处」', () {
      expect(toolLabel(kDegradedTool), '安全模式');
      expect(
        toolHeadline(const [
          ToolTrace(name: kDegradedTool, summary: '已降级到安全模式'),
        ]),
        '安全模式',
      );
    });

    test('查询词能落盘也能读回来', () {
      const t = ToolTrace(
        name: 'search_character',
        subject: '普拉娜',
        summary: 'OC 0 个 + 通用 3/12 个 = 3 个',
      );
      final back = ToolTrace.fromJson(t.toJson());
      expect(back.subject, '普拉娜');
      expect(back.summary, t.summary);
      // 旧存档没有这个字段,读成空串而不是崩
      expect(ToolTrace.fromJson(const {'name': 'lookup_tag'}).subject, '');
    });

    test('补 summary 时别把查询词弄丢 —— tool_result 只回计数', () {
      const t = ToolTrace(name: 'lookup_tag', subject: 'halo');
      expect(t.copyWith(summary: '匹配 5 条').subject, 'halo');
    });
  });

  group('可选模型列表', () {
    // 这张表是后端下发的,app 只挑三样字段。挑错了不会崩,只会在顶栏显示一个
    // 看不出是哪一代的名字(「GLM」而不是「GLM 5.3 Flash」),所以拿真实形状钉住。
    Map<String, dynamic> live() => {
      'active': 'deepseek',
      'choices': {
        'deepseek': {
          // 后端写的是全角括号,去括号那条规则必须按真实形状钉
          'label': 'DeepSeek v4 flash（commandcode）',
          'short_label': 'DeepSeek',
          'model': 'deepseek-v4-flash@commandcode',
          'recommended': true,
          'aliases': ['ds'],
        },
        'gemini': {
          'label': 'Gemini(3.7 Flash Vertex)',
          'short_label': 'Gemini',
          'name': 'Gemini 3.7 Flash',
          'model': 'gemini-3.7-flash@vertex',
        },
        'chatgpt': {
          'label': 'ChatGPT(gpt-5.6-luna)',
          'name': 'GPT-5.6 Luna',
          'model': 'gpt-5.6-luna',
        },
        'glm': {
          'label': 'GLM 5.3 Flash(commandcode)',
          'name': 'GLM 5.3 Flash',
          'recommended': true,
          'model': 'glm-5.3-flash@commandcode',
        },
      },
    };

    test('显示名:有 name 用 name,没有就把 label 的括号说明去掉', () {
      final l = parseAgentModels(live());
      expect(l.byKey('gemini')!.name, 'Gemini 3.7 Flash');
      // deepseek 没配 name,得靠去括号得到完整型号,不能显示成整条 label
      expect(l.byKey('deepseek')!.name, 'DeepSeek v4 flash');
    });

    test('label 也没有就退回 key,不显示空白', () {
      final l = parseAgentModels({
        'choices': {
          'mystery': {'model': 'x'},
        },
      });
      expect(l.byKey('mystery')!.name, 'mystery');
    });

    test('推荐的排前面,同档保持后端顺序', () {
      final l = parseAgentModels(live());
      expect(
        [for (final c in l.choices) c.key],
        ['deepseek', 'glm', 'gemini', 'chatgpt'],
      );
      expect(l.byKey('glm')!.recommended, isTrue);
      expect(l.byKey('gemini')!.recommended, isFalse);
    });

    test('后端还没加 recommended 也照常出表 —— 只是没角标', () {
      final j = live();
      for (final v in (j['choices'] as Map).values) {
        (v as Map).remove('recommended');
      }
      final l = parseAgentModels(j);
      expect(l.choices.length, 4);
      expect(l.choices.every((c) => !c.recommended), isTrue);
      expect([for (final c in l.choices) c.key].first, 'deepseek');
    });

    test('形状不对不能整页打不开:少一条好过全没有', () {
      expect(parseAgentModels(const {}).choices, isEmpty);
      expect(parseAgentModels(const {'choices': 'nope'}).choices, isEmpty);
      final mixed = parseAgentModels(const {
        'choices': {
          'ok': {'name': 'OK'},
          'bad': 'not a map',
        },
      });
      expect([for (final c in mixed.choices) c.key], ['ok']);
    });

    test('active 读得出来 —— 没自己选过时顶栏显示的就是它', () {
      expect(parseAgentModels(live()).active, 'deepseek');
    });

    test('没有 Bot 授权时后端渠道不算:没选自定义接口,顶栏就是没选', () async {
      Future<AgentModelChoice?> shown({
        required bool authorized,
        required String pinned,
      }) async {
        final c = ProviderContainer(
          overrides: [
            assistantBotAuthorizedProvider.overrideWithValue(authorized),
            agentModelsProvider.overrideWith(
              (ref) async => parseAgentModels(live()),
            ),
            assistantModelPrefProvider.overrideWith(() => _PinnedPref(pinned)),
          ],
        );
        addTearDown(c.dispose);
        await c.read(agentModelsProvider.future);
        await c.read(assistantModelPrefProvider.future);
        return c.read(assistantModelProvider);
      }

      expect((await shown(authorized: true, pinned: 'glm'))?.key, 'glm');
      expect((await shown(authorized: true, pinned: ''))?.key, 'deepseek');
      expect(await shown(authorized: false, pinned: 'glm'), isNull);
      // 没选过时也不能拿后端默认那条顶上
      expect(await shown(authorized: false, pinned: ''), isNull);
    });
  });

  test('replaceCharacters 原样恢复,连 id 一起', () async {
    final n = await _notifier();
    final snap = [
      const CharacterPrompt(id: 'keep-me', name: '旧角色', positive: 'old'),
    ];
    n.applyAgentCharacters([
      (name: '新', positive: 'new', negative: '', position: ''),
    ]);
    n.replaceCharacters(snap);
    expect(n.state.characters.single.id, 'keep-me');
    expect(n.state.characters.single.positive, 'old');
  });
}

class _PinnedPref extends AssistantModelPrefNotifier {
  _PinnedPref(this.key);

  final String key;

  @override
  Future<String> build() async => key;
}
