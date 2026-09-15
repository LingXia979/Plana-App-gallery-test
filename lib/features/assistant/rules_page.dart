/// 规则预设页:每个模型在用哪一份、导入、导出、删除。
///
/// 一张卡一份预设。默认规则按模型分两张(v4.5 版、v5 版),名称、作者、版本读服务端
/// 预设顶层的 meta。**点卡片就用这份**,正在用的卡右上角挂一个「使用中」角标。
/// 每个模型恰好有一张卡在用,默认规则兜底。
///
/// 不做编辑器:手机上改几千字的规则很难受,而规则文件的写法和服务端预设一致,
/// 在电脑上改完导进来更顺手。
library;

import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/bot_session_store.dart';
import '../../core/net/backend_config.dart';
import '../../core/theme/app_theme.dart';
import '../../core/util/haptics.dart';
import '../generate/widgets/common.dart' show confirmDialog, hintSnack;
import 'preset_rules.dart';

class RulesPresetPage extends ConsumerWidget {
  const RulesPresetPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lib = ref.watch(rulesLibraryProvider).value;
    return Scaffold(
      appBar: AppBar(
        title: const Text('规则预设'),
        actions: [
          IconButton(
            tooltip: '导入',
            onPressed: () => _import(context, ref),
            icon: const Icon(Icons.file_open_outlined),
          ),
        ],
      ),
      body: lib == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(14, 4, 14, 24),
              children: [
                for (final p in lib.all)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _card(context, ref, lib, p),
                  ),
              ],
            ),
    );
  }

  Widget _card(
    BuildContext context,
    WidgetRef ref,
    RulesLibrary lib,
    RulesPreset p,
  ) {
    final inUse = {
      for (final f in RulesFamily.values)
        if (lib.activeFor(f).id == p.id) f,
    };
    void onUse(RulesFamily f) {
      Haptics.selection();
      ref.read(rulesLibraryProvider.notifier).use(f, p.id);
    }

    if (p.isDefault) {
      // 默认规则只支持一个模型;名称、作者、版本读服务端预设,没取到时用占位值
      final f = p.models.single;
      final info = ref.watch(defaultRulesProvider(f)).value;
      return _PresetCard(
        title: info?.name ?? p.name,
        subtitle: [
          info?.author ?? p.author,
          '${info?.version ?? defaultRulesVersionOf(f)} 版',
        ].where((s) => s.isNotEmpty).join(' · '),
        isDefault: true,
        models: p.models,
        inUse: inUse,
        onUse: onUse,
        onExport: () => _exportDefault(context, ref, f),
      );
    }
    return _PresetCard(
      title: p.name,
      subtitle: [
        if (p.author.isNotEmpty) p.author,
        '${p.rules.length} 段',
      ].join(' · '),
      isDefault: false,
      models: p.models,
      inUse: inUse,
      onUse: onUse,
      onExport: () => _save(
        context,
        name: p.name,
        author: p.author,
        models: p.models,
        rules: p.rules,
        fileName: 'plana-rules-${_safe(p.name)}.yaml',
      ),
      onDelete: () => _delete(context, ref, p),
    );
  }

  Future<void> _import(BuildContext context, WidgetRef ref) async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.any,
      withData: true,
    );
    final picked = res?.files.firstOrNull;
    final bytes = picked?.bytes;
    if (picked == null || bytes == null || !context.mounted) return;

    final RulesFile file;
    try {
      file = decodeRulesFile(utf8.decode(bytes), fileName: picked.name);
    } on FormatException catch (e) {
      hintSnack(context, e.message, icon: Icons.error_outline);
      return;
    } catch (_) {
      hintSnack(context, '读不了这个文件,请确认是 UTF-8 文本', icon: Icons.error_outline);
      return;
    }

    // 名字、作者、模型让用户过一眼:服务端预设文件里压根没写这几样,
    // 文件里写了的也可能想改个自己认得出的名字
    final meta = await showModalBottomSheet<_ImportMeta>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _ImportSheet(file: file),
    );
    if (meta == null || !context.mounted) return;
    await ref
        .read(rulesLibraryProvider.notifier)
        .add(
          name: meta.name,
          author: meta.author,
          models: meta.models,
          rules: file.rules,
        );
    if (context.mounted) {
      hintSnack(context, '已导入「${meta.name}」', icon: Icons.check_circle_outline);
    }
  }

  /// 默认规则导出的是服务端**最新**那份,名字带上版本(「Nyako v5」)——
  /// 两个版本同名,导进来之后分不出哪张是哪张。
  Future<void> _exportDefault(
    BuildContext context,
    WidgetRef ref,
    RulesFamily f,
  ) async {
    try {
      final d = await fetchDefaultRules(
        f,
        backendBase: ref.read(backendBaseProvider).value ?? '',
        sessionId: (await ref.read(botSessionProvider.future))?.sessionId ?? '',
        fresh: true,
      );
      if (!context.mounted) return;
      await _save(
        context,
        name: '${d.name} ${d.version}'.trim(),
        author: d.author,
        models: {f},
        rules: d.rules,
        fileName: 'plana-rules-${_safe('${d.name}-${d.version}')}.yaml',
      );
    } catch (e) {
      if (context.mounted) {
        hintSnack(context, '导出失败:$e', icon: Icons.error_outline);
      }
    }
  }

  Future<void> _save(
    BuildContext context, {
    required String name,
    required String author,
    required Set<RulesFamily> models,
    required List<PresetRule> rules,
    required String fileName,
  }) async {
    try {
      final path = await FilePicker.platform.saveFile(
        fileName: fileName,
        bytes: utf8.encode(
          encodeRulesFile(
            name: name,
            author: author,
            models: models,
            rules: rules,
          ),
        ),
      );
      if (path != null && context.mounted) {
        hintSnack(context, '已导出「$name」', icon: Icons.check_circle_outline);
      }
    } catch (e) {
      if (context.mounted) {
        hintSnack(context, '导出失败:$e', icon: Icons.error_outline);
      }
    }
  }

  /// 文件名里别带路径分隔符和系统不认的字符。
  String _safe(String s) => s.replaceAll(RegExp(r'[\\/:*?"<>|\s]+'), '_');

  Future<void> _delete(
    BuildContext context,
    WidgetRef ref,
    RulesPreset p,
  ) async {
    final ok = await confirmDialog(
      context,
      title: '删除预设?',
      message: '「${p.name}」将被删除,正在使用它的模型改用默认规则。',
      confirmLabel: '删除',
    );
    if (!ok) return;
    await ref.read(rulesLibraryProvider.notifier).remove(p.id);
  }
}

