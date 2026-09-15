/// 直连自定义接口那条:在 app 里跑一遍 agent 循环,吐出与 `streamAgentPrompt`
/// 完全一样的 [AgentEvent] 流。
///
/// **下游一个字都不用改**:结果卡、导入、生成、内联出图只认这四个事件和
/// [AgentResult],不知道字节是从 Plana 后端来的还是从用户自己的模型来的。
///
/// 三件事和服务端那条对齐,不能自己另发明一套:
///   · **提示词**用规则主体([PresetRule]),与服务端那条是同一份:自定义过就用自定义的,
///     没有就是服务端的默认那份。只是不套外壳 —— 外壳是服务端消息编排用的;
///   · **条件段**(漫画规则这类)发不发,由 `/api/agent/prequery` 顺带判好回来,
///     与服务端同一个判定,app 不另写一份关键词;用户手动选的模式(漫画、仅自然语言)
///     由调用方传进来,挑段规则与服务端同一条([renderRules]);
///   · **工具**打 `POST /api/agent/tools/call` 回后端代查 —— 与 tag 补全同一个路子。
///     不是在 app 里另写一份查询:同一句「画个芙兰」在两条路上给出不同候选,
///     用户只会以为模型不稳定;
///   · **预匹配与记账**打 `/api/agent/prequery`、`/api/agent/resources/merge`。
///     内置预设里写着「块里给了就直接用」—— 不做预匹配的话这句是空头支票,模型每轮
///     都得自己再查一遍。判据(停用词、热度闸、还在不在这幅画里)一律留在服务端,
///     app 只负责把块拼进去、把账本存着。画师串在块里只有占位符(`__ARTIST_A1__`),
///     收尾时由 `/resources/merge` 还原,和服务端那条同一份规则;
///   · **调用约定**(```tool_call 围栏、```nai_draw 围栏)由服务端渲染好的
///     「可用工具」块带过来,app 不拼这段 —— 加一个工具就得两边一起改的话,
///     漏一边的表现是模型调了个不存在的工具。
///
/// 与服务端那条**没有**的:降级阶梯、拒绝重掷、tag 哨兵。跑失败就是失败。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../core/net/agent_stream.dart';
import '../../core/net/backend_client.dart';
import '../../core/util/image_ops.dart' show styleRefResizeJpg;
import 'agent_trace.dart';
import 'assistant_models.dart' show decodeResources;
import 'assistant_settings.dart';
import 'custom_endpoint.dart';
import 'preset_rules.dart';

/// 一轮里最多跑几跳(每跳 = 一次模型调用)。
///
/// 服务端那条也是这个量级。放大没用:模型连查三轮还定不下来,多半是它在原地
/// 打转,再给它两跳只是多烧两次钱。
const _maxHops = 4;

final _toolFence = RegExp(
  r'```[ \t]*tool_call[ \t]*\r?\n(.*?)```',
  dotAll: true,
  caseSensitive: false,
);
final _drawFence = RegExp(
  r'```[ \t]*nai_draw[ \t]*\r?\n(.*?)```',
  dotAll: true,
  caseSensitive: false,
);
final _thinkTag = RegExp(
  r'<Think>.*?</Think>',
  dotAll: true,
  caseSensitive: false,
);

/// 附图:MIME + base64。
typedef DirectImage = ({String mime, String data});

/// 发给模型的一条消息。[image] 只挂在本轮用户那条上 —— 历史里的图不回带,
/// 与服务端那条一致。
typedef DirectMsg = ({String role, String content, DirectImage? image});

/// 按文件头认图片类型,认不出按 PNG —— 与服务端 `_sniff_image_mime` 同一张表。
/// 标签和字节对不上时有的接口整条拒收,而相册里挑的多半是 JPEG。
String imageMimeOf(Uint8List b) {
  bool at(int i, List<int> sig) {
    if (b.length < i + sig.length) return false;
    for (var k = 0; k < sig.length; k++) {
      if (b[i + k] != sig[k]) return false;
    }
    return true;
  }

  if (at(0, const [0x89, 0x50, 0x4E, 0x47])) return 'image/png';
  if (at(0, const [0xFF, 0xD8, 0xFF])) return 'image/jpeg';
  if (at(0, 'RIFF'.codeUnits) && at(8, 'WEBP'.codeUnits)) return 'image/webp';
  if (at(0, 'GIF87a'.codeUnits) || at(0, 'GIF89a'.codeUnits)) {
    return 'image/gif';
  }
  return 'image/png';
}

