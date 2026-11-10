import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/sessions_state.dart';
import '../chat/chat_screen.dart';
import '../settings/settings_screen.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'notara_canvas.dart';
import 'teaching_drawer.dart';
import 'teaching_top_bar.dart';
import 'teaching_types.dart';

/// 教学主壳:一行顶栏 + 三视图。
///
/// ```
/// ┌───────────────────────────────────────────────┐
/// │ ◧   [ 对话 | 白板 | 教室 ]   ⏱ 🎚 📄 ⋯   ◌  │  50dp
/// ├───────────────────────────────────────────────┤
/// │                                               │
/// │   对话 = 原生 ChatScreen                       │
/// │   白板 / 教室 = 同一个 WebView,JS 切视图        │
/// │                                               │
/// └───────────────────────────────────────────────┘
/// ```
///
/// 五条不许破的规矩:
/// 1. 对话页是原生 Flutter,不套 WebView,消息级更不行;
/// 2. 白板与教室只有一个 WebView,切视图不重新加载——这是 0 白屏的前提;
/// 3. 原生对话与画布**同时挂在树上**,靠不透明度换层。卸载再挂会重建
///    Android Surface,那半秒黑屏就是"切白板闪一下"的来源;
/// 4. 每次切视图都带着**当前这节课的 sessionId**,白板才会画同一道题;
/// 5. 回到对话页时网页只停 CSS 动画,**不冻结 JS**:后台还要继续收流、
///    继续把函数图画完,一右滑就能看见画好的那张。
class TeachingShell extends ConsumerStatefulWidget {
  const TeachingShell({super.key, this.onOpenDrawer});

  /// 外层(HomeShell)的抽屉回调。为 null 时用本壳自己的抽屉。
  final VoidCallback? onOpenDrawer;

  /// 视图切换的过渡时长。带在类上,测试与「右滑进白板」共用同一个数。
  static const Duration fade = Duration(milliseconds: 180);

  @override
  ConsumerState<TeachingShell> createState() => _TeachingShellState();
}

class _TeachingShellState extends ConsumerState<TeachingShell> {
  TeachingView _view = TeachingView.chat;

  /// 画布控制器:initState 里读一次存成字段。
  ///
  /// dispose 里 riverpod 禁止再碰 `ref`(那时 element 已经脱树,读就抛
  /// StateError——CI 的 discard_guard / remote_traffic 就是这么红的)。
  /// 摘 `onSessionOpened` 回调只能走这个字段。
  late final NotaraCanvasController _canvas;

  /// 纯净阅读:收掉顶栏与输入区,整屏只剩正文。
  bool _pure = false;

  /// 顶栏浮层(`⋯` 或兜底说明)是否开着——返回键第一级要能关掉它。
  bool _sheetOpen = false;

  final _scaffold = GlobalKey<ScaffoldState>();

  /// 空课号时,第一次在这节课里打字就现开一节课堂。
  bool _ensuring = false;

