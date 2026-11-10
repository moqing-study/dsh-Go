import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../runtime/runtime_state.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import '../web/local_web_screen.dart' show localWebUri;
import 'teaching_types.dart';

/// 白板与教室**共用**的那一个 WebView。
///
/// 为什么必须是一个:Notara 的画布、LaTeX、JSXGraph 函数图像都在
/// `window` 里活着。换视图若重建 WebView,就要重新握手、重新取一次课堂、
/// 重新排一次公式——那就是白屏和色差的来源。这里只加载一次,之后靠 JS
/// 让网页自己切,GPU 侧只有一次合成。
///
/// 生命周期:进入 App 就 [warmUp](对话页在跑,它在后台加载);离开教学
/// 视图不销毁;[pause] 只停网页里的动画循环,把帧让给原生对话。
class NotaraCanvasController extends ChangeNotifier {
  NotaraCanvasController();

  WebViewController? _web;
  bool _loaded = false;
  bool _paused = false;
  String? _lastError;
  Uri? _url;

  WebViewController? get web => _web;
  bool get loaded => _loaded;
  bool get paused => _paused;
  String? get lastError => _lastError;

  /// 网页里当前落在哪个视图,由 JS 回报(找不到入口时为 null)。
  TeachingView? _shownView;
  TeachingView? get shownView => _shownView;

  void attach(WebViewController controller, Uri url) {
    _web = controller;
    _url = url;
    notifyListeners();
  }

  void markLoaded() {
    if (_loaded) return;
    _loaded = true;
    notifyListeners();
  }

  void fail(String message) {
    _lastError = message;
    notifyListeners();
  }

  /// 后台预热:对话页显示时就把页面拉起来,第一次点「白板」不用等。
  Future<void> warmUp(WidgetRef ref) async {
    if (_web != null) return;
    final status = ref.read(localRuntimeProvider).status;
    final base = status.baseUrl;
    final token = status.token;
    if (base == null || token == null) return;
    final url = localWebUri(base, token);
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF151517))
      ..addJavaScriptChannel(
        'NotaraBridge',
        onMessageReceived: (message) {
          // 网页回报视图切换结果:{"view":"board"} / {"view":"lesson"}
          final payload = message.message;
          if (payload.contains('board')) {
            _shownView = TeachingView.board;
          } else if (payload.contains('lesson')) {
            _shownView = TeachingView.lesson;
          } else if (payload.contains('chat')) {
            _shownView = TeachingView.chat;
          }
          notifyListeners();
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) async {
            await _injectBridge();
            markLoaded();
          },
          onWebResourceError: (error) {
            if (error.isForMainFrame ?? false) fail(error.description);
          },
        ),
      )
      ..loadRequest(url);
    attach(controller, url);
  }

  /// 切到某个教学视图。返回 false 表示网页里没找到对应入口(需要用户手动点)。
  Future<bool> show(TeachingView view) async {
    final web = _web;
    if (web == null) return false;
    final js = _scriptFor(view);
    if (js == null) return false;
    try {
      final result = await web.runJavaScriptReturningResult(js);
      final ok = result == true || result == 'true';
      if (ok) _shownView = view;
      notifyListeners();
      return ok;
    } catch (_) {
      return false;
    }
  }

  /// 切到抽屉里的五大入口之一。
  Future<bool> showSection(TeachingSection section) async {
    final web = _web;
    if (web == null) return false;
    try {
      final result = await web.runJavaScriptReturningResult(_sectionScript(section));
      return result == true || result == 'true';
    } catch (_) {
      return false;
    }
  }

  /// 顶栏右侧四键:`⏱ 🎚 📄 ⋯` 各自对应 Notara 自己的面板(课堂历史/计时、
  /// 教学设置/课程选项、当前课堂文档/题目小结、更多操作)。
  ///
  /// 交给网页自己弹——这几块的数据与交互都在 Notara 里,原生重做一套只会
  /// 两边不一致。网页里找不到入口时返回 false,由调用方给一句说明。
  Future<bool> tapWebEntry(String key) async {
    final web = _web;
    if (web == null) return false;
    try {
      final result = await web.runJavaScriptReturningResult('window.__dshGoTap && window.__dshGoTap("$key");');
      return result == true || result == 'true';
    } catch (_) {
      return false;
    }
  }

  /// 对话页在前台时停掉网页里的动画循环,把帧让给原生滚动。
  Future<void> pause() async {
    if (_paused) return;
    _paused = true;
    await _run('window.__dshAppPause && window.__dshAppPause(true);');
    notifyListeners();
  }

  Future<void> resume() async {
    if (!_paused) return;
    _paused = false;
    await _run('window.__dshAppPause && window.__dshAppPause(false);');
    notifyListeners();
  }

  Future<void> reload() async {
    final url = _url;
    if (url == null) return;
    _loaded = false;
    _lastError = null;
    notifyListeners();
    await _web?.loadRequest(url);
  }

  Future<void> _run(String js) async {
    try {
      await _web?.runJavaScript(js);
    } catch (_) {
      // 页面还没就绪:下一次操作会再试,不打扰用户。
    }
  }

  /// 把 `assets/web/notara_bridge.js` 注进网页。它只挂三个函数,不碰样式,
  /// 每次加载后都注一次(脚本自身幂等)。
  Future<void> _injectBridge() async {
    try {
      final js = await rootBundle.loadString('assets/web/notara_bridge.js');
      await _web?.runJavaScript(js);
    } catch (_) {
      // 注入失败不致命:原生顶栏的按钮会退化为"没找到入口",用户仍可在
      // 网页里自己点,只是少一层原生联动。
    }
  }

  static String? _scriptFor(TeachingView view) => switch (view) {
    TeachingView.chat => 'window.__dshGoShow && window.__dshGoShow("chat");',
    TeachingView.board => 'window.__dshGoShow && window.__dshGoShow("board");',
    TeachingView.lesson => 'window.__dshGoShow && window.__dshGoShow("lesson");',
  };

  static String _sectionScript(TeachingSection section) =>
      'window.__dshGoSection && window.__dshGoSection("${section.webKey}");';
}