/// 附图超过这个字节数就先缩再发。
///
/// 卡的是 Claude:单张图 base64 超过 5MB 整条请求被拒,放大过的图随便就过线。
/// 服务端那条原样转发,失败了还有「剥图重试」兜着;直连没有重试,一次就得发得出去。
const kDirectImageMaxBytes = 3500000;

/// 附图 → 发给模型的那份。超过 [kDirectImageMaxBytes] 的按长边 2048 转 JPEG,
/// 画面内容看得清就够写提示词了。转不动(解不开的格式)就原样发,让接口自己判。
Future<DirectImage> prepareDirectImage(Uint8List bytes) async {
  if (bytes.length > kDirectImageMaxBytes) {
    try {
      final jpg = await styleRefResizeJpg(bytes, maxDim: 2048, quality: 90);
      return (mime: 'image/jpeg', data: base64Encode(jpg));
    } catch (_) {}
  }
  return (mime: imageMimeOf(bytes), data: base64Encode(bytes));
}

/// 画师串占位符 `__ARTIST_A1__`(机制见服务端 `artist_placeholder.py`)。写歪了也认:
/// 大小写、两头多了空格。
final _artistToken = RegExp(
  r'__\s*ARTIST\s*_\s*([^\s,，_]+(?:_[^\s,，_]+)*)\s*__',
  caseSensitive: false,
);

/// 文字里认得出的完整画师串折成占位符(映射取自 `/prequery` 的 `artist_placeholders`)。
///
/// 画布、历史里的画师串都是当初逐字填进去的,逐字比就对得上;用户在创作页改过的对不上,
/// 原样给模型。长的先换,免得短串吃掉长串的一截。
String collapseArtistStrings(String text, Map<String, String> tokens) {
  final entries = [
    for (final e in tokens.entries)
      if (e.value.isNotEmpty) e,
  ]..sort((a, b) => b.value.length.compareTo(a.value.length));
  var out = text;
  for (final e in entries) {
    out = out.replaceAll(e.value, e.key);
  }
  return out;
}

/// 占位符 → 完整画师串的**兜底**:服务端没还原成(老服务端、那一下网络断了)时用,
/// 保证占位符不原样进提示词。规则正本在服务端(`/resources/merge`),这里只认
/// `/prequery` 给过的,认不出的删掉。
String expandArtistTokens(String text, Map<String, String> tokens) {
  if (!_artistToken.hasMatch(text)) return text;
  final byBody = {
    for (final e in tokens.entries)
      if (_artistToken.firstMatch(e.key) case final m?)
        m[1]!.toLowerCase(): e.value,
  };
  var dropped = false;
  var out = text.replaceAllMapped(_artistToken, (m) {
    final hit = byBody[m[1]!.toLowerCase()];
    if (hit == null) dropped = true;
    return hit ?? '';
  });
  if (dropped) {
    out = out
        .replaceAll(RegExp(r'(\s*,\s*){2,}'), ', ')
        .replaceAll(RegExp(r'^\s*,\s*|\s*,\s*$'), '');
  }
  return out;
}

/// 本地库的画师串按服务端同一种起名方式列成「占位符 → 完整串」,兜底还原用:
/// 服务端没还原成、模型又用了工具查到的本地画师时,光靠 `/prequery` 的映射认不全。
Map<String, String> libraryArtistTokens(List<Map<String, dynamic>> artists) => {
  for (final a in artists)
    if ('${a['prompt'] ?? ''}'.trim().isNotEmpty)
      for (final n in {'${a['id'] ?? ''}', '${a['name'] ?? ''}'})
        if (n.trim().isNotEmpty)
          '__ARTIST_${n.trim().replaceAll(RegExp(r'[\s,，]+'), '_').replaceAll(RegExp(r'_{2,}'), '_')}__':
              '${a['prompt']}'.trim(),
};

/// 给用户看的正文里出现的占位符换成名字(`A1`),不换成一长串 tag。
String artistTokensToNames(String text) =>
    text.replaceAllMapped(_artistToken, (m) => m[1]!);

