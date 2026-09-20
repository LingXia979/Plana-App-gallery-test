import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_mode.dart';
import '../../core/auth/bot_session_store.dart';
import '../../core/auth/nai_keys.dart';
import '../../core/auth/token_probe.dart';
import '../../core/auth/token_store.dart';
import '../../core/live_progress/live_progress.dart';
import '../../core/net/nai_client.dart';
import '../../core/net/nai_endpoint.dart';
import '../../core/net/nai_proxy.dart';
import '../../core/store/gen_settings.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/theme_settings.dart';
import '../profile/widgets/credential_login_sheet.dart';
import '../profile/widgets/token_status.dart';
import 'bot_auth_panel.dart';
import '../../core/util/haptics.dart';

/// 首启欢迎流程:欢迎 → 外观 → 接入 → 通知,共 4 页。
/// 内容居中,页间横滑,元素错峰浮现;凭据在本页内就地配完,不再跳出去。
class WelcomePage extends ConsumerStatefulWidget {
  const WelcomePage({super.key, this.replay = false});

  /// 从关于页「重新查看引导」进来的重看模式。
  ///
  /// 首启时这个页面是 gate 的直接子级,走完只需置 `notifyPrimed`,gate 自己会
  /// 换成主界面 —— 没人 pop 它,也不该 pop。重看是 push 出来的路由,gate 早就
  /// 停在主界面了,不自己退就卡在完成页。
  final bool replay;

  @override
  ConsumerState<WelcomePage> createState() => _WelcomePageState();
}

class _WelcomePageState extends ConsumerState<WelcomePage> {
  static const _pageCount = 6;

  final _pager = PageController();
  int _index = 0;
  bool _finishing = false;

  /// 当前「算作激活」的页:滑过半程就翻牌,入场动画在拖动途中就开始演,
  /// 而不是等停稳(PageView 会提前建好各页,不这样每页的入场都在看不见时演完)。
  final _active = ValueNotifier<int>(0);

  @override
  void initState() {
    super.initState();
    _pager.addListener(_onScroll);
  }

  void _onScroll() {
    final p = (_pager.page ?? 0).round();
    if (p != _active.value) _active.value = p;
  }

  @override
  void dispose() {
    _pager
      ..removeListener(_onScroll)
      ..dispose();
    _active.dispose();
    super.dispose();
  }

  /// 每页外面套一层:激活状态变化时,页内元素重放错峰入场。
  Widget _page(int index, Widget Function(bool active) build) =>
      ValueListenableBuilder<int>(
        valueListenable: _active,
        builder: (_, a, _) => build(a == index),
      );

  void _next() {
    if (_index >= _pageCount - 1) return;
    _pager.nextPage(duration: Motion.medium, curve: Motion.emphasized);
  }

  /// 通知那页的选择:开则拉系统权限,记下开关,进完成页。
  /// 不等落盘——patch 会先同步改状态,落盘是尽力而为,等它反而卡住翻页。
  void _notifyChoice(bool on) {
    if (on) LiveProgress.instance.ensurePermission();
    ref
        .read(genSettingsProvider.notifier)
        .patch((s) => s.copyWith(genNotify: on));
    _next();
  }