class _PresetCard extends StatelessWidget {
  const _PresetCard({
    required this.title,
    required this.subtitle,
    required this.isDefault,
    required this.models,
    required this.inUse,
    required this.onUse,
    required this.onExport,
    this.onDelete,
  });

  final String title;
  final String subtitle;
  final bool isDefault;

  /// 这份支持的模型。
  final Set<RulesFamily> models;

  /// 正在用这份的模型。
  final Set<RulesFamily> inUse;
  final ValueChanged<RulesFamily> onUse;
  final VoidCallback onExport;

  /// 默认规则删不了,传 null。
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final allInUse = models.every(inUse.contains);
    // 支持两个模型、只在其中一个上用着的,角标说清是哪一个;其余只说「使用中」
    final badge = inUse.isEmpty
        ? null
        : allInUse
        ? '使用中'
        : '${inUse.map(rulesFamilyLabel).join('、')} 使用中';
    final notInUse = [
      for (final f in RulesFamily.values)
        if (models.contains(f) && !inUse.contains(f)) f,
    ];
    return Material(
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: inUse.isNotEmpty
            ? BorderSide(color: scheme.primary, width: 1.4)
            : BorderSide.none,
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        // 点卡片 = 支持的模型都改用这份。两个模型想分开用的,走右边菜单里的「用于」
        onTap: notInUse.isEmpty
            ? null
            : () {
                for (final f in notInUse) {
                  onUse(f);
                }
              },
        child: Stack(
          children: [
            Padding(
              // 上下对称,标题那两行在卡片里垂直居中。角标是叠在上面的
              // (Positioned),不占高度;躲它靠的是把右边菜单按钮收小,不是加边距
              padding: const EdgeInsets.fromLTRB(16, 10, 2, 10),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: context.texts.bodyLarge!.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            if (isDefault) const _Tag('默认'),
                            for (final f in RulesFamily.values)
                              if (models.contains(f)) _Tag(rulesFamilyLabel(f)),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          style: context.texts.labelSmall!.copyWith(
                            color: scheme.outline,
                          ),
                        ),
                      ],
                    ),
                  ),
                  PopupMenuButton<String>(
                    tooltip: '更多',
                    // 自带的是 48 见方的图标按钮,在这么矮的卡里会顶到右上角的
                    // 角标;换成 36 见方,整张卡本身也能点,够用
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Icon(
                        Icons.more_vert,
                        size: 20,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    onSelected: (v) => switch (v) {
                      'delete' => onDelete?.call(),
                      'export' => onExport(),
                      _ => onUse(RulesFamily.values.byName(v)),
                    },
                    itemBuilder: (_) => [
                      // 单模型的点卡片就够了;两个模型的才需要分开指定
                      if (models.length > 1)
                        for (final f in notInUse)
                          PopupMenuItem(
                            value: f.name,
                            child: Text('用于 ${rulesFamilyLabel(f)}'),
                          ),
                      const PopupMenuItem(value: 'export', child: Text('导出')),
                      if (onDelete != null)
                        PopupMenuItem(
                          value: 'delete',
                          child: Text(
                            '删除',
                            style: TextStyle(color: scheme.error),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            if (badge != null)
              Positioned(
                top: 0,
                right: 0,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(8, 1, 11, 2),
                  decoration: BoxDecoration(
                    color: scheme.primary,
                    borderRadius: const BorderRadius.only(
                      bottomLeft: Radius.circular(10),
                    ),
                  ),
                  child: Text(
                    badge,
                    style: context.texts.labelSmall!.copyWith(
                      color: scheme.onPrimary,
                      height: 1.2,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 标题后面那几枚小标签:默认、支持的模型。
class _Tag extends StatelessWidget {
  const _Tag(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: context.texts.labelSmall!.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

typedef _ImportMeta = ({String name, String author, Set<RulesFamily> models});

/// 导入前过一眼:名字、作者、支持的模型。文件里写了就预先填上。
class _ImportSheet extends StatefulWidget {
  const _ImportSheet({required this.file});

  final RulesFile file;

  @override
  State<_ImportSheet> createState() => _ImportSheetState();
}

class _ImportSheetState extends State<_ImportSheet> {
  late final _name = TextEditingController(text: widget.file.name);
  late final _author = TextEditingController(text: widget.file.author);
  late final Set<RulesFamily> _models = {...widget.file.models};

  @override
  void dispose() {
    _name.dispose();
    _author.dispose();
    super.dispose();
  }

  bool get _ok => _name.text.trim().isNotEmpty && _models.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final conditional = widget.file.rules.any((r) => r.when.isNotEmpty);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        16,
        20,
        16 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '导入规则预设',
            style: context.texts.titleMedium!.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            [
              '共 ${widget.file.rules.length} 段',
              if (conditional) '含条件段',
            ].join(' · '),
            style: context.texts.labelSmall!.copyWith(color: scheme.outline),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _name,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              labelText: '预设名称',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _author,
            decoration: const InputDecoration(
              labelText: '作者',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            '支持的模型',
            style: context.texts.labelLarge!.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              for (final f in RulesFamily.values)
                FilterChip(
                  label: Text(rulesFamilyLabel(f)),
                  selected: _models.contains(f),
                  onSelected: (v) =>
                      setState(() => v ? _models.add(f) : _models.remove(f)),
                ),
            ],
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _ok
                ? () => Navigator.pop(context, (
                    name: _name.text.trim(),
                    author: _author.text.trim(),
                    models: {..._models},
                  ))
                : null,
            child: const Text('导入'),
          ),
        ],
      ),
    );
  }
}