/// 正文里的 ```nai_draw 围栏 → 画面;剥掉围栏和 `<Think>` 之后剩下的就是回复。
///
/// 抽成纯函数是因为模型写坏围栏的花样很多(写成 ```json、忘了收尾的 ```、
/// 一条回复里写两个),而写坏的表现是「这轮没出图」,和「模型决定不出图」
/// 长得一模一样 —— 不单测根本分不出来。
({String reply, Map<String, dynamic>? draw}) parseDirectReply(String raw) {
  var text = raw.replaceAll(_thinkTag, '');
  Map<String, dynamic>? draw;
  // 取**最后**一个围栏:模型偶尔会先写一版再改一版,后写的是它的结论
  for (final m in _drawFence.allMatches(text)) {
    try {
      final j = jsonDecode(m.group(1)!.trim());
      if (j is Map<String, dynamic>) draw = j;
    } catch (_) {
      // 围栏里不是合法 JSON —— 当这轮没出图,正文照常发出去
    }
  }
  text = text.replaceAll(_drawFence, '');
  return (reply: text.trim(), draw: draw);
}

/// 正文里的 ```tool_call 围栏 → 待执行的调用。解析不了的那条跳过,不整轮作废。
List<({String name, Map<String, dynamic> args})> parseToolCalls(String raw) {
  final out = <({String name, Map<String, dynamic> args})>[];
  for (final m in _toolFence.allMatches(raw)) {
    try {
      final j = jsonDecode(m.group(1)!.trim());
      if (j is! Map) continue;
      final name = j['name']?.toString().trim() ?? '';
      if (name.isEmpty) continue;
      final args = j['arguments'];
      out.add((
        name: name,
        args: args is Map<String, dynamic> ? args : const {},
      ));
    } catch (_) {
      // 不是合法 JSON:跳过这一块。服务端那条会回灌一条「解析失败」让模型重写,
      // 直连这边不做 —— 没有重试预算的概念,多跑一跳不如让它凭已有信息作答。
    }
  }
  return out;
}

/// 自定义接口那条的系统提示:规则(已挂好工具层) + 出图格式 + 工具表。
///
/// 顺序对着服务端那条:规则主体在前,代码侧的「输出格式」「可用工具」两块在后。
/// [modes] 是预匹配判回来的,[chosen] 是用户选的模式,挑段规则见 [renderRules]。
String directSystemPrompt({
  required List<PresetRule> rules,
  required List<String>? modes,
  List<String> chosen = const [],
  required String outputFormat,
  required String toolsBlock,
}) => [
  renderRules(rules, modes, chosen: chosen),
  outputFormat.trim(),
  toolsBlock.trim(),
].where((s) => s.isNotEmpty).join('\n\n');

