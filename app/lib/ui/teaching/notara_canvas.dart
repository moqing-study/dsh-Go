import 'dart:async';
import 'dart:convert';

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

  /// 网页当前这节课的 sessionId。
  ///
  /// 切视图、点四键、存取教法都要带上它:不带课号的白板只能自己猜一节课,
  /// 猜错就是"对话里聊 A、白板画 B"。由直连结果与网页回传共同维护。
  String? _activeSessionId;
  String? get activeSessionId => _activeSessionId;

  /// 抽屉当前落在哪一节。
  TeachingSection? _section;
  TeachingSection? get section => _section;

  /// 网页开了课(首页选目录、题库点题、计划开课)时通知外壳。
  ///
  /// 参数是网页刚打开的真实 sessionId 与目标视图。外壳据此把原生对话切到
  /// 同一个会话——这就是"课堂 1:1 映射",而不是两套各记各的账。
  void Function(String sessionId, String view)? onSessionOpened;

  /// 后台白板画完了新图。顶栏据此在「白板」上亮一个小点。
  ///
  /// 这不是装饰:学生在对话页聊题时,网页在后台照样收流、照样画。图已经
  /// 画好却让他切过去再等一次渲染,等于白等。
  bool _boardFresh = false;
  bool get boardFresh => _boardFresh;

  void clearBoardFresh() {
    if (!_boardFresh) return;
    _boardFresh = false;
    notifyListeners();
  }

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
        onMessageReceived: (message) => _onBridgeMessage(message.message),
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) async {
            await _injectBridge();
            // 网页首屏就默认无壳,这里再确认一次:页面重载会清掉 body 上的
            // 标记,不清掉的就是别人关过它。
            await setEmbedded(true);
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

  /// 调用网页的直连入口,返回它自己的结果对象。
  ///
  /// Notara 那边把 `{ok:false, reason:'no_session'}` 这一类答案原样交回来,
  /// 所以这里不做"看起来成功"的兜底:解析不出对象就是 null,由调用方决定
  /// 是退到旧入口还是如实告诉用户。
  Future<Map<String, dynamic>?> call(String expression) async {
    final web = _web;
    if (web == null) return null;
    try {
      final raw = await web.runJavaScriptReturningResult(expression);
      return _decodeResult(raw);
    } catch (_) {
      return null;
    }
  }

  /// WebView 交回来的东西可能是已解码的 Map,也可能是一层甚至两层 JSON 文本
  /// (Android 的 evaluateJavascript 会把字符串再编码一次)。逐层剥,剥不动
  /// 就放弃——不猜内容。
  static Map<String, dynamic>? _decodeResult(Object? raw) {
    if (raw == null) return null;
    var text = raw is String ? raw : '$raw';
    for (var attempt = 0; attempt < 3; attempt++) {
      if (text.isEmpty || text == 'null') return null;
      try {
        final value = jsonDecode(text);
        if (value is Map<String, dynamic>) return value;
        if (value is String) {
          text = value;
          continue;
        }
        return null;
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  /// 切到某节课的某个视图。**先开课,再切视图**:不带课号的白板会先画出
  /// 上一节课的板书,那正是"对话里聊 A、白板画 B"的来源。
  Future<bool> show(TeachingView view, {String? sessionId}) async {
    final web = _web;
    if (web == null) return false;
    final name = switch (view) {
      TeachingView.chat => 'chat',
      TeachingView.board => 'board',
      TeachingView.lesson => 'classroom',
      // 分区视图由 openSection 驱动,不经过这里。
      TeachingView.section => 'chat',
    };
    final result = await call(
      'window.__NOTARA_DIRECT__ ? window.__NOTARA_DIRECT__.openLessonView('
      '${jsonEncode(sessionId ?? '')}, ${jsonEncode(name)}) : null',
    );
    if (result != null) {
      final ok = result['ok'] == true;
      if (ok) {
        _shownView = view;
        _activeSessionId = (result['sessionId'] as String?) ?? sessionId;
        if (view == TeachingView.board) {
          _boardFresh = false;
          // 白板比视口宽:切过来就按宽度收一档,平板竖屏才看得全。
          await fitBoard();
        }
        notifyListeners();
      }
      return ok;
    }
    // 直连接口没加载到(网页还是上一版):退回原来的"找入口再点",并记下来,
    // 好让界面知道现在是降级状态。
    final legacy = await _legacyShow(view);
    if (legacy) {
      _shownView = view;
      notifyListeners();
    }
    return legacy;
  }

  Future<bool> _legacyShow(TeachingView view) async {
    final web = _web;
    if (web == null) return false;
    try {
      final result = await web.runJavaScriptReturningResult(_scriptFor(view));
      final ok = result == true || result == 'true';
      if (ok) _shownView = view;
      return ok;
    } catch (_) {
      return false;
    }
  }

  /// 切到抽屉里的五大入口之一。
  Future<bool> showSection(TeachingSection section) async {
    final web = _web;
    if (web == null) return false;
    final result = await call(
      'window.__NOTARA_DIRECT__ ? window.__NOTARA_DIRECT__.openSection('
      '${jsonEncode(section.webKey)}, null) : null',
    );
    if (result != null) {
      final ok = result['ok'] == true;
      if (ok) {
        _section = section;
        notifyListeners();
      }
      return ok;
    }
    try {
      final legacy = await web.runJavaScriptReturningResult(_sectionScript(section));
      final ok = legacy == true || legacy == 'true';
      if (ok) _section = section;
      return ok;
    } catch (_) {
      return false;
    }
  }

  /// 课堂四键。`history / teaching / summary` 各自对应 Notara 里真实的面板
  /// 开关;`more` 由原生自己弹(那是窄屏折叠,不是网页功能)。
  ///
  /// 网页里没有登记这个面板时返回 false——**不退回点击**,那正是要废掉的东西。
  Future<bool> openHeaderAction(String key) async {
    final web = _web;
    if (web == null) return false;
    final result = await call(
      'window.__NOTARA_DIRECT__ ? window.__NOTARA_DIRECT__.openHeaderAction('
      '${jsonEncode(key)}) : null',
    );
    return result?['ok'] == true;
  }

  /// 当前网页真的登记了哪些面板。启动自检与窄屏折叠都用它。
  Future<List<String>> headerActions() async {
    final result = await call(
      'window.__NOTARA_DIRECT__ ? window.__NOTARA_DIRECT__.headerActions() : null',
    );
    final keys = result?['keys'];
    if (keys is! List) return const [];
    return keys.whereType<String>().toList(growable: false);
  }

  /// 真实的教法列表:标题、说明、id 都来自这节课的教学设置回执。
  Future<List<TeachingSkill>> listSkills(String? sessionId) async {
    final id = sessionId ?? _activeSessionId ?? '';
    final result = await call(
      'window.__NOTARA_DIRECT__ ? window.__NOTARA_DIRECT__.listSkills(${jsonEncode(id)}) : null',
    );
    if (result == null || result['ok'] != true) return const [];
    final raw = result['skills'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((item) => TeachingSkill(
              id: '${item['id'] ?? ''}',
              title: '${item['title'] ?? ''}',
              description: '${item['description'] ?? ''}',
            ))
        .where((skill) => skill.id.isNotEmpty)
        .toList(growable: false);
  }

  /// 选定一个教法。走的是和网页面板同一条写路径(带 revision),所以冲突能
  /// 如实报出来,而不是本地改个变量当作生效。
  Future<bool> selectSkill(String? sessionId, String skillId) async {
    final id = sessionId ?? _activeSessionId ?? '';
    final web = _web;
    if (web == null || id.isEmpty) return false;
    final result = await call(
      'window.__NOTARA_DIRECT__ ? window.__NOTARA_DIRECT__.selectSkill('
      '${jsonEncode(id)}, ${jsonEncode(skillId)}) : null',
    );
    return result?['ok'] == true;
  }

  /// 让白板按当前视口宽度铺满(只缩不放)。
  Future<void> fitBoard() async {
    await _run('window.__NOTARA_DIRECT__ && window.__NOTARA_DIRECT__.fitBoard();');
  }

  /// 确认有一节课可上;没有就现开一节(带教学预设)。
  ///
  /// 网页侧是异步建会话,结果通过 [onSessionOpened] 回来,所以这里不等返回值:
  /// 返回 true 只表示"已经在开了"。
  Future<bool> ensureSession() async {
    final result = await call(
      'window.__NOTARA_DIRECT__ ? window.__NOTARA_DIRECT__.ensureSession() : null',
    );
    return result?['ok'] == true;
  }

  /// 内嵌无壳模式。网页首屏就默认无壳,这里再确认一次,防止它被别处关掉。
  Future<void> setEmbedded(bool on) async {
    await _run('window.__NOTARA_DIRECT__ && window.__NOTARA_DIRECT__.setEmbedded($on);');
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

  /// 网页回来的两类消息。
  ///
  ///   `{"type":"notaraSession","sessionId":"…","view":"…"}`  网页开课了
  ///   `{"view":"board"}`                                      旧桥的切视图回执
  ///
  /// 分开处理:旧回执**不带课号**,所以它只能说明"网页画到哪一页",绝不能
  /// 拿来判断"是哪一节课"。之前的实现用 `contains('board')` 猜,连会话消
  /// 息都会被误判成视图回执,这里一并修掉。
  void _onBridgeMessage(String raw) {
    Map<String, dynamic>? data;
    try {
      final value = jsonDecode(raw);
      if (value is Map<String, dynamic>) data = value;
    } catch (_) {
      data = null;
    }
    if (data == null) return;
    if (data['type'] == 'notaraSession') {
      final id = '${data['sessionId'] ?? ''}';
      if (id.isEmpty) return;
      _activeSessionId = id;
      onSessionOpened?.call(id, '${data['view'] ?? ''}');
      notifyListeners();
      return;
    }
    if (data['type'] == 'notaraBoard') {
      // 后台把图改完了:亮个点,不抢当前视图。
      _boardFresh = true;
      notifyListeners();
      return;
    }
    switch ('${data['view'] ?? ''}') {
      case 'board':
        _shownView = TeachingView.board;
      case 'notara-vault-classroom':
      case 'lesson':
        _shownView = TeachingView.lesson;
      case 'chat':
        _shownView = TeachingView.chat;
      default:
        break;
    }
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

  static String _scriptFor(TeachingView view) => switch (view) {
    TeachingView.chat => 'window.__dshGoShow && window.__dshGoShow("chat");',
    TeachingView.board => 'window.__dshGoShow && window.__dshGoShow("board");',
    TeachingView.lesson => 'window.__dshGoShow && window.__dshGoShow("lesson");',
    TeachingView.section => 'window.__dshGoShow && window.__dshGoShow("chat");',
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
  const NotaraCanvas({super.key, required this.view, this.sessionId});

  /// 要驱动的视图。null 表示"网页自己在导航"(抽屉的首页/题库/计划/技能),
  /// 这时外壳不该再用一个视图名把它拽回来。
  final TeachingView? view;

  /// 当前这节课。切视图时一起交给网页——不带课号的白板只能自己猜一节课。
  final String? sessionId;

  @override
  ConsumerState<NotaraCanvas> createState() => _NotaraCanvasState();
}

class _NotaraCanvasState extends ConsumerState<NotaraCanvas> {
  /// 引擎还没起来时,每一帧都试一次太吵;隔一小会儿再试。
  bool _warmPending = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _ensureLoaded());
  }

  /// 引擎(proot + dsh web)起来之前拿不到 baseUri/token。
  ///
  /// 以前这里只试一次就放弃,结果"先开 App、引擎稍后才就绪"的机器上永远
  /// 停在占位图。现在每次依赖变化都回来试:起来了就加载,端口/token 变了就
  /// 重新加载。
  void _ensureLoaded() {
    if (!mounted || _warmPending) return;
    final status = ref.read(localRuntimeProvider).status;
    final ready = status.baseUrl != null && status.token != null;
    if (!ready) return;
    final canvas = ref.read(notaraCanvasProvider);
    if (canvas.web != null) return;
    _warmPending = true;
    unawaited(() async {
      await canvas.warmUp(ref);
      if (!mounted) return;
      _warmPending = false;
      await canvas.resume();
      final view = widget.view;
      if (view != null) await canvas.show(view, sessionId: widget.sessionId);
    }());
  }

  @override
  void didUpdateWidget(NotaraCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    final view = widget.view;
    if (view == null) return;
    if (oldWidget.view != widget.view || oldWidget.sessionId != widget.sessionId) {
      // 带上课号:白板要画的是这节课的板书,不是上一节的。
      unawaited(ref.read(notaraCanvasProvider).show(view, sessionId: widget.sessionId));
    }
  }

  @override
  Widget build(BuildContext context) {
    final canvas = ref.read(notaraCanvasProvider);
    // 引擎状态一变就重试加载:这是"起来之后画布自己出现"的落点。
    ref.listen(localRuntimeProvider.select((s) => s.status.phase), (_, _) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _ensureLoaded());
    });
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
