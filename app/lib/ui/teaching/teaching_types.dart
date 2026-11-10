/// 教学主视图:对话、白板、教室。
///
/// 对话是原生 Flutter([TeachingView.chat]);白板与教室共用**同一个**
/// WebView 实例([TeachingView.board] / [TeachingView.lesson]),靠 JS 切,
/// 不重新加载页面——这是「0 白屏、0 色差」的前提。
enum TeachingView { chat, board, lesson }

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
}