/// 跑一轮。事件序列与 [streamAgentPrompt] 一致,最后一个必是 [AgentDone]。
Stream<AgentEvent> streamDirectPrompt({
  required CustomEndpoint endpoint,
  required String backendBase,

  /// 空串 = 没有 Bot 授权。预匹配、工具、记账照样打后端,后端对这种调用只给本地库。
  required String sessionId,
  required String userRequest,

  /// 用户这轮附的图(原始字节)。挂在本轮 user 消息上,每一跳都带着。
  Uint8List? image,

  /// 这一轮用的规则(预设 + app 工具层,见 [withToolLayer])。按段给,条件段在这里筛。
  required List<PresetRule> rules,

  /// 出图代码块的格式说明([appOutputFormat])。服务端那条由后端代码发,这条得自己带。
  String outputFormat = '',

  /// 画布那段([当前画面提示词] 块),不带就是这轮不给画布。
  ///
  /// 和 [userRequest] 分开收、拼进同一条 user 消息 —— 与服务端 parts 的形状一致。
  /// **不能让它进预匹配**:整串画布 tag 拿去做字面匹配会把一堆无关角色匹出来
  /// (服务端那条也踩过,所以那边至今不回写 req.user_request)。
  String canvasBlock = '',
  List<Map<String, String>> history = const [],
  List<Map<String, dynamic>> webArtists = const [],
  List<Map<String, dynamic>> webOcs = const [],

  /// 上一轮记下的沿用资源(画师串 / OC)。发出去让服务端补进资料块,
  /// 收尾时连同本轮命中的一起并成新账本,随 [AgentResult.resources] 回去。
  Map<String, Map<String, String>> resources = const {},

  /// 设置里的「资料库范围」(`none` / `local` / `all`)。
  /// 预匹配和工具代查都吃这一项,两处必须同口径。
  String libraryScope = 'local',

  /// 用户选的模式(见 assistant_mode.dart),和预匹配判回来的一起挑段。
  List<String> chosenModes = const [],
  ThinkLevel think = ThinkLevel.auto,
  Duration timeout = const Duration(seconds: 120),

  /// 调试记录:系统提示、消息、每一跳的模型原话和工具结果都记进去。
  AgentTrace? trace,
}) async* {
  final client = http.Client();
  try {
    // 两个后端块彼此不相干,并着取 —— 串着取等于在第一次模型调用前白等两个往返。
    // 附图要缩的话也在这时候缩。
    final (toolsBlock, pre, img) = await (
      _fetchToolsBlock(client, backendBase, sessionId),
      _fetchPrequery(
        client,
        backendBase,
        sessionId,
        text: userRequest,
        // 判模式要看这一轮会一起发出去的其它文字:画布,以及带着出图围栏的
        // 最近几轮回复(「上一轮画过分格图」)。它们不进预匹配。
        contextTexts: [
          if (canvasBlock.isNotEmpty) canvasBlock,
          for (final h in history.reversed.take(4))
            if (h['role'] == 'assistant') h['content'] ?? '',
        ],
        webArtists: webArtists,
        webOcs: webOcs,
        resources: resources,
        libraryScope: libraryScope,
      ),
      image == null ? Future<DirectImage?>.value() : prepareDirectImage(image),
    ).wait;
    final system = directSystemPrompt(
      rules: rules,
      modes: pre.modes,
      chosen: chosenModes,
      outputFormat: outputFormat,
      toolsBlock: toolsBlock,
    );
    trace
      ?..prequery = {
        'block': pre.block,
        'this_turn': pre.thisTurn,
        'modes': pre.modes,
        'artist_placeholders': pre.artists,
      }
      ..system = system;

    // 消息流:历史 + 本轮。工具结果以 user 文本回灌,与服务端那条同一种形状。
    // 用户那段 + 画布拼成一条 user 消息,资料块跟在后面。
    // 画布和历史里认得出的完整画师串折成占位符 —— 模型看到的「自己上次写的」就是占位符,
    // 不会照着抄完整串(服务端那条在 run_chat_with_retries 里做同一件事)。
    final msgs = <DirectMsg>[
      for (final h in history)
        (
          role: h['role'] ?? 'user',
          content: collapseArtistStrings(h['content'] ?? '', pre.artists),
          image: null,
        ),
      (
        role: 'user',
        content: [
          userRequest,
          collapseArtistStrings(canvasBlock, pre.artists),
          pre.block,
        ].where((s) => s.isNotEmpty).join('\n\n'),
        image: img,
      ),
    ];

    trace?.messages = [
      for (final m in msgs)
        {
          'role': m.role,
          'content': m.content,
          if (m.image case final i?)
            'image': '<${i.mime} base64 ${i.data.length} 字符>',
        },
    ];

    for (var hop = 0; hop < _maxHops; hop++) {
      final hopStart = trace?.sinceStart() ?? 0;
      final raw = await _callModel(
        client,
        endpoint,
        system: system,
        msgs: msgs,
        think: think,
        timeout: timeout,
      );
      final hopRec = <String, Object?>{
        't': hopStart,
        'ms': (trace?.sinceStart() ?? 0) - hopStart,
        'reply': raw,
      };
      trace?.hops.add(hopRec);
      final calls = parseToolCalls(raw);
      if (calls.isEmpty || hop == _maxHops - 1) {
        final parsed = parseDirectReply(raw);
        final merged = await _mergeResources(
          client,
          backendBase,
          sessionId,
          remembered: resources,
          thisTurn: pre.thisTurn,
          spec: parsed.draw,
          artists: pre.artists,
          webArtists: webArtists,
          libraryScope: libraryScope,
        );
        final draw =
            merged.spec ??
            _expandDraw(parsed.draw, {
              ...libraryArtistTokens(webArtists),
              ...pre.artists,
            });
        final reply = artistTokensToNames(parsed.reply);
        trace?.event('final', {
          'reply': reply,
          'draw': parsed.draw,
          if (draw != parsed.draw) 'draw_expanded': draw,
          'resources': merged.ledger,
        });
        yield AgentDone(_toResult(reply, draw, merged.ledger));
        return;
      }

      msgs.add((role: 'assistant', content: raw, image: null));
      hopRec['tool_calls'] = [
        for (final c in calls) {'name': c.name, 'arguments': c.args},
      ];
      final chunks = <String>[];
      for (final c in calls) {
        yield AgentToolCall(c.name, c.args);
        String summary;
        Object? result;
        try {
          result = await _callTool(
            client,
            backendBase,
            sessionId,
            c,
            webArtists: webArtists,
            webOcs: webOcs,
            libraryScope: libraryScope,
          );
          summary = result is List ? '${result.length} 条' : '已返回';
        } catch (e) {
          result = null;
          summary = '$e';
        }
        yield AgentToolResult(c.name, summary);
        chunks.add(
          '[${c.name}] ${result == null ? "执行失败:$summary" : jsonEncode(result)}',
        );
      }
      hopRec['tool_results'] = chunks.join('\n\n');
      msgs.add((
        role: 'user',
        content:
            '[tool_result 共 ${calls.length} 条] 以下是你上一条回复里 tool_call 的执行结果。'
            '请基于结果给出**最终回复**(不要再重复调用同样的工具)。\n\n'
            '${chunks.join("\n\n")}',
        image: null,
      ));
    }
  } finally {
    client.close();
  }
}

