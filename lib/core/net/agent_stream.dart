/// AI 助手一轮对话的实时链路:`POST /api/agent/web/generate-prompt`,
/// 响应是 `text/event-stream`(SSE)。
///
/// 与 [streamBotTask](bot_stream.dart) 的分工:那条走 WebSocket + 轮询兜底,
/// 管的是**出图任务**的进度;这条是单向的 SSE,管的是**一轮 LLM** 的过程与产出。
/// 两条都不进 [BackendClient] —— 它那套 `_postJson` 是「攒完整个 body 再解析」,
/// 天然装不下流式。
///
/// 事件按后端 `agent_router/schemas.py:SseEvent` 定义,这里只认 app 用得上的四类:
///   `tool_call` / `tool_result` → [AgentToolCall] / [AgentToolResult]
///   `degraded`                  → [AgentDegraded]
///   `final`                     → [AgentDone](流的最后一个事件)
///   `error`                     → 抛 [BackendException]
/// 其余(`agent_token` 等)静默丢弃 —— 后端现在压根不发(走的是 `.run()`),
/// 而且真要接上也不能原样显示:`<Think>` 段与围栏是 final 才剥的,逐 token 漏给
/// 用户就是把模型的草稿纸摊开。自填接口那条已经在 app 内自己剥好了再发
/// [AgentDelta](见 direct_agent 的 `directStreamView`),后端这条照那个口径补齐
/// 之后就能直接接上。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpClient;

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'backend_client.dart';

sealed class AgentEvent {
  const AgentEvent();
}

/// 模型开始调一个知识库工具。
class AgentToolCall extends AgentEvent {
  const AgentToolCall(this.name, this.args);

  /// 后端工具名:`search_character` / `search_artist` / `random_artist` / `lookup_tag`。
  final String name;
  final Map<String, dynamic> args;
}

/// 工具返回。[summary] 是服务端写好的中文摘要(「匹配 3 个画风串」),直接展示。
class AgentToolResult extends AgentEvent {
  const AgentToolResult(this.name, this.summary);

  final String name;
  final String summary;
}

/// 软降级(上游拒绝后退到安全模式)。图照出,只是这轮质量可能打折。
class AgentDegraded extends AgentEvent {
  const AgentDegraded();
}

/// 模型正在写这一跳的回复(目前只有自填接口那条会发)。
///
/// 带的是**到此刻为止的全量**,不是增量:`</Think>` 收尾、换一跳重写时正文会整段
/// 挪位,拼增量得在两头各留一套回退,每帧重算一份便宜得多。拿到就整块替换。
class AgentDelta extends AgentEvent {
  const AgentDelta({this.text = '', this.reasoning = ''});

  /// 能直接摆进气泡的正文:`<Think>` 段与 ```tool_call / ```nai_draw 围栏已剔掉。
  final String text;

  /// 思考过程:模型原生的 reasoning 字段 + 正文里的 `<Think>` 段。
  final String reasoning;
}

/// 终态。拿到它这一轮就结束了,后面不会再有事件。
class AgentDone extends AgentEvent {
  const AgentDone(this.result);

  final AgentResult result;
}