  /// 收尾:兜底接入方式 → 记「引导已过」→ gate 换主界面(重看模式则自己退)。
  /// 全程没选接入方式的按直连处理,否则 gate 会把人又弹回来。
  void _finish() {
    if (_finishing) return;
    setState(() => _finishing = true);
    if (ref.read(authModeProvider).value == null) {
      ref.read(authModeProvider.notifier).set(AuthMode.token);
    }
    ref
        .read(genSettingsProvider.notifier)
        .patch((s) => s.copyWith(notifyPrimed: true));
    if (widget.replay && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final last = _index == _pageCount - 1;
    final mode = ref.watch(authModeProvider).value;
    final hasToken = (ref.watch(tokenProvider).value ?? '').isNotEmpty;
    final hasBot = ref.watch(botSessionProvider).value != null;

    // 接入页要「配好」才放行:选直连得真存了令牌,选 Bot 则下一页去授权。
    // 光点中直连却没填令牌,等于什么都没配,只能走「暂时跳过」。
    final needPick =
        _index == 2 && (mode == null || (mode == AuthMode.token && !hasToken));
    // Bot 授权页:选了 Bot 生成就非授权不可(不然根本生成不了),不给跳过;
    // 只为增强功能来的(生成走直连)则主按钮直接叫「跳过」。
    final botPage = _index == 3 && !hasBot;
    final mustAuth = botPage && mode == AuthMode.bot;
    final skipBot = botPage && !mustAuth;
    final notifyPage = _index == 4;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: PageView(
                controller: _pager,
                onPageChanged: (i) => setState(() => _index = i),
                children: [
                  _page(0, (a) => _IntroStep(active: a)),
                  _page(1, (a) => _AppearanceStep(active: a)),
                  _page(2, (a) => _AccessStep(active: a)),
                  _page(3, (a) => _BotStep(active: a)),
                  _page(4, (a) => _NotifyStep(active: a)),
                  _page(5, (a) => _DoneStep(active: a)),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 12),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      for (var i = 0; i < _pageCount; i++)
                        AnimatedContainer(
                          duration: Motion.fast,
                          curve: Motion.standard,
                          margin: const EdgeInsets.symmetric(horizontal: 3),
                          width: i == _index ? 20 : 7,
                          height: 7,
                          decoration: BoxDecoration(
                            color: i == _index
                                ? scheme.primary
                                : scheme.outlineVariant,
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  FilledButton(
                    onPressed: last
                        ? (_finishing ? null : _finish)
                        : notifyPage
                        ? () => _notifyChoice(true)
                        : (needPick || mustAuth ? null : _next),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(50),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(25),
                      ),
                    ),
                    child: Text(
                      last
                          ? '开始使用'
                          : notifyPage
                          ? '开启通知'
                          : skipBot
                          ? '跳过'
                          : '下一步',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  // 次要出口:通知页「暂不开启」,接入页「暂时跳过」(按直连处理)
                  SizedBox(
                    height: 40,
                    child: notifyPage
                        ? TextButton(
                            onPressed: () => _notifyChoice(false),
                            child: const Text('暂不开启'),
                          )
                        : needPick
                        ? TextButton(
                            onPressed: () {
                              ref
                                  .read(authModeProvider.notifier)
                                  .set(AuthMode.token);
                              _next();
                            },
                            child: const Text('暂时跳过'),
                          )
                        : null,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 每页统一骨架:内容整体居中,翻到本页时元素自下而上错峰淡入。
class _Step extends StatelessWidget {
  const _Step({
    required this.icon,
    required this.title,
    required this.active,
    this.desc,
    this.descBold,
    this.child,
  });

  final IconData icon;
  final String title;

  /// 是否为当前页;转 true 时重放入场。
  final bool active;
  final String? desc;

  /// [desc] 里要加粗的那一段(必须是 desc 的子串,否则忽略)。
  /// 只为强调一句话里的关键条件,不值得把 desc 整个换成 InlineSpan ——
  /// 四个调用点里三个是纯文本。
  final String? descBold;

  /// desc 正文;[descBold] 命中就把那一段加粗,其余照常。
  Widget _descText(BuildContext context, ColorScheme scheme) {
    final base = context.texts.bodyMedium!.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final text = desc!;
    final bold = descBold;
    if (bold != null && bold.isNotEmpty) {
      final at = text.indexOf(bold);
      if (at >= 0) {
        return Text.rich(
          TextSpan(
            children: [
              TextSpan(text: text.substring(0, at)),
              TextSpan(
                text: bold,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              TextSpan(text: text.substring(at + bold.length)),
            ],
          ),
          textAlign: TextAlign.center,
          style: base,
        );
      }
    }
    return Text(text, textAlign: TextAlign.center, style: base);
  }

  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(26, 20, 26, 12),
      child: ConstrainedBox(
        // 撑满可视高度才能真正居中,内容超高时退化为可滚
        constraints: BoxConstraints(
          minHeight:
              MediaQuery.sizeOf(context).height -
              MediaQuery.paddingOf(context).vertical -
              200,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _Rise(
              active: active,
              delayMs: 0,
              child: Container(
                width: 68,
                height: 68,
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: 32, color: scheme.onPrimaryContainer),
              ),
            ),
            const SizedBox(height: 20),
            _Rise(
              active: active,
              delayMs: 90,
              child: Text(
                title,
                textAlign: TextAlign.center,
                style: context.texts.headlineSmall!.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            if (desc != null) ...[
              const SizedBox(height: 8),
              _Rise(
                active: active,
                delayMs: 160,
                child: _descText(context, scheme),
              ),
            ],
            if (child != null) ...[
              const SizedBox(height: 26),
              _Rise(active: active, delayMs: 230, child: child!),
            ],
          ],
        ),
      ),
    );
  }
}

/// 自下而上淡入(延时错峰)。每次所在页被激活都重放,
/// 离开则复位——否则 PageView 预建各页,入场全在看不见时演完了。
class _Rise extends StatefulWidget {
  const _Rise({required this.child, required this.active, this.delayMs = 0});

  final Widget child;
  final bool active;
  final int delayMs;

  @override
  State<_Rise> createState() => _RiseState();
}

class _RiseState extends State<_Rise> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: Motion.slow,
  );

  @override
  void initState() {
    super.initState();
    if (widget.active) _play();
  }

  @override
  void didUpdateWidget(_Rise old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) {
      _play();
    } else if (!widget.active && old.active) {
      _c.value = 0; // 复位,下次进来重演
    }
  }

  void _play() {
    Future<void>.delayed(Duration(milliseconds: widget.delayMs), () {
      if (mounted && widget.active) _c.forward(from: 0);
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curved = CurvedAnimation(parent: _c, curve: Motion.emphasized);
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween(
          begin: const Offset(0, .1),
          end: Offset.zero,
        ).animate(curved),
        child: widget.child,
      ),
    );
  }
}

// ── 1 欢迎 ────────────────

class _IntroStep extends StatelessWidget {
  const _IntroStep({required this.active});

  final bool active;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return _Step(
      active: active,
      icon: Icons.auto_awesome,
      title: '欢迎使用 Plana',
      desc: 'NovelAI 移动创作端',
      child: Column(
        children: [
          for (final f in const [
            (Icons.edit_note, '全屏提示词编辑器'),
            (Icons.photo_library_outlined, '图库留参数,随时复现'),
            (Icons.auto_fix_high, 'Vibe · 参考 · 重绘 · 超分'),
          ])
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(f.$1, size: 17, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 9),
                  Text(
                    f.$2,
                    style: context.texts.bodySmall!.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ── 2 外观(选中即时换肤) ────────────────

class _AppearanceStep extends ConsumerWidget {
  const _AppearanceStep({required this.active});

  final bool active;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ts = ref.watch(themeSettingsProvider);
    final notifier = ref.read(themeSettingsProvider.notifier);
    final scheme = context.scheme;
    return _Step(
      active: active,
      icon: Icons.color_lens_outlined,
      title: '外观配色',
      child: Column(
        children: [
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<ThemeMode>(
              segments: const [
                ButtonSegment(value: ThemeMode.system, label: Text('跟随系统')),
                ButtonSegment(value: ThemeMode.light, label: Text('浅色')),
                ButtonSegment(value: ThemeMode.dark, label: Text('深色')),
              ],
              selected: {ts.mode},
              onSelectionChanged: (s) =>
                  notifier.patch((x) => x.copyWith(mode: s.first)),
              showSelectedIcon: false,
            ),
          ),
          const SizedBox(height: 24),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            alignment: WrapAlignment.center,
            children: [
              for (final s in themeSeeds)
                InkWell(
                  onTap: () =>
                      notifier.patch((x) => x.copyWith(seedKey: s.key)),
                  customBorder: const CircleBorder(),
                  child: AnimatedContainer(
                    duration: Motion.fast,
                    width: 42,
                    height: 42,
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        width: 2,
                        color: s.key == ts.seed.key
                            ? scheme.onSurface
                            : Colors.transparent,
                      ),
                    ),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: s.color,
                        shape: BoxShape.circle,
                      ),
                      child: s.key == ts.seed.key
                          ? Icon(
                              Icons.check,
                              size: 17,
                              color:
                                  ThemeData.estimateBrightnessForColor(
                                        s.color,
                                      ) ==
                                      Brightness.dark
                                  ? Colors.white
                                  : Colors.black87,
                            )
                          : null,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── 3 接入(就地配完,不跳页) ────────────────

class _AccessStep extends ConsumerStatefulWidget {
  const _AccessStep({required this.active});

  final bool active;

  @override
  ConsumerState<_AccessStep> createState() => _AccessStepState();
}

class _AccessStepState extends ConsumerState<_AccessStep>
    with SingleTickerProviderStateMixin {
  final _tokenCtrl = TextEditingController();
  final _urlCtrl = TextEditingController();
  bool _obscure = true;
  bool _saving = false;

  /// 直连卡里选的是第三方接口(地址跟这把令牌一起存,见 [NaiKey.endpoint])。
  /// 它不是第三种**接入方式** —— 接入方式仍是直连,只是不打官方那台机器,
  /// 所以做成卡内的分段而不是第三张卡。
  bool _third = false;

  /// 第三方地址填得不成形时的当场提示(官方那一路没有这一栏)。
  String? _urlError;

  /// 两张卡共用的切换动画:0 = 直连展开,1 = Bot 展开。
  /// 一条补间此消彼长,总高度单调变化,页面居中也不会被顶得一晃。
  late final AnimationController _swap = AnimationController(
    vsync: this,
    duration: Motion.medium,
    value: ref.read(authModeProvider).value == AuthMode.bot ? 1 : 0,
  );

  late final Animation<double> _botExpand = CurvedAnimation(
    parent: _swap,
    curve: Motion.emphasized,
    reverseCurve: Motion.emphasized.flipped,
  );

  late final Animation<double> _tokenExpand = ReverseAnimation(_botExpand);

  // 引导页贴的是官方令牌(第三方接口在令牌管理页添加),固定查官方。
  late final TokenProbe _probe = TokenProbe(
    (t) => ref.read(naiClientProvider('')).subscription(t),
  );

  @override
  void initState() {
    super.initState();
    _tokenCtrl.addListener(_onInput);
    _urlCtrl.addListener(_onUrl);
    _probe.addListener(_onProbe);
  }

  void _onProbe() {
    if (mounted) setState(() {});
  }

  void _onInput() {
    setState(() {});
    // 第三方不查:`/user/subscription` 是官方的东西,中转站大多没实现,
    // 查失败会在保存之前就摆一行红字,而那把 key 多半是好的。
    if (!_third) _probe.input(_tokenCtrl.text);
  }

  void _onUrl() => setState(() => _urlError = null);

  /// 代理开关(与「账号与接入」里那个是同一个)。刚才没查通的,换条线路再查
  /// 一次;已经查通的不重查 —— 令牌好坏跟走哪条线路无关。
  void _setProxy(bool on) {
    ref.read(naiProxyProvider.notifier).set(on);
    _probe.input(_tokenCtrl.text);
    Haptics.selection();
  }

  /// 官方 ↔ 第三方。切过去先把探测结果清掉 —— 那是刚才查官方留下的,
  /// 挂在第三方那一栏下面就是张冠李戴。
  void _switchThird(bool third) {
    if (third == _third) return;
    setState(() {
      _third = third;
      _urlError = null;
    });
    _probe.reset();
    if (!third) _probe.input(_tokenCtrl.text);
    Haptics.selection();
  }

  @override
  void dispose() {
    _swap.dispose();
    _probe
      ..removeListener(_onProbe)
      ..dispose();
    _tokenCtrl
      ..removeListener(_onInput)
      ..dispose();
    _urlCtrl
      ..removeListener(_onUrl)
      ..dispose();
    super.dispose();
  }

  Future<void> _paste(TextEditingController c) async {
    final d = await Clipboard.getData(Clipboard.kTextPlain);
    final t = d?.text?.trim();
    if (t == null || t.isEmpty) return;
    c.text = t;
    c.selection = TextSelection.collapsed(offset: c.text.length);
  }

  /// 能不能保存:官方只要有令牌,第三方还要有地址。地址的形态留到按下保存时
  /// 才校验 —— 边打边标红,打到一半全程都是红的。
  bool get _canSave =>
      !_saving &&
      _tokenCtrl.text.trim().isNotEmpty &&
      (!_third || _urlCtrl.text.trim().isNotEmpty);

  /// 卡内输入框的统一装饰(地址与令牌两栏同一套)。
  InputDecoration _fieldDec(
    ColorScheme scheme,
    String hint, {
    Widget? suffix,
  }) => InputDecoration(
    isDense: true,
    filled: true,
    fillColor: scheme.surfaceContainerHigh,
    hintText: hint,
    hintStyle: TextStyle(color: scheme.outline),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide.none,
    ),
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    suffixIcon: suffix,
  );

  Future<void> _saveToken() async {
    final t = _tokenCtrl.text.trim();
    if (t.isEmpty) return;
    // 第三方:地址跟这把 key 绑成一把存下。形态不对当场挡下;通不通不在这里探
    // —— 中转站多半没开 GET,探测失败反而拦住能用的地址。
    final url = _third ? normalizeNaiBase(_urlCtrl.text) : '';
    if (_third && (url.isEmpty || !naiBaseLooksValid(url))) {
      setState(() => _urlError = '请填 http:// 或 https:// 开头的接口地址');
      return;
    }
    setState(() => _saving = true);
    // 手贴的这把不带续期凭证,到期需重贴。凭证现在跟着每把 Key 存,所以不必
    // 再作废什么 —— 不存在「续期把令牌换成别的账号」这条老坑了。
    await ref.read(naiKeysStoreProvider.notifier).add(t, endpoint: url);
    if (!mounted) return;
    setState(() => _saving = false);
    await ref.read(authModeProvider.notifier).set(AuthMode.token);
    if (mounted) Haptics.selection();
  }

  /// 邮箱密码登录:sheet 里已换 JWT 并落盘,这里回填输入框(触发档位
  /// 查询)+ 把接入方式定为直连,与手动保存令牌走完同样的收尾。
  ///
  /// 只在官方那一路露出:登录走的是 NAI 官方账号体系,中转站不发这种账号。
  Future<void> _credentialLogin() async {
    final jwt = await showCredentialLoginSheet(context);
    if (jwt == null || !mounted) return;
    _tokenCtrl.text = jwt;
    _tokenCtrl.selection = TextSelection.collapsed(offset: jwt.length);
    await ref.read(authModeProvider.notifier).set(AuthMode.token);
  }

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(authModeProvider).value;
    final savedToken = (ref.watch(tokenProvider).value ?? '').isNotEmpty;
    final hasBot = ref.watch(botSessionProvider).value != null;
    final scheme = context.scheme;

    // 模式变化(含外部改动)驱动共享补间;没选过时两张卡都收着
    final bot = mode == AuthMode.bot;
    ref.listen(authModeProvider, (_, next) {
      final toBot = next.value == AuthMode.bot;
      if (toBot && _swap.status != AnimationStatus.forward) {
        _swap.forward();
      } else if (!toBot && _swap.status != AnimationStatus.reverse) {
        _swap.reverse();
      }
    });

    return _Step(
      active: widget.active,
      icon: Icons.key,
      title: '生成接入方式',
      desc: '之后可在「我的」里改',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _AccessCard(
            icon: Icons.vpn_key,
            title: '直连 NovelAI Token',
            note: savedToken ? '已保存' : null,
            selected: !bot,
            expand: _tokenExpand,
            onSelect: () =>
                ref.read(authModeProvider.notifier).set(AuthMode.token),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 官方 / 第三方是**同一种接入方式**的两台机器,所以做成卡内分段
                // 而不是第三张卡 —— 第三张卡会让人以为它跟 Bot 那条一样,
                // 是另一套账号体系。
                SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(value: false, label: Text('官方')),
                      ButtonSegment(value: true, label: Text('第三方')),
                    ],
                    selected: {_third},
                    showSelectedIcon: false,
                    // 卡内地方紧,收掉点按区外扩的那圈留白 —— 不收的话这一条
                    // 会比下面的输入框还高。
                    style: SegmentedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      textStyle: context.texts.labelMedium,
                    ),
                    onSelectionChanged: (v) => _switchThird(v.first),
                  ),
                ),
                // 直连是本机直打 NovelAI:网络到不了官网,令牌填对了也一样
                // 生成不了 —— 官方那一路就地给代理开关。第三方那一路打的是它
                // 自己那台,代理管不着,只留一句说明。
                AnimatedSize(
                  duration: Motion.fast,
                  curve: Motion.standard,
                  alignment: Alignment.topCenter,
                  child: _third
                      ? Padding(
                          padding: const EdgeInsets.fromLTRB(0, 9, 0, 9),
                          child: Text(
                            '兼容 NovelAI 接口的中转站或自建反代,地址跟这把 key 一起存',
                            style: context.texts.labelSmall!.copyWith(
                              color: scheme.outline,
                            ),
                          ),
                        )
                      : Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '代理访问 NovelAI',
                                      style: context.texts.labelMedium!
                                          .copyWith(
                                            color: scheme.onSurfaceVariant,
                                          ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      kNaiProxyHint,
                                      style: context.texts.labelSmall!.copyWith(
                                        color: scheme.outline,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Switch(
                                value: ref.watch(naiProxyProvider),
                                onChanged: _setProxy,
                                materialTapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                              ),
                            ],
                          ),
                        ),
                ),
                // 两种表单高矮不同,换分段时补成过渡,不然整张卡会啪地跳一下。
                AnimatedSize(
                  duration: Motion.fast,
                  curve: Motion.standard,
                  alignment: Alignment.topCenter,
                  child: _third
                      ? Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: TextField(
                            controller: _urlCtrl,
                            autocorrect: false,
                            enableSuggestions: false,
                            keyboardType: TextInputType.url,
                            textInputAction: TextInputAction.next,
                            style: mono(context, size: 12),
                            decoration: _fieldDec(
                              scheme,
                              'https://example.com',
                              suffix: IconButton(
                                onPressed: () => _paste(_urlCtrl),
                                icon: const Icon(Icons.content_paste, size: 18),
                                color: scheme.onSurfaceVariant,
                                visualDensity: VisualDensity.compact,
                              ),
                            ),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
                TextField(
                  controller: _tokenCtrl,
                  obscureText: _obscure,
                  autocorrect: false,
                  enableSuggestions: false,
                  keyboardType: TextInputType.visiblePassword,
                  style: mono(context, size: 12),
                  decoration: _fieldDec(
                    scheme,
                    _third ? '接口 key' : 'pst-… / eyJ…',
                    suffix: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          onPressed: () => _paste(_tokenCtrl),
                          icon: const Icon(Icons.content_paste, size: 18),
                          color: scheme.onSurfaceVariant,
                          visualDensity: VisualDensity.compact,
                        ),
                        IconButton(
                          onPressed: () => setState(() => _obscure = !_obscure),
                          icon: Icon(
                            _obscure ? Icons.visibility : Icons.visibility_off,
                            size: 18,
                          ),
                          color: scheme.onSurfaceVariant,
                          visualDensity: VisualDensity.compact,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    // 第三方不查账户状态,那一格就空着,只在地址填不成形时
                    // 摆一行红字 —— 借现成的空位说话,不给卡再加一段高度。
                    Expanded(
                      child: _third
                          ? Text(
                              _urlError ?? '',
                              style: context.texts.labelSmall!.copyWith(
                                color: scheme.error,
                              ),
                            )
                          : tokenStatusLine(
                              context,
                              _probe,
                              onRetry: () => _probe.run(_tokenCtrl.text),
                            ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.tonal(
                      onPressed: _canSave ? _saveToken : null,
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(72, 38),
                        visualDensity: VisualDensity.compact,
                      ),
                      child: Text(_saving ? '保存中' : '保存'),
                    ),
                  ],
                ),
                // 邮箱登录只在官方那一路露出:中转站不发 NAI 账号,
                // 摆在第三方下面等于给一条走不通的路。
                if (!_third)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: _credentialLogin,
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                      ),
                      icon: const Icon(Icons.mail_outline, size: 15),
                      label: const Text('没有令牌?用邮箱密码登录'),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          _AccessCard(
            icon: Icons.smart_toy_outlined,
            title: '用 Bot 账户生成',
            note: hasBot ? '已授权' : null,
            selected: bot,
            expand: _botExpand,
            onSelect: () =>
                ref.read(authModeProvider.notifier).set(AuthMode.bot),
            // 选了 Bot 就必须授权才放行(见 mustAuth),而授权是邀请制 ——
            // 不写清楚的话,拿不到邀请的人会卡在这一页不知道该往哪走,
            // 所以连出路一起说了。与上面那张卡的提示同一档字号/颜色。
            child: hasBot
                ? null
                : Text(
                    '需先完成 Bot 授权,当前仅为邀请制;没有邀请请先用直连 Token',
                    style: context.texts.labelSmall!.copyWith(
                      color: scheme.outline,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// 接入卡(轻量描边式):不填底色,选中只加主色描边 + 对勾,
/// 表单直接排在卡内、不再套第二层容器。
/// 展开高度由外部传入的 [expand] 驱动(两张卡共用一条补间)。
class _AccessCard extends StatelessWidget {
  const _AccessCard({
    required this.icon,
    required this.title,
    required this.selected,
    required this.expand,
    required this.onSelect,
    this.child,
    this.note,
  });

  final IconData icon;
  final String title;
  final bool selected;
  final Animation<double> expand;
  final VoidCallback onSelect;

  /// 选中后展开的表单;null = 这张卡没有可配的东西(选中只是选中)。
  final Widget? child;

  /// 右侧状态角标(已保存 / 已授权)。
  final String? note;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return AnimatedContainer(
      duration: Motion.fast,
      curve: Motion.standard,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          width: selected ? 2 : 1.5,
          color: selected ? scheme.primary : scheme.outlineVariant,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: Colors.transparent,
        child: Column(
          children: [
            InkWell(
              onTap: onSelect,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(13, 12, 13, 12),
                child: Row(
                  children: [
                    Icon(
                      icon,
                      size: 18,
                      color: selected
                          ? scheme.primary
                          : scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Text(
                        title,
                        style: context.texts.titleSmall!.copyWith(
                          fontWeight: FontWeight.w600,
                          color: selected
                              ? scheme.onSurface
                              : scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    if (note != null)
                      Text(
                        note!,
                        style: context.texts.labelSmall!.copyWith(
                          color: scheme.tertiary,
                        ),
                      ),
                    if (selected) ...[
                      const SizedBox(width: 6),
                      Icon(Icons.check_circle, size: 16, color: scheme.primary),
                    ],
                  ],
                ),
              ),
            ),
            if (child != null)
              SizeTransition(
                sizeFactor: expand,
                alignment: Alignment.topCenter,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(13, 0, 13, 13),
                  child: child,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ── 4 扩展功能(与生成方式解耦:选 Key 的人也能授权拿这些) ────────────────

class _BotStep extends ConsumerWidget {
  const _BotStep({required this.active});

  final bool active;

  /// 授权后开放的扩展功能。只列「没会话就真的用不了」的:翻译、统计这类
  /// 离线本来就有,不算。
  ///
  /// 增强标签补全**已不在此列** —— 它用到的后端接口都是公开的,2026-08-25 起
  /// 解除了 Bot 授权门禁,对所有人默认开启。留在这儿就是虚报门槛。
  static const _perks = <(IconData, String)>[
    (Icons.model_training, '额外模型:Anima · Krea 2'),
    (Icons.travel_explore, '公共库:Vibe · 画师串 · 角色 OC'),
    (Icons.cloud_upload_outlined, '云备份:Vibe 库与标签库跨设备同步'),
    (Icons.image_search, '图片反推标签(WD Tagger)'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = context.scheme;
    final hasBot = ref.watch(botSessionProvider).value != null;
    final needForGen = ref.watch(authModeProvider).value == AuthMode.bot;

    return _Step(
      active: active,
      icon: Icons.smart_toy_outlined,
      title: '扩展功能',
      desc: needForGen
          ? '你选了用 Bot 账户生成,需要先授权'
          : hasBot
          ? ''
          : '以下扩展功能需通过 Bot 授权后开放,当前仅为邀请制;'
                '不授权不影响扩展功能以外的任何功能',
      descBold: '当前仅为邀请制',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final p in _perks)
            Padding(
              padding: const EdgeInsets.only(bottom: 9),
              child: Row(
                children: [
                  Icon(
                    hasBot ? Icons.check : p.$1,
                    size: 16,
                    color: hasBot ? scheme.tertiary : scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      p.$2,
                      style: context.texts.bodySmall!.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 12),
          if (hasBot)
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.verified_outlined, size: 17, color: scheme.tertiary),
                const SizedBox(width: 6),
                Text(
                  '已授权',
                  style: context.texts.bodyMedium!.copyWith(
                    color: scheme.tertiary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            )
          else
            const BotAuthPanel(compact: true),
        ],
      ),
    );
  }
}

// ── 5 通知 ────────────────

class _NotifyStep extends StatelessWidget {
  const _NotifyStep({required this.active});

  final bool active;

  @override
  Widget build(BuildContext context) {
    return _Step(
      active: active,
      icon: Icons.notifications_active_outlined,
      title: '生成进度通知',
      desc: '开启后可接收生成进度及完成通知,Android 16+ 支持灵动岛显示',
    );
  }
}

// ── 6 完成 ────────────────

/// 庆祝页:一个放大浮现的对勾 + 一句「全部完成」,再无别的。
class _DoneStep extends StatelessWidget {
  const _DoneStep({required this.active});

  final bool active;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Pop(
            active: active,
            child: Container(
              width: 108,
              height: 108,
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.check_rounded,
                size: 58,
                color: scheme.onPrimaryContainer,
              ),
            ),
          ),
          const SizedBox(height: 26),
          _Rise(
            active: active,
            delayMs: 220,
            child: Text(
              '全部完成',
              style: context.texts.headlineSmall!.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 弹入:回弹式放大 + 淡入(庆祝页的对勾用)。
class _Pop extends StatefulWidget {
  const _Pop({required this.child, required this.active});

  final Widget child;
  final bool active;

  @override
  State<_Pop> createState() => _PopState();
}

class _PopState extends State<_Pop> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 620),
  );

  @override
  void initState() {
    super.initState();
    if (widget.active) _c.forward();
  }

  @override
  void didUpdateWidget(_Pop old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) {
      _c.forward(from: 0);
    } else if (!widget.active && old.active) {
      _c.value = 0;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ScaleTransition(
    scale: CurvedAnimation(parent: _c, curve: Curves.elasticOut),
    child: FadeTransition(
      opacity: CurvedAnimation(
        parent: _c,
        curve: const Interval(0, .35, curve: Curves.easeOut),
      ),
      child: widget.child,
    ),
  );
}