/// 画面里的占位符本地兜底还原(见 [expandArtistTokens])。
Map<String, dynamic>? _expandDraw(
  Map<String, dynamic>? draw,
  Map<String, String> artists,
) {
  if (draw == null || !_artistToken.hasMatch(jsonEncode(draw))) return draw;
  String fix(Object? v) => expandArtistTokens(v?.toString() ?? '', artists);
  return {
    ...draw,
    if (draw['positive'] != null) 'positive': fix(draw['positive']),
    if (draw['negative'] != null) 'negative': fix(draw['negative']),
    if (draw['characters'] is List)
      'characters': [
        for (final c in draw['characters'] as List)
          c is Map<String, dynamic>
              ? {
                  ...c,
                  if (c['positive'] != null) 'positive': fix(c['positive']),
                  if (c['negative'] != null) 'negative': fix(c['negative']),
                }
              : c,
      ],
  };
}

AgentResult _toResult(
  String reply,
  Map<String, dynamic>? draw,
  Map<String, Map<String, String>> resources,
) {
  final d = draw ?? const <String, dynamic>{};
  return AgentResult(
    replyText: reply.isNotEmpty ? reply : '本喵在喵~',
    positive: d['positive']?.toString() ?? '',
    negative: d['negative']?.toString() ?? '',
    characters: [
      for (final c in (d['characters'] as List? ?? const []))
        if (c is Map<String, dynamic>) AgentCharacter.fromJson(c),
    ],
    // 服务端并好的账本原样带出去。**不能回空** —— 调用方是拿最新那条 AI
    // 消息的账本发下一轮的,回空等于把之前记着的画风冲掉。
    resources: resources,
  );
}

/// 预匹配:按用户这轮的话取画师串 / OC / 角色候选,连带把 [resources] 里
/// 记着的补齐,返回**渲染好的**块。
///
/// 拿不到就空着走 —— 没有资料块模型还能靠工具自己查,为此整轮失败不划算。
///
/// 顺带回来本轮命中的条件段模式。**取不到就是 null**(不是空列表):空列表的
/// 意思是「判过了,不是漫画」,会把漫画规则筛掉;null 的意思是「没判成」,
/// 调用方全发 —— 多发一段比把用户要的漫画画成单图代价小。
Future<
  ({
    String block,
    Map<String, Map<String, String>> thisTurn,
    List<String>? modes,
    Map<String, String> artists,
  })
>
_fetchPrequery(
  http.Client c,
  String base,
  String sessionId, {
  required String text,
  required List<String> contextTexts,
  required List<Map<String, dynamic>> webArtists,
  required List<Map<String, dynamic>> webOcs,
  required Map<String, Map<String, String>> resources,
  required String libraryScope,
}) async {
  const empty = (
    block: '',
    thisTurn: <String, Map<String, String>>{},
    modes: null,
    artists: <String, String>{},
  );
  if (base.isEmpty) return empty;
  try {
    final r = await c
        .post(
          Uri.parse('$base/api/agent/prequery'),
          headers: {'Content-Type': 'application/json', ..._auth(sessionId)},
          body: jsonEncode({
            'user_request': text,
            'web_artists': webArtists,
            'web_ocs': webOcs,
            'resources': resources,
            'library_scope': libraryScope,
            'context_texts': contextTexts,
            // [画师串] 块换成占位符,顺带回传映射(折画布和历史、兜底还原用)
            'artist_placeholders': true,
          }),
        )
        .timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) return empty;
    final j = jsonDecode(utf8.decode(r.bodyBytes));
    if (j is! Map) return empty;
    final artists = j['artist_placeholders'];
    return (
      block: j['block']?.toString() ?? '',
      thisTurn: decodeResources(j['this_turn']),
      // 老后端不回这个字段:当没判成,全发
      modes: j['modes'] is List
          ? [for (final m in j['modes'] as List) '$m']
          : null,
      // 老后端不认开关,块里还是完整内容,这里就是空的,折叠和还原都不发生
      artists: artists is Map
          ? {for (final e in artists.entries) '${e.key}': '${e.value}'}
          : const <String, String>{},
    );
  } catch (_) {
    return empty;
  }
}

