/// AI 助手给的角色提议 → 可用的角色卡。
///
/// 单独成文件是因为它有**两个调用方**,规则必须只有一份:
///   · [GenerateNotifier.applyAgentCharacters] —— 用户点「导入」时真的落到创作页
///   · AI 结果卡的「直接生成」 —— 只算出一份要发的状态,不碰创作页
/// 两边只要有一处自己抄一遍,同一份提议导入和直接生成就会摆出两种构图,
/// 而这种漂移在界面上完全看不出来。
library;

import 'char_position.dart';
import 'models.dart';

/// 把 AI 的角色提议落成角色卡。返回**卡列表**与 **AI 有没有真的摆过位置**。
///
/// **只看 AI 这一份,不读画布。** 画布和 AI 两边是彻底分开的,交集只有两处且
/// 都要手动:发送前点「引用创作页」(读),结果卡上点「导入」(写)。原先 AI 没给
/// 站位的角色会按位继承画布上同位旧角色的坐标 —— 那是一次没人按过的读。
///
/// AI 没给站位(空串)的,挑一个空格放;**空串不是「放正中」**。
/// 引用过创作页的那一轮,服务端会要求 AI 把 position 原样带回来,构图就不会丢。
///
/// 超出当前模型上限的直接截断(V4/V4.5 六个、V5 三十二个,见 [maxCharactersOf])。
///
/// 返回的 `placed` 为真时要把 `use_coords` 打开,为假时关掉:坐标开关也跟着
/// AI 这份走,不留画布上的旧值。开着而 AI 没摆位的话,发出去的是一堆默认空格。
({List<CharacterPrompt> chars, bool placed}) buildAgentCharacters(
  List<({String name, String positive, String negative, String position})>
  items, {
  required String model,
  required String Function() newId,
}) {
  final cap = maxCharactersOf(model);
  final out = <CharacterPrompt>[];
  var placed = false;
  for (var i = 0; i < items.length && out.length < cap; i++) {
    final it = items[i];
    final given = it.position.trim();
    if (given.isNotEmpty) placed = true;
    out.add(
      CharacterPrompt(
        id: newId(),
        name: it.name.trim().isNotEmpty
            ? it.name.trim()
            : '角色 ${out.length + 1}',
        positive: it.positive,
        negative: it.negative,
        position: given.isNotEmpty
            ? given
            : nextSpawnPosition(
                out.map((c) => c.position),
                freeform: isNai5Model(model),
              ),
      ),
    );
  }
  return (chars: out, placed: placed);
}
