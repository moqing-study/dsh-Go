import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/sessions_state.dart';
import '../chat/chat_screen.dart';
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
/// 三条不许破的规矩:
/// 1. 对话页是原生 Flutter,不套 WebView,消息级更不行;
/// 2. 白板与教室只有一个 WebView,切视图不重新加载——这是 0 白屏的前提;
/// 3. 回到对话页时,后台网页停掉动画循环,把帧让给原生滚动。
///
/// 返回键按四层拦截,顺序不能变:先关浮层/抽屉,再退纯净,再回对话,
/// 最后才允许退出 App。
class TeachingShell extends ConsumerStatefulWidget {
  const TeachingShell({super.key, this.onOpenDrawer});

  /// 外层(HomeShell)的抽屉回调。为 null 时用本壳自己的抽屉。
  final VoidCallback? onOpenDrawer;

  @override
  ConsumerState<TeachingShell> createState() => _TeachingShellState();
}

class _TeachingShellState extends ConsumerState<TeachingShell> {
  TeachingView _view = TeachingView.chat;

  /// 纯净阅读:收掉顶栏,只留内容。
  bool _pure = false;

  /// 顶栏浮层(`⏱ 🎚 📄 ⋯`)是否开着——返回键第一级要能关掉它。
  bool _sheetOpen = false;

  final _scaffold = GlobalKey<ScaffoldState>();