  @override
  void initState() {
    super.initState();
    // 唯一一次用 ref 拿控制器,之后都走 _canvas 字段。
    _canvas = ref.read(notaraCanvasProvider);
    // 进 App 就预热画布:对话页在用的时候,网页在后台把首屏拉起来。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _canvas.onSessionOpened = _onSessionOpened;
      unawaited(_canvas.warmUp(ref));
      // 注意:这里不 pause。网页要在后台把白板画完,冻结 JS 就画不出来。
    });
  }

  @override
  void dispose() {
    // 回调挂在全局控制器上,壳走了必须摘掉,否则会指向一个已销毁的 State。
    // 走字段,不走 ref——dispose 里 ref 已失效。
    _canvas.onSessionOpened = null;
    super.dispose();
  }

  bool get _drawerOpen => _scaffold.currentState?.isDrawerOpen ?? false;

  /// 当前这节课的 id:优先网页报上来的,其次原生选中的。
  String? get _sessionId =>
      ref.read(notaraCanvasProvider).activeSessionId ?? ref.read(currentSessionProvider);

  void _switch(TeachingView view) {
    if (view == _view) return;
    HapticFeedback.selectionClick();
    if (view == TeachingView.board) {
      ref.read(notaraCanvasProvider).clearBoardFresh();
    }
    setState(() => _view = view);
    final canvas = ref.read(notaraCanvasProvider);
    if (view == TeachingView.chat) {
      // 对话在前台:网页继续待命(不冻结),只是不再抢焦点。
      unawaited(canvas.show(TeachingView.chat, sessionId: _sessionId));
    } else {
      // 带上当前课号:不带的话白板只能自己猜一节课,猜错就是另一道题。
      unawaited(canvas.show(view, sessionId: _sessionId));
    }
  }

  void _enterPure() {
    HapticFeedback.mediumImpact();
    setState(() {
      _pure = true;
      // 纯净阅读看的是内容;顶栏与输入区一起退场,只留正文。
    });
  }

  void _exitPure() {
    HapticFeedback.selectionClick();
    setState(() => _pure = false);
  }

  /// 纯净态下右滑:切到纯净白板,看老师画的函数与几何图像。
  ///
  /// 过渡是真的 180ms 淡入淡出([TeachingShell.fade]),两层同时在树上,靠
  /// 不透明度换,所以能看见交叉淡化。切过去先按视口宽度排一次白板。
  void _pureSwipeToBoard() {
    if (!_pure) return;
    if (_view == TeachingView.board) return;
    HapticFeedback.mediumImpact();
    setState(() => _view = TeachingView.board);
    final canvas = ref.read(notaraCanvasProvider);
    canvas.clearBoardFresh();
    unawaited(canvas.show(TeachingView.board, sessionId: _sessionId));
  }

  /// 纯净白板左边缘向右滑:**回到纯净对话页**,仍然没有任何 UI。
  ///
  /// 这里不退出纯净——退出只走右上角 `◌` 与安卓返回键。手势只负责在
  /// "看图"和"看文"之间来回,不顺手把阅读状态改掉。
  void _pureBackToChat() {
    if (!_pure || _view != TeachingView.board) return;
    HapticFeedback.selectionClick();
    setState(() => _view = TeachingView.chat);
  }

  /// 网页开课了(首页选目录、题库点题、计划开课)。
  ///
  /// 已确认的交互:点题即开课即进原生对话页,不停在网页看题目详情。所以这里
  /// 直接把原生对话切到同一个 sessionId,并回到对话视图。
  void _onSessionOpened(String sessionId, String view) {
    if (!mounted) return;
    // 已经是这节课:多半是外壳自己调进去的回声,不重复切,也不打断输入。
    if (ref.read(currentSessionProvider) == sessionId) return;
    ref.read(currentSessionProvider.notifier).select(sessionId);
    if (_view != TeachingView.chat) {
      setState(() => _view = TeachingView.chat);
    }
  }

  Future<void> _onSection(TeachingSection section) async {
    if (!section.livesInWeb) {
      // 设置是 DSH 自己的页面,Notara 内部没有它。交给原生打开,而不是把
      // `settings` 丢给网页去找一个不存在的入口然后"没反应"。
      //
      // 这一项**不能丢**:全新安装要先在这里配模型服务商的 API Key。
      await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen()));
      return;
    }
    // 其余四项落在画布上。用 section 这个独立状态:顶栏三个页签一个都不亮,
    // 不会出现"从抽屉进题库、顶栏却高亮教室"。
    setState(() => _view = TeachingView.section);
    await ref.read(notaraCanvasProvider).showSection(section);
  }

  Future<void> _onLesson(String sessionId) async {
    // 从抽屉的最近课堂进来:先把网页切到同一节课,再回原生对话页。
    final canvas = ref.read(notaraCanvasProvider);
    await canvas.show(TeachingView.chat, sessionId: sessionId);
    ref.read(currentSessionProvider.notifier).select(sessionId);
    if (!mounted) return;
    setState(() => _view = TeachingView.chat);
  }

  /// 顶栏右侧的课堂键:直接打开 Notara 里**真实**的面板。
  ///
  /// 网页把开关登记在注册表里,这里调同一个函数——不找节点、不读文字、不合成
  /// 点击。图标按钮没有文字,旧办法对它们必然失效,这就是废掉它的原因。
  Future<void> _headerAction(String key, String title) async {
    HapticFeedback.selectionClick();
    final canvas = ref.read(notaraCanvasProvider);
    if (_view == TeachingView.chat) {
      // 面板长在课堂页上:对话页在前台时,先把画布切过去,否则打开也看不见。
      // 必须真的切到前台——后台弹出来的面板,前台什么反应都没有。
      setState(() => _view = TeachingView.lesson);
      await canvas.show(TeachingView.lesson, sessionId: _sessionId);
      await Future<void>.delayed(const Duration(milliseconds: 160));
    }
    final ok = await canvas.openHeaderAction(key);
    if (ok || !mounted) return;
    // 网页没登记这个面板:如实说,不假装点过。
    setState(() => _sheetOpen = true);
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => _TeachingFallbackSheet(title: title),
    );
    if (mounted) setState(() => _sheetOpen = false);
  }

  /// `⋯`:窄屏时前三键会收进来,这里把它们列成一张原生菜单。
  Future<void> _moreSheet() async {
    HapticFeedback.selectionClick();
    setState(() => _sheetOpen = true);
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(AppIcons.commandTimeout),
              title: const Text('课堂历史 / 计时'),
              onTap: () => Navigator.of(context).pop('history'),
            ),
            ListTile(
              leading: const Icon(AppIcons.settings),
              title: const Text('教学设置 / 讲法基调'),
              onTap: () => Navigator.of(context).pop('teaching'),
            ),
            ListTile(
              leading: const Icon(AppIcons.summary),
              title: const Text('课堂文档 / 题目小结'),
              onTap: () => Navigator.of(context).pop('summary'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    setState(() => _sheetOpen = false);
    if (picked == null) return;
    await _headerAction(picked, switch (picked) {
      'history' => '课堂历史 / 计时',
      'teaching' => '教学设置',
      _ => '课堂文档 / 小结',
    });
  }

  /// 空课号时第一次说话:现开一节带教学预设的课堂。
  ///
  /// 不这样做的话,原生这边发出去的就是一节普通对话,网页永远不认它是课堂:
  /// 白板没有内容、四键找不到面板、教室也进不去。
  Future<void> _ensureTeachingSessionIfNeeded() async {
    if (_ensuring) return;
    if (ref.read(currentSessionProvider) != null) return;
    if (ref.read(notaraCanvasProvider).activeSessionId != null) return;
    _ensuring = true;
    try {
      await ref.read(notaraCanvasProvider).ensureSession();
    } finally {
      _ensuring = false;
    }
  }

  /// 顶栏只在这里拼一次:对话页(交给 ChatScreen)和白板/教室(叠在上面)
  /// 用的是同一份,按钮顺序、热区、间距不会两处走样。
  Widget _topBar() {
    final canvas = ref.read(notaraCanvasProvider);
    // 白板小点是控制器的外部状态:用 AnimatedBuilder 听,别让整个壳重建。
    return AnimatedBuilder(
      animation: canvas,
      builder: (context, _) => TeachingTopBar(
      view: _view,
      boardFresh: canvas.boardFresh,
      onView: _switch,
      onMenu: () => _scaffold.currentState?.openDrawer(),
      onHistory: () => unawaited(_headerAction('history', '课堂历史 / 计时')),
      onTeachingSettings: () => unawaited(_headerAction('teaching', '教学设置 / 讲法基调')),
      onDocument: () => unawaited(_headerAction('summary', '课堂文档 / 题目小结')),
      onMore: () => unawaited(_moreSheet()),
      onPureReading: _enterPure,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final drawer = TeachingDrawer(
      onClose: () => _scaffold.currentState?.closeDrawer(),
      onSection: (section) => unawaited(_onSection(section)),
      onLesson: (sessionId) => unawaited(_onLesson(sessionId)),
    );

    final chat = ChatScreen(
      onOpenDrawer: () => _scaffold.currentState?.openDrawer(),
      backdrop: false,
      // 顶栏由本壳供给:同一行高度、同一套按钮,翻到白板也不跳。
      customTopBar: true,
      topBarHeight: TeachingTopBar.barHeight,
      topBar: _pure ? null : _topBar(),
      // 纯净阅读:底部输入区与状态条一起收起,整屏只留正文。
      hideComposer: _pure,
      // 第一次说话若还没有课堂,先开一节,别退化成普通写代码对话。
      onBeforeSend: _ensureTeachingSessionIfNeeded,
    );

    // 白板与教室是同一个 WebView:一个槽位,靠 JS 切。
    //
    // 非对话视图的顶栏是叠上去的,所以画布要让开同样高度;纯净阅读时顶栏
    // 收走,让位也跟着收回。
    //
    // 对话页时画布**不卸载**,而是停在白板视图上继续渲染——学生在对话里
    // 聊题,后台那张函数图要跟着更新;一右滑看到的就是画完的那张。
    final canvasView = switch (_view) {
      TeachingView.chat => TeachingView.board,
      TeachingView.section => null,
      final other => other,
    };
    final canvas = Padding(
      padding: EdgeInsets.only(top: _pure ? 0 : TeachingTopBar.heightOf(context)),
      child: NotaraCanvas(view: canvasView, sessionId: _sessionId),
    );

    // 对话与画布**都在树上**,靠不透明度换:这样才有 180ms 的交叉淡化,
    // 也不会因为卸载重建 Android Surface 而黑屏一下。
    final body = Stack(
      children: [
        Positioned.fill(
          child: IgnorePointer(
            ignoring: _view != TeachingView.chat,
            child: AnimatedOpacity(
              opacity: _view == TeachingView.chat ? 1 : 0,
              duration: TeachingShell.fade,
              curve: Curves.easeOutCubic,
              child: chat,
            ),
          ),
        ),
        Positioned.fill(
          child: IgnorePointer(
            ignoring: _view == TeachingView.chat,
            child: AnimatedOpacity(
              opacity: _view == TeachingView.chat ? 0 : 1,
              duration: TeachingShell.fade,
              curve: Curves.easeOutCubic,
              child: canvas,
            ),
          ),
        ),
        // 非对话视图的顶栏:对话页自己带了一条(见 topBar),白板/教室这边补一条同样高度的。
        if (_view != TeachingView.chat && !_pure)
          Positioned(top: 0, left: 0, right: 0, child: _topBar()),
        // 纯净白板:左边缘 24dp 向右滑回纯净对话(仍然没有 UI)。
        if (_pure)
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: 24,
            child: _EdgeHotZone(onSwipeRight: _pureBackToChat),
          ),
        // 纯净模式下只留右上角这一个 `◌`:它是唯一退出纯净的入口。
        if (_pure)
          Positioned(
            top: MediaQuery.paddingOf(context).top + 4,
            right: 8,
            child: _PureFloatingKey(onPressed: _exitPure, visible: true),
          ),
      ],
    );

    return PopScope(
      // 四层拦截:任何一层还开着,就不许退出。
      canPop: _view == TeachingView.chat && !_pure && !_drawerOpen && !_sheetOpen,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        // 第 1 级:抽屉或浮层开着 -> 先关。
        if (_drawerOpen) {
          _scaffold.currentState?.closeDrawer();
          return;
        }
        if (_sheetOpen) {
          Navigator.of(context).maybePop();
          return;
        }
        // 第 2 级:纯净阅读 -> 先退出,把顶栏与输入区还回来。
        if (_pure) {
          _exitPure();
          return;
        }
        // 第 3 级:白板 / 教室 / 分区 -> 先回对话。
        if (_view != TeachingView.chat) {
          _switch(TeachingView.chat);
          return;
        }
        // 第 4 级:已在对话、无浮层 -> 允许退出。
        SystemNavigator.pop();
      },
      child: Scaffold(
        key: _scaffold,
        backgroundColor: Colors.transparent,
        resizeToAvoidBottomInset: true,
        drawer: drawer,
        // 纯净态右滑进白板:这是「看函数图像」最省事的一步。
        body: _pure
            ? GestureDetector(
                behavior: HitTestBehavior.translucent,
                onHorizontalDragEnd: (details) {
                  final v = details.primaryVelocity ?? 0;
                  // 只在对话页右滑进白板;白板页的边缘热区负责往回走。
                  if (v < -260 && _view == TeachingView.chat) {
                    _pureSwipeToBoard();
                  }
                },
                child: body,
              )
            : body,
      ),
    );
  }

}

