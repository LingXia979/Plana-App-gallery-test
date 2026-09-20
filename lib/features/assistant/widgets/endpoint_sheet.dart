/// 添加 / 编辑一个自定义 AI 接口。
///
/// 四样必填之外还给一颗「拉取模型列表」:模型 id 抄错一个字符的表现是发出去 404,
/// 而 404 在中转服务上又常被包成别的错,查半天查不到根因。拉不到也不拦着 ——
/// 有些自建服务压根没有列表接口,手填照样能用。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/ui/setting_row.dart';
import '../../generate/widgets/common.dart' show confirmDialog, hintSnack;
import '../custom_endpoint.dart';
import '../custom_endpoint_api.dart';

/// [source] 非空 = 编辑那一条;空 = 新建。
Future<void> showEndpointSheet(
  BuildContext context, {
  CustomEndpoint? source,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: false,
  backgroundColor: Colors.transparent,
  barrierColor: Colors.black.withValues(alpha: .18),
  // 键盘顶上来时整个表单跟着抬,不然填 API Key 那行会被挡住
  builder: (_) => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
    child: _EndpointSheet(source: source),
  ),
);

class _EndpointSheet extends ConsumerStatefulWidget {
  const _EndpointSheet({this.source});

  final CustomEndpoint? source;

  @override
  ConsumerState<_EndpointSheet> createState() => _EndpointSheetState();
}

class _EndpointSheetState extends ConsumerState<_EndpointSheet> {
  late final _name = TextEditingController(text: widget.source?.name ?? '');
  late final _base = TextEditingController(text: widget.source?.baseUrl ?? '');
  late final _key = TextEditingController(text: widget.source?.apiKey ?? '');
  late final _model = TextEditingController(text: widget.source?.model ?? '');
  late final _path = TextEditingController(text: widget.source?.apiPath ?? '');

  late AgentApiFormat _format = widget.source?.format ?? AgentApiFormat.openai;
  bool _loading = false;

  @override
  void dispose() {
    _name.dispose();
    _base.dispose();
    _key.dispose();
    _model.dispose();
    _path.dispose();
    super.dispose();
  }

  CustomEndpoint _draft() => CustomEndpoint(
    id: widget.source?.id ?? ref.read(customEndpointsProvider.notifier).newId(),
    name: _name.text.trim(),
    format: _format,
    baseUrl: _base.text.trim(),
    apiKey: _key.text.trim(),
    model: _model.text.trim(),
    apiPath: _path.text.trim(),
  );