  @override
  void initState() {
    super.initState();
    // 进 App 就预热画布:对话页在用的时候,网页在后台把首屏拉起来。
    // 第一次点「白板」不该看见白屏。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(ref.read(notaraCanvasProvider).warmUp(ref));
      unawaited(ref.read(notaraCanvasProvider).pause());
    });
  }

  bool get _drawerOpen => _scaffold.currentState?.isDrawerOpen ?? false;

  void _switch(TeachingView view) {
    if (view == _view) return;
    HapticFeedback.selectionClick();
    setState(() => _view = view);
    final canvas = ref.read(notaraCanvasProvider);
    if (view == TeachingView.chat) {
      // 对话在前台:网页待命,别继续烧帧。
      unawaited(canvas.pause());
    } else {
      unawaited(canvas.resume());
      unawaited(canvas.show(view));
    }
  }

  void _enterPure() {
    HapticFeedback.mediumImpact();
    setState(() {
      _pure = true;
      // 纯净阅读看的是内容;当前停在对话就先不动,停在白板/教室就保持。
    });
  }

  void _exitPure() {
    HapticFeedback.selectionClick();
    setState(() => _pure = false);
    unawaited(ref.read(notaraCanvasProvider).resume());
  }

  /// 纯净态下右滑:180ms 切到纯净白板,看函数图像。
  void _pureSwipeToBoard() {
    if (!_pure) return;
    HapticFeedback.mediumImpact();
    setState(() => _view = TeachingView.board);
    unawaited(ref.read(notaraCanvasProvider).resume());
    unawaited(ref.read(notaraCanvasProvider).show(TeachingView.board));
  }

  Future<void> _onSection(TeachingSection section) async {
    // 五大入口全部落在画布上:先把视图切到教室(Notara 的主容器),
    // 再让网页自己走到对应 section。
    setState(() => _view = TeachingView.lesson);
    final canvas = ref.read(notaraCanvasProvider);
    await canvas.resume();
    await canvas.showSection(section);
  }

  Future<void> _onLesson(String sessionId) async {
    // 选定课堂:永远回原生对话页——那里才是讲课的地方。
    ref.read(currentSessionProvider.notifier).select(sessionId);
    setState(() => _view = TeachingView.chat);
    await ref.read(notaraCanvasProvider).pause();
  }

  /// 顶栏右侧四个键:先让网页弹它自己的面板(教学设置、课堂文档这些
  /// 都是 Notara 的,重新做一套只会两边不一致)。网页里找不到入口时,
  /// 才落一个说明用的浮层。
  Future<void> _barAction(String key, String title) async {
    HapticFeedback.selectionClick();
    final canvas = ref.read(notaraCanvasProvider);
    if (_view == TeachingView.chat) {
      // 网页在待命状态,先把它拉起来再点。
      setState(() => _view = TeachingView.lesson);
      await canvas.resume();
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    final ok = await canvas.tapWebEntry(key);
    if (ok || !mounted) return;
    setState(() => _sheetOpen = true);
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => _TeachingFallbackSheet(title: title),
    );
    if (mounted) setState(() => _sheetOpen = false);
  }

  /// 顶栏只在这里拼一次:对话页(交给 ChatScreen)和白板/教室(叠在上面)
  /// 用的是同一份,按钮顺序、热区、间距不会两处走样。
  Widget _topBar() => TeachingTopBar(
    view: _view,
    onView: _switch,
    onMenu: () => _scaffold.currentState?.openDrawer(),
    onHistory: () => unawaited(_barAction('history', '课堂历史 / 计时')),
    onTeachingSettings: () => unawaited(_barAction('teaching', '教学设置')),
    onDocument: () => unawaited(_barAction('document', '课堂文档 / 题目小结')),
    onMore: () => unawaited(_barAction('more', '更多操作')),
    onPureReading: _enterPure,
  );

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
    );

    // 白板与教室是同一个 WebView:一个 IndexedStack 槽位,靠 JS 切。
    // 非对话视图的顶栏是叠上去的,所以画布要让开同样高度——否则第一行内容
    // 会被顶栏压住。纯净阅读时顶栏收走,让位也跟着收回。
    final canvas = Padding(
      padding: EdgeInsets.only(top: _pure ? 0 : TeachingTopBar.heightOf(context)),
      child: NotaraCanvas(view: _view == TeachingView.chat ? TeachingView.board : _view),
    );

    final body = Stack(
      children: [
        Positioned.fill(
          child: IndexedStack(
            index: _view == TeachingView.chat ? 0 : 1,
            children: [chat, canvas],
          ),
        ),
        // 非对话视图的顶栏:对话页自己带了一条(见 topBar),白板/教室这边补一条同样高度的。
        if (_view != TeachingView.chat && !_pure)
          Positioned(top: 0, left: 0, right: 0, child: _topBar()),
        // 白板页的 24dp 边缘热区:从边上点一下把顶栏叫回来。
        if (_view != TeachingView.chat && _pure) ...[
          Positioned(left: 0, top: 0, bottom: 0, width: 24, child: _EdgeHotZone(onTap: _exitPure)),
          Positioned(right: 0, top: 0, bottom: 0, width: 24, child: _EdgeHotZone(onTap: _exitPure)),
        ],
      ],
    );

    return PopScope(
      // 四层拦截:任何一层还开着,就不许退出。
      canPop: _view == TeachingView.chat && !_pure && !_drawerOpen && !_sheetOpen,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        // 第 1 级:抽屉或顶栏浮层开着 -> 先关。
        if (_drawerOpen) {
          _scaffold.currentState?.closeDrawer();
          return;
        }
        if (_sheetOpen) {
          Navigator.of(context).maybePop();
          return;
        }
        // 第 2 级:纯净阅读 -> 先退出,把顶栏还回来。
        if (_pure) {
          _exitPure();
          return;
        }
        // 第 3 级:白板 / 教室 / 其它视图 -> 先回对话。
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
        // 纯净态右滑 180ms 进白板:这是「看函数图像」最省事的一步。
        body: _pure
            ? GestureDetector(
                behavior: HitTestBehavior.translucent,
                onHorizontalDragEnd: (details) {
                  final v = details.primaryVelocity ?? 0;
                  if (v < -260) {
                    _pureSwipeToBoard();
                  } else if (v > 260 && _view != TeachingView.chat) {
                    _exitPure();
                  }
                },
                child: body,
              )
            : body,
      ),
    );
  }
}

/// 纯净白板两侧的 24dp 热区:轻点一下就把顶栏叫回来。
class _EdgeHotZone extends StatelessWidget {
  const _EdgeHotZone({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
    );
  }
}

/// 网页里找不到对应入口时的兜底浮层。写清楚"去哪儿点",而不是假装成功。
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
              '这一项由 Notara 网页自己提供，当前页面里没有找到它的入口。'
              '可以在白板/教室里直接操作，或到「设置」里看看。',
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