/// 纯净白板左边缘的 24dp 热区:向右滑回纯净对话。
///
/// 注意它**不退出纯净**:顶栏和输入框不该被一个边缘手势顺手叫回来。
class _EdgeHotZone extends StatelessWidget {
  const _EdgeHotZone({required this.onSwipeRight});

  final VoidCallback onSwipeRight;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragEnd: (details) {
        if ((details.primaryVelocity ?? 0) > 200) onSwipeRight();
      },
      child: const SizedBox.expand(),
    );
  }
}

/// 纯净模式下唯一的常驻按钮 `◌`:轻点退出纯净。
class _PureFloatingKey extends StatelessWidget {
  const _PureFloatingKey({required this.onPressed, required this.visible});

  final VoidCallback onPressed;
  final bool visible;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AnimatedOpacity(
      opacity: visible ? 1 : 0,
      duration: TeachingShell.fade,
      child: Material(
        color: colors.surface.withValues(alpha: 0.55),
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: SizedBox(
            width: 44,
            height: 44,
            child: Icon(AppIcons.radioOff, size: 20, color: colors.onSurfaceVariant),
          ),
        ),
      ),
    );
  }
}

/// 网页里没有这个面板时的兜底说明。写清楚"去哪儿找",而不是假装成功。
class _TeachingFallbackSheet extends StatelessWidget {
  const _TeachingFallbackSheet({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(AppSpace.xl, 0, AppSpace.xl, AppSpace.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: AppSpace.sm),
            Text(
              '这一项由 Notara 课堂自己提供，当前这节课还没有登记它。'
              '通常是这节课还没开始，或网页还没加载完——先在输入框发一句话，再点一次。',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
            ),
            const SizedBox(height: AppSpace.lg),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Navigator.of(context).maybePop(),
                child: const Text('知道了'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