/// 全局一份。放在 ProviderScope 里,离开页面也不回收——回收就等于销毁
/// WebView,再进来又要重加载。
///
/// 用普通 [Provider] 持有实例,监听交给 [AnimatedBuilder]:Riverpod 3 把
/// [ChangeNotifierProvider] 挪进了 legacy 库,而这里要的只是"一个活着的对象",
/// 不需要 provider 层的重建。
final notaraCanvasProvider = Provider<NotaraCanvasController>((ref) {
  final controller = NotaraCanvasController();
  ref.onDispose(controller.dispose);
  return controller;
});

/// 白板 / 教室的显示面。**同一个** [WebViewWidget] 实例,两个视图轮换显示,
/// 不重建。
class NotaraCanvas extends ConsumerStatefulWidget {
  const NotaraCanvas({super.key, required this.view});

  final TeachingView view;

  @override
  ConsumerState<NotaraCanvas> createState() => _NotaraCanvasState();
}

class _NotaraCanvasState extends ConsumerState<NotaraCanvas> {
  @override
  void initState() {
    super.initState();
    // 进来就确保页面在加载(用户在对话页时通常已经预热过)。
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final canvas = ref.read(notaraCanvasProvider);
      await canvas.warmUp(ref);
      if (!mounted) return;
      await canvas.resume();
      await canvas.show(widget.view);
    });
  }

  @override
  void didUpdateWidget(NotaraCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.view != widget.view) {
      unawaited(ref.read(notaraCanvasProvider).show(widget.view));
    }
  }

  @override
  Widget build(BuildContext context) {
    final canvas = ref.read(notaraCanvasProvider);
    // 画布从"没起来"到"起来了"是一次外部状态变化,用 AnimatedBuilder 听,
    // 不必让 provider 层跟着重建。
    return AnimatedBuilder(
      animation: canvas,
      builder: (context, _) {
        final web = canvas.web;
        if (web == null) {
          return _CanvasPlaceholder(
            icon: AppIcons.school,
            title: '教学画布还没起来',
            message: canvas.lastError ?? '本机引擎还在启动,启动后这里会自动出现白板与教室。',
            action: TextButton(
              onPressed: () => unawaited(canvas.reload()),
              child: const Text('重试'),
            ),
          );
        }
        return WebViewWidget(controller: web);
      },
    );
  }
}

class _CanvasPlaceholder extends StatelessWidget {
  const _CanvasPlaceholder({required this.icon, required this.title, required this.message, this.action});

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ColoredBox(
      color: colors.surface,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.xxl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 40, color: colors.onSurfaceVariant),
              const SizedBox(height: AppSpace.lg),
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: AppSpace.sm),
              Text(
                message,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
              ),
              if (action != null) ...[const SizedBox(height: AppSpace.lg), action!],
            ],
          ),
        ),
      ),
    );
  }
}
