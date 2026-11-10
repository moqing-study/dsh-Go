/// 教学主视图:对话、白板、教室、以及抽屉里的全局入口。
///
/// 对话是原生 Flutter([TeachingView.chat]);白板与教室共用**同一个**
/// WebView 实例([TeachingView.board] / [TeachingView.lesson]),靠 JS 切,
/// 不重新加载页面——这是「0 白屏、0 色差」的前提。
///
/// [section] 是抽屉五大入口(首页/计划/题库/技能)落到画布上的状态。它必须
/// 与 [lesson] 分开:否则从抽屉进「题库」时,顶栏会把「教室」点亮,用户以为
/// 自己在教室里。
enum TeachingView { chat, board, lesson, section }

/// 抽屉上半部分的全局入口。
///
/// 隐藏 Notara 原本最左侧的常驻图标栏之后,这五项搬进原生 Drawer:
/// 首页(选目录 / 带课程选项开新课)、计划、Vault 题库、技能、设置。
/// 点其中任意一项,主区切到单实例无壳画布对应的 Notara 视图;
/// 在首页 / Vault / 计划里选定题目进入课堂时,自动切回原生对话页。
enum TeachingSection { home, plan, vault, skills, settings }

extension TeachingViewLabel on TeachingView {
  String get label => switch (this) {
    TeachingView.chat => '对话',
    TeachingView.board => '白板',
    TeachingView.lesson => '教室',
    // 分区不是顶栏页签,这里只给无障碍与日志一个可读名字。
    TeachingView.section => '资料',
  };
}

extension TeachingSectionLabel on TeachingSection {
  String get label => switch (this) {
    TeachingSection.home => '首页',
    TeachingSection.plan => '计划',
    TeachingSection.vault => 'Vault 题库',
    TeachingSection.skills => '技能',
    TeachingSection.settings => '设置',
  };

  /// 这一节在 DSH Web 侧落脚的名称,[NotaraCanvas.showSection] 用它找入口。
  String get webKey => switch (this) {
    TeachingSection.home => 'home',
    TeachingSection.plan => 'plan',
    TeachingSection.vault => 'vault',
    TeachingSection.skills => 'skills',
    TeachingSection.settings => 'settings',
  };

  /// 网页里真的有没有这一节。
  ///
  /// 设置是 DSH 自己的页面,Notara 内部没有它——以前照样把 `settings` 丢给
  /// 网页去找入口,找不到就当"点失败了",用户看到的是没反应。这里说清楚:
  /// 它不该由网页承接,由原生打开设置页。
  bool get livesInWeb => this != TeachingSection.settings;
}

/// 一条真实的教法。字段直接来自这节课的 `teachingSettings` 回执:
/// 网页里那条单选列表长什么样,原生弹出的列表就长什么样。
class TeachingSkill {
  const TeachingSkill({required this.id, required this.title, required this.description});

  final String id;
  final String title;
  final String description;
}