/// 收尾:画面里的画师串占位符还原,再记账 —— 本轮命中的 ∪ 上轮记着的,按「还在不在这幅画里」
/// 筛一遍(按还原后的画面算)。
///
/// 规则在服务端(bot / web / 直连同一份)。算不出来就把上轮那本原样留着 ——
/// 多留一个块的代价远小于把用户在用的画风忘掉;[spec] 为 null 时调用方自己兜底还原。
Future<({Map<String, Map<String, String>> ledger, Map<String, dynamic>? spec})>
_mergeResources(
  http.Client c,
  String base,
  String sessionId, {
  required Map<String, Map<String, String>> remembered,
  required Map<String, Map<String, String>> thisTurn,
  required Map<String, dynamic>? spec,
  required Map<String, String> artists,
  required List<Map<String, dynamic>> webArtists,
  required String libraryScope,
}) async {
  final fallback = (ledger: remembered, spec: null);
  final placeholders = spec != null && _artistToken.hasMatch(jsonEncode(spec));
  if (base.isEmpty) return fallback;
  if (remembered.isEmpty && thisTurn.isEmpty && !placeholders) {
    return (ledger: const <String, Map<String, String>>{}, spec: null);
  }
  try {
    final r = await c
        .post(
          Uri.parse('$base/api/agent/resources/merge'),
          headers: {'Content-Type': 'application/json', ..._auth(sessionId)},
          body: jsonEncode({
            'remembered': remembered,
            'this_turn': thisTurn,
            // null = 这轮没出图,不筛(没出图不代表用户放弃了这套画风)
            'spec': spec,
            if (placeholders) ...{
              'expand_artists': true,
              'artist_placeholders': artists,
              // 映射里没有的(工具查到的画师)服务端去资料库查
              'web_artists': webArtists,
              'library_scope': libraryScope,
            },
          }),
        )
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) return fallback;
    final j = jsonDecode(utf8.decode(r.bodyBytes));
    if (j is! Map) return fallback;
    return (
      ledger: decodeResources(j['resources']),
      spec: j['spec'] is Map<String, dynamic>
          ? j['spec'] as Map<String, dynamic>
          : null,
    );
  } catch (_) {
    return fallback;
  }
}

/// 「可用工具」块。拿不到就返回空串 —— 没有工具照样能出词,只是查不了资料;
/// 为此整轮失败不划算。
Future<String> _fetchToolsBlock(
  http.Client c,
  String base,
  String sessionId,
) async {
  if (base.isEmpty) return '';
  try {
    final r = await c
        .get(Uri.parse('$base/api/agent/tools'), headers: _auth(sessionId))
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) return '';
    final j = jsonDecode(utf8.decode(r.bodyBytes));
    return (j is Map ? j['block']?.toString() : null) ?? '';
  } catch (_) {
    return '';
  }
}

Future<Object?> _callTool(
  http.Client c,
  String base,
  String sessionId,
  ({String name, Map<String, dynamic> args}) call, {
  required List<Map<String, dynamic>> webArtists,
  required List<Map<String, dynamic>> webOcs,
  required String libraryScope,
}) async {
  if (base.isEmpty) throw BackendException('没有后端地址,查不了资料');
  final r = await c
      .post(
        Uri.parse('$base/api/agent/tools/call'),
        headers: {'Content-Type': 'application/json', ..._auth(sessionId)},
        body: jsonEncode({
          'name': call.name,
          'arguments': call.args,
          'web_artists': webArtists,
          'web_ocs': webOcs,
          'library_scope': libraryScope,
        }),
      )
      .timeout(const Duration(seconds: 30));
  final j = jsonDecode(utf8.decode(r.bodyBytes));
  if (r.statusCode < 200 || r.statusCode >= 300) {
    final detail =
        (j is Map ? j['detail']?.toString() : null) ?? '${r.statusCode}';
    throw BackendException(detail);
  }
  return j is Map ? j['result'] : null;
}