/// 跑一轮 AI 助手。
///
/// [imageModel] 是**图片生成模型**的档位(与 LLM 渠道 [model] 正交),取值
/// `anima` / `krea` / `nai_v5*` / `nai_v45*`,由 [agentImageModel] 从当前显示模型换算。
/// **不传就恒走 NAI 4.5 的预设** —— krea 吃的是连贯自然语言、anima 是另一套体系,
/// 拿 4.5 的 tag 串预设去喂它们等于没写。
///
/// [history] 是**前端持有**的对话历史(`[{role, content}]`,role 取 `user` /
/// `assistant`)—— 这条链路服务端不存历史,不回带就等于每轮都是新对话。
/// [historyTurns] 告诉服务端按几轮截(助手设置里的「上下文轮数」);不带的话服务端
/// 按默认的 20 轮截,设成 30 发上来也会被截回 20。老版服务端不认这个字段,照旧 20。
///
/// [currentPositive] / [currentNegative] / [currentCharacters] 是用户**当前**的
/// 画面状态,让模型能「在这基础上改」而不是每次从头写。角色项形如
/// `{name, positive, negative, position}`,`position` 必须带上 —— 不发的话模型
/// 看不见构图,重写 characters 时一律不带站位,前端就把用户摆好的位置重排掉了。
///
/// **三项都留空 = 这轮不给画布**(服务端 `_build_current_prompt_context` 三项全空
/// 时整块不拼)。app 里是不是给由用户按钮决定,见 `AssistantNotifier.send`。
///
/// [webArtists] / [webOcs] 是**用户自己那份**画师串与 OC(灵感页的库)。
/// 发了就**只用这份** —— 服务端不再并进它本机那份公共库(见
/// `_load_artists_for_deps`)。不发的话服务端回落公共库,那是 bot 的口径。
/// [libraryScope] 对应设置里的「资料库范围」:`local` 是上面那条默认规矩,
/// `all` 表示发了自己那份还要再并上公共库,`none` 则三样资料全不给
/// (**这一档必须显式发**,不发库只会让服务端回落公共库,恰好是反的)。
///
/// ⚠ 发了 `webArtists` 之后,服务端会把回来的正向词里认得出的画师串包成
/// `<<artist:名字:内容>>`(web 前端拿它渲染芯片)。app 不渲染芯片,收到后要
/// 用 [stripArtistMarkers] 剥干净,别把尖括号写进用户的提示词。
///
/// [idleTimeout] 是**静默超时**,不是整轮超时:agent 带工具循环,正常也可能跑
/// 40 秒以上,按整轮掐必然误杀;而只要还在推事件就说明活着。取消订阅即断流
/// (`finally` 里关掉 client,连接跟着断)。
///
/// 120 秒这个值是按**最长的一段静默**定的:服务端这条路走 `.run()` 不是
/// `.run_stream()`,所以没有 agent_token 事件 —— 从最后一次 tool_result 到出最终
/// 答案之间一个事件都没有,那段就是一整次 LLM 生成。服务端自己还有 240 秒的整轮
/// 硬上限并且一定会发 final 或 error,所以这边真正要兜的只是「连接死了」,
/// 不必掐得紧。**别再调回 45 秒** —— 那是接外层重试阶梯之前的值,阶梯重掷时
/// 静默会更长,会把还在正常干活的一轮误判成断线。
///
/// **等响应头也按 [idleTimeout] 算**,只有「连上服务器」限时 20 秒。服务端挂着
/// GZip 中间件,SSE 的响应头会被扣到第一段 body 才发;老版服务端第一段就是第一个
/// 事件,模型 20 秒内既没调工具也没出结果,原先按 20 秒等响应头就把正常在跑的一轮
/// 当成连不上掐掉了(服务端那一轮照样跑完,token 照扣)。新版服务端开流先推一行
/// 注释、之后每 15 秒一次心跳,两边都兼容。
///
/// 失败一律抛 [BackendException]:HTTP 非 2xx、`error` 事件、静默超时、连不上。
/// **抛出时这一轮什么都没写**。
Stream<AgentEvent> streamAgentPrompt({
  required String baseUrl,
  required String sessionId,
  required String userRequest,
  String model = '',
  String imageModel = '',
  String? imageB64,
  List<Map<String, String>> history = const [],
  int historyTurns = 20,
  String currentPositive = '',
  String currentNegative = '',
  List<Map<String, dynamic>> currentCharacters = const [],
  List<Map<String, dynamic>> webArtists = const [],
  List<Map<String, dynamic>> webOcs = const [],
  Map<String, Map<String, String>> resources = const {},
  String libraryScope = 'local',

  /// 自定义过的规则主体(`[{name, content, when}]`)。**空 = 用服务端预设自己那份**,
  /// 这时一个字都不发 —— 没改过规则的人不必每轮背着两万字上传。
  List<Map<String, dynamic>> presetRules = const [],

  /// 用户选的模式(`mode:comic` 这类,见 assistant_mode.dart)。服务端并进本轮的
  /// 条件段筛选;空 = 正常模式,不发。
  List<String> modes = const [],
  Duration idleTimeout = const Duration(seconds: 120),

  /// 调试记录(见 `AgentTrace`):发出去的请求体,图片换成大小。
  void Function(Map<String, Object?> body)? onRequest,

  /// 调试记录:收到的每一帧,原样(解不开 JSON 的给原文)。
  void Function(String event, Object? data)? onEvent,
}) async* {
  if (baseUrl.isEmpty) throw BackendException('未配置后端地址');

  final client = IOClient(
    HttpClient()..connectionTimeout = const Duration(seconds: 20),
  );
  try {
    final hasImage = imageB64 != null && imageB64.isNotEmpty;
    final body = <String, Object?>{
      'user_request': userRequest,
      'model': model,
      'image_model': imageModel,
      if (hasImage) 'image_b64': imageB64,
      'history': history,
      'history_turns': historyTurns,
      'current_positive': currentPositive,
      'current_negative': currentNegative,
      'current_characters': currentCharacters,
      'web_artists': webArtists,
      'web_ocs': webOcs,
      'resources': resources,
      'library_scope': libraryScope,
      if (presetRules.isNotEmpty) 'preset_rules': presetRules,
      if (modes.isNotEmpty) 'modes': modes,
    };
    onRequest?.call({
      ...body,
      if (hasImage) 'image_b64': '<图片 base64 ${imageB64.length} 字符>',
    });
    final req =
        http.Request(
            'POST',
            Uri.parse('$baseUrl/api/agent/web/generate-prompt'),
          )
          ..headers.addAll({
            'Content-Type': 'application/json',
            'Accept': 'text/event-stream',
            'Authorization': 'Bearer $sessionId',
          })
          ..bodyBytes = utf8.encode(jsonEncode(body));

    final http.StreamedResponse resp;
    try {
      resp = await client.send(req).timeout(idleTimeout);
    } on TimeoutException {
      throw BackendException('等了 ${idleTimeout.inSeconds} 秒没等到回复,可能是上游堵了');
    } on BackendException {
      rethrow;
    } catch (_) {
      throw BackendException('无法连接后端,请检查地址与网络');
    }

    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      // 错误响应是普通 JSON(FastAPI 的 {"detail": ...}),不是事件流。
      final body = await resp.stream.bytesToString();
      var detail = '请求失败(${resp.statusCode})';
      try {
        final j = jsonDecode(body);
        if (j is Map && j['detail'] is String) detail = j['detail'] as String;
      } catch (_) {}
      throw BackendException(detail, status: resp.statusCode);
    }

    // 一帧 = 若干行 + 一个空行。`event:` 定类型,`data:` 装 JSON。
    var event = '';
    final data = StringBuffer();

    final lines = resp.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .timeout(
          idleTimeout,
          onTimeout: (sink) => sink.addError(
            BackendException('等了 ${idleTimeout.inSeconds} 秒没等到回复,可能是上游堵了'),
          ),
        );

    await for (final line in lines) {
      if (line.isNotEmpty) {
        if (line.startsWith('event:')) {
          event = line.substring(6).trim();
        } else if (line.startsWith('data:')) {
          // 同一帧的多条 data 行按 SSE 规范用换行拼接(服务端目前只发一条)。
          if (data.isNotEmpty) data.write('\n');
          data.write(line.substring(5).trim());
        }
        continue;
      }

      // 空行 = 帧结束。
      final raw = data.toString();
      final name = event;
      event = '';
      data.clear();
      if (name.isEmpty) continue;

      Object? payload;
      try {
        payload = jsonDecode(raw);
      } catch (_) {
        payload = null;
      }
      onEvent?.call(name, payload ?? raw);
      final map = payload is Map<String, dynamic>
          ? payload
          : const <String, dynamic>{};

      switch (name) {
        case 'tool_call':
          yield AgentToolCall(
            map['name']?.toString() ?? '',
            map['arguments'] is Map<String, dynamic>
                ? map['arguments'] as Map<String, dynamic>
                : const {},
          );
        case 'tool_result':
          yield AgentToolResult(
            map['name']?.toString() ?? '',
            map['summary']?.toString() ?? '',
          );
        case 'degraded':
          yield const AgentDegraded();
        case 'error':
          throw BackendException(
            map['message']?.toString().trim().isNotEmpty == true
                ? map['message'].toString().trim()
                : 'AI 这轮没跑起来',
          );
        case 'final':
          yield AgentDone(AgentResult.fromJson(map));
          return; // final 之后服务端就关流了,不必再等
      }
    }

    // 流自己结束却没给过 final:服务端中途断了。当失败处理,不能让调用方
    // 以为「跑完了但什么都没改」—— 那会把一次失败伪装成一次闲聊。
    throw BackendException('AI 这轮没跑完就断了,再试一次');
  } finally {
    client.close();
  }
}