  Future<void> _pickModel() async {
    final draft = _draft();
    if (draft.apiKey.isEmpty) {
      hintSnack(context, '先填 API Key 才能拉列表', icon: Icons.key_off_outlined);
      return;
    }
    setState(() => _loading = true);
    List<String> models;
    try {
      models = await fetchModelList(draft);
    } on EndpointException catch (e) {
      if (mounted) hintSnack(context, e.message, icon: Icons.error_outline);
      return;
    } catch (e) {
      if (mounted) hintSnack(context, '拉取失败:$e', icon: Icons.error_outline);
      return;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
    if (!mounted) return;
    final picked = await _showModelPicker(context, models, _model.text.trim());
    if (picked != null && mounted) setState(() => _model.text = picked);
  }

  Future<void> _save() async {
    final draft = _draft();
    if (draft.model.isEmpty) {
      hintSnack(context, '还没填模型', icon: Icons.error_outline);
      return;
    }
    if (draft.apiKey.isEmpty) {
      hintSnack(context, '还没填 API Key', icon: Icons.key_off_outlined);
      return;
    }
    await ref.read(customEndpointsProvider.notifier).put(draft);
    if (mounted) unawaited(Navigator.of(context).maybePop());
  }

  Future<void> _delete() async {
    final id = widget.source?.id;
    if (id == null) return;
    final ok = await confirmDialog(
      context,
      title: '删除这个接口?',
      message: '地址和 API Key 都会从本机删除。已经发生过的对话不受影响。',
      confirmLabel: '删除',
    );
    if (!ok || !mounted) return;
    await ref.read(customEndpointsProvider.notifier).remove(id);
    if (mounted) unawaited(Navigator.of(context).maybePop());
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return SettingSheet(
      title: widget.source == null ? '添加接口' : '编辑接口',
      children: [
        settingSection(context, '格式'),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 2, 20, 6),
          child: SegmentedButton<AgentApiFormat>(
            segments: [
              for (final f in AgentApiFormat.values)
                ButtonSegment(value: f, label: Text(agentApiFormatLabel(f))),
            ],
            selected: {_format},
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            onSelectionChanged: (v) => setState(() => _format = v.first),
          ),
        ),
        _field(
          '接口地址',
          _base,
          hint: agentApiDefaultBase(_format),
          keyboard: TextInputType.url,
        ),
        // 中转改路径是常事;Gemini 那条还得把模型名写进路径,所以给了 {model} 占位
        _field(
          '接口路径',
          _path,
          hint: agentApiDefaultPath(_format),
          keyboard: TextInputType.url,
        ),
        _field('API Key', _key, obscure: true),
        settingSection(context, '模型'),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 2, 20, 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _model,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    isDense: true,
                    labelText: '模型',
                    hintText: 'gpt-5.6-luna',
                    floatingLabelBehavior: FloatingLabelBehavior.always,
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                height: 48,
                child: FilledButton.tonal(
                  onPressed: _loading ? null : _pickModel,
                  child: _loading
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('模型列表'),
                ),
              ),
            ],
          ),
        ),
        _field('名称', _name, hint: '不填就显示模型名'),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
          child: Row(
            children: [
              if (widget.source != null)
                TextButton(
                  onPressed: _delete,
                  style: TextButton.styleFrom(foregroundColor: scheme.error),
                  child: const Text('删除'),
                ),
              const Spacer(),
              FilledButton(onPressed: _save, child: const Text('保存')),
            ],
          ),
        ),
      ],
    );
  }

  Widget _field(
    String label,
    TextEditingController c, {
    String? hint,
    bool obscure = false,
    TextInputType? keyboard,
  }) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 6, 20, 6),
    child: TextField(
      controller: c,
      obscureText: obscure,
      keyboardType: keyboard,
      autocorrect: false,
      enableSuggestions: !obscure,
      decoration: InputDecoration(
        isDense: true,
        labelText: label,
        hintText: hint,
        // 标签**恒浮**:不浮的话 Material 会把 hint 藏到聚焦之后才显示,
        // 而这几格的 hint 正是「留空就用这个」的示例 —— 看不见等于没写。
        floatingLabelBehavior: FloatingLabelBehavior.always,
        border: const OutlineInputBorder(),
      ),
    ),
  );
}

/// 模型列表选择器。条数可能上百,给个搜索框。
Future<String?> _showModelPicker(
  BuildContext context,
  List<String> models,
  String current,
) => showModalBottomSheet<String>(
  context: context,
  isScrollControlled: true,
  builder: (_) => _ModelPicker(models: models, current: current),
);

class _ModelPicker extends StatefulWidget {
  const _ModelPicker({required this.models, required this.current});

  final List<String> models;
  final String current;

  @override
  State<_ModelPicker> createState() => _ModelPickerState();
}

class _ModelPickerState extends State<_ModelPicker> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final q = _q.trim().toLowerCase();
    final list = [
      for (final m in widget.models)
        if (q.isEmpty || m.toLowerCase().contains(q)) m,
    ];
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .8,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 2, 20, 8),
              child: TextField(
                autofocus: true,
                onChanged: (v) => setState(() => _q = v),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: '搜索 ${widget.models.length} 个模型',
                  prefixIcon: const Icon(Icons.search, size: 20),
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
            Flexible(
              child: ListView.builder(
                itemCount: list.length,
                itemBuilder: (context, i) {
                  final m = list[i];
                  final sel = m == widget.current;
                  return ListTile(
                    dense: true,
                    title: Text(
                      m,
                      style: TextStyle(
                        fontWeight: sel ? FontWeight.w700 : null,
                        color: sel ? scheme.primary : null,
                      ),
                    ),
                    trailing: sel
                        ? Icon(Icons.check, size: 18, color: scheme.primary)
                        : null,
                    onTap: () => Navigator.pop(context, m),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