/// 有 Bot 授权才带会话;没有就匿名打,后端对匿名调用只给本地库。
Map<String, String> _auth(String sessionId) =>
    sessionId.isEmpty ? const {} : {'Authorization': 'Bearer $sessionId'};

/// 打一次模型,拿整段正文。三家的请求体和取文字段各不相同。
///
/// **不走流式**:这条链路的产出是「一段回复 + 一个围栏」,围栏没收完解析不了,
/// 逐 token 显示也只能显示到一半就要撤回。服务端那条同样是 `.run()` 不是
/// `.run_stream()`,理由一样。
Future<String> _callModel(
  http.Client c,
  CustomEndpoint e, {
  required String system,
  required List<DirectMsg> msgs,
  required ThinkLevel think,
  required Duration timeout,
}) async {
  // 路径可配(中转改路径是常事),Gemini 那条还把模型名写在路径里 ——
  // 两件事都由 CustomEndpoint.chatUri 处理,这儿不再各拼各的。
  final uri = e.chatUri;
  final (headers, body) = directRequest(
    e,
    system: system,
    msgs: msgs,
    think: think,
  );

  final http.Response r;
  try {
    r = await c
        .post(
          uri,
          headers: {'Content-Type': 'application/json', ...headers},
          body: jsonEncode(body),
        )
        .timeout(timeout);
  } on TimeoutException {
    throw BackendException('模型没在时限内回复');
  } catch (_) {
    throw BackendException('连不上 ${uri.host}');
  }
  final decoded = jsonDecode(utf8.decode(r.bodyBytes));
  if (r.statusCode < 200 || r.statusCode >= 300) {
    throw BackendException(_errorOf(decoded, r.statusCode));
  }
  final text = extractReplyText(e.format, decoded);
  if (text.trim().isEmpty) throw BackendException('模型回了一段空的');
  return text;
}

/// 一次模型调用的请求头与请求体。三家的形状各不相同,抽出来单测 ——
/// 附图字段写错的表现是「模型说没看到图」,和它自己看走眼分不出来。
///
/// 带图的那条 content 从字符串换成分段数组,**图在前、字在后**
/// (Claude 与 Gemini 的文档都建议单图时这么摆,OpenAI 不挑)。
(Map<String, String>, Map<String, dynamic>) directRequest(
  CustomEndpoint e, {
  required String system,
  required List<DirectMsg> msgs,
  required ThinkLevel think,
}) {
  final key = e.apiKey.trim();
  return switch (e.format) {
    AgentApiFormat.openai => (
      {'Authorization': 'Bearer $key'},
      {
        'model': e.model,
        'messages': [
          {'role': 'system', 'content': system},
          for (final m in msgs)
            {
              'role': m.role,
              'content': switch (m.image) {
                final i? => [
                  {
                    'type': 'image_url',
                    'image_url': {'url': 'data:${i.mime};base64,${i.data}'},
                  },
                  if (m.content.isNotEmpty) {'type': 'text', 'text': m.content},
                ],
                null => m.content,
              },
            },
        ],
        ...thinkFields(AgentApiFormat.openai, think),
      },
    ),
    AgentApiFormat.google => (
      {'x-goog-api-key': key},
      {
        'systemInstruction': {
          'parts': [
            {'text': system},
          ],
        },
        'contents': [
          for (final m in msgs)
            {
              // Gemini 只认 user / model 两种
              'role': m.role == 'assistant' ? 'model' : 'user',
              'parts': [
                if (m.image case final i?)
                  {
                    'inlineData': {'mimeType': i.mime, 'data': i.data},
                  },
                if (m.image == null || m.content.isNotEmpty)
                  {'text': m.content},
              ],
            },
        ],
        ...thinkFields(AgentApiFormat.google, think),
      },
    ),
    AgentApiFormat.anthropic => (
      {'x-api-key': key, 'anthropic-version': '2023-06-01'},
      {
        'model': e.model,
        // Anthropic 必填,且没有"不限"这一档。开了思考还得**大于**思考预算,
        // 否则整条请求会被拒:那笔预算是从 max_tokens 里切出去的。
        'max_tokens': 4096 + _anthropicBudget(think),
        'system': system,
        'messages': [
          for (final m in msgs)
            {
              'role': m.role,
              'content': switch (m.image) {
                final i? => [
                  {
                    'type': 'image',
                    'source': {
                      'type': 'base64',
                      'media_type': i.mime,
                      'data': i.data,
                    },
                  },
                  if (m.content.isNotEmpty) {'type': 'text', 'text': m.content},
                ],
                null => m.content,
              },
            },
        ],
        ...thinkFields(AgentApiFormat.anthropic, think),
      },
    ),
  };
}

/// Anthropic 的思考预算(token)。0 = 不开。下限是它自己规定的 1024。
int _anthropicBudget(ThinkLevel l) => switch (l) {
  ThinkLevel.auto || ThinkLevel.off => 0,
  ThinkLevel.low => 1024,
  ThinkLevel.medium => 4096,
  ThinkLevel.high => 8192,
  ThinkLevel.ultra => 16384,
};

/// 思考等级 → 各家请求体里的那几个字段。
///
/// 三家的旋钮完全不是一回事:OpenAI 给的是档位字符串,另外两家要的是 **token 预算**。
/// [ThinkLevel.auto] 一律返回空表 —— 不发这个字段,让模型/服务方用自己的默认。
/// 中转不认这些字段时通常直接忽略,所以发了也不至于把请求打死。
Map<String, dynamic> thinkFields(AgentApiFormat format, ThinkLevel level) {
  if (level == ThinkLevel.auto) return const {};
  switch (format) {
    case AgentApiFormat.openai:
      return {
        'reasoning_effort': switch (level) {
          // OpenAI 两头都封顶:没有「关」,minimal 是最低;也没有「超高」,
          // high 是最高 —— 所以这两档各自撞在端点上,不是写漏了。
          ThinkLevel.off => 'minimal',
          ThinkLevel.low => 'low',
          ThinkLevel.high || ThinkLevel.ultra => 'high',
          _ => 'medium',
        },
      };
    case AgentApiFormat.google:
      return {
        'generationConfig': {
          'thinkingConfig': {
            'thinkingBudget': switch (level) {
              ThinkLevel.off => 0,
              ThinkLevel.low => 1024,
              ThinkLevel.high => 16384,
              ThinkLevel.ultra => 24576,
              _ => 8192,
            },
          },
        },
      };
    case AgentApiFormat.anthropic:
      final budget = _anthropicBudget(level);
      // 「关」在 Anthropic 这边就是不带 thinking 字段
      if (budget == 0) return const {};
      return {
        'thinking': {'type': 'enabled', 'budget_tokens': budget},
      };
  }
}

/// 三家的响应 → 正文。认错字段的表现是「模型回了一段空的」,和真的空回
/// 长得一样,所以抽出来单测。
String extractReplyText(AgentApiFormat format, Object? body) {
  if (body is! Map) return '';
  switch (format) {
    case AgentApiFormat.openai:
      final choices = body['choices'];
      if (choices is! List || choices.isEmpty) return '';
      final first = choices.first;
      if (first is! Map) return '';
      final msg = first['message'];
      if (msg is Map) return msg['content']?.toString() ?? '';
      return first['text']?.toString() ?? '';
    case AgentApiFormat.google:
      final cands = body['candidates'];
      if (cands is! List || cands.isEmpty) return '';
      final first = cands.first;
      if (first is! Map) return '';
      final parts = (first['content'] as Map?)?['parts'];
      if (parts is! List) return '';
      return [
        for (final p in parts)
          if (p is Map && p['text'] != null) p['text'].toString(),
      ].join();
    case AgentApiFormat.anthropic:
      final content = body['content'];
      if (content is! List) return '';
      return [
        for (final p in content)
          if (p is Map && p['type'] == 'text') p['text']?.toString() ?? '',
      ].join();
  }
}

/// 错误体 → 给用户看的一句话。三家都把话装在 `error` 里,但形状不同。
String _errorOf(Object? body, int status) {
  if (body is Map) {
    final err = body['error'];
    if (err is Map) {
      final m = err['message']?.toString();
      if (m != null && m.isNotEmpty) return m;
    }
    if (err is String && err.isNotEmpty) return err;
    final m = body['message']?.toString();
    if (m != null && m.isNotEmpty) return m;
  }
  return '模型返回 $status';
}
