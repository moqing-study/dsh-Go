import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/sessions_state.dart';
import '../shell/sessions_drawer.dart' show sessionTitle;
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'teaching_types.dart';

/// `◧` 拉出的原生抽屉。
///
/// 上半是 Notara 的**五大全局入口**——原网页最左那条常驻图标栏被收进来之后,
/// 它们只剩这一个家:首页(选目录 / 带课程选项开新课)、计划、Vault 题库、
/// 技能、设置(主教师 / 工作员双模型)。点它们,主区切到单实例画布的对应
/// 视图;在首页 / Vault / 计划里选定题目进入课堂时,主区自己切回原生对话页
/// (由 [NotaraCanvasController] 的回报驱动,见 [TeachingShell])。
///
/// 下半才是最近课堂:点一条,秒切到那个课堂会话。
class TeachingDrawer extends ConsumerWidget {
  const TeachingDrawer({super.key, required this.onClose, required this.onSection, required this.onLesson});

  final VoidCallback onClose;
  final ValueChanged<TeachingSection> onSection;
  final ValueChanged<String> onLesson;

  static const width = 320.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).colorScheme;
    final sessions = ref.watch(sessionsProvider);
    return Drawer(
      width: width,
      backgroundColor: colors.surface,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpace.lg, AppSpace.lg, AppSpace.sm, AppSpace.md),
              child: Row(
                children: [
                  Icon(AppIcons.school, size: 22, color: colors.primary),
                  const SizedBox(width: AppSpace.sm),
                  Expanded(
                    child: Text('Notara 教学', style: Theme.of(context).textTheme.titleMedium),
                  ),
                  IconButton(
                    onPressed: onClose,
                    icon: const Icon(AppIcons.close, size: 20),
                    tooltip: '关闭',
                  ),
                ],
              ),
            ),
            // 上半:五大全局入口。
            for (final section in TeachingSection.values)
              _SectionRow(
                section: section,
                onTap: () {
                  onClose();
                  onSection(section);
                },
              ),
            const Divider(height: 24),
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpace.lg, 0, AppSpace.lg, AppSpace.sm),
              child: Text(
                '最近课堂',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(color: colors.onSurfaceVariant),
              ),
            ),
            Expanded(
              child: sessions.when(
                data: (items) {
                  if (items.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
                      child: Text(
                        '还没有课堂。到「首页」选一个目录开新课。',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
                      ),
                    );
                  }
                  return ListView.builder(
                    padding: EdgeInsets.zero,
                    itemCount: items.length,
                    itemBuilder: (context, index) {
                      final session = items[index];
                      return _LessonRow(
                        title: sessionTitle(session),
                        onTap: () {
                          onClose();
                          onLesson(session.sessionId);
                        },
                      );
                    },
                  );
                },
                loading: () => const Padding(
                  padding: EdgeInsets.symmetric(horizontal: AppSpace.lg),
                  child: LinearProgressIndicator(minHeight: 2),
                ),
                error: (_, _) => Padding(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
                  child: Text(
                    '读不到课堂列表',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
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

class _SectionRow extends StatelessWidget {
  const _SectionRow({required this.section, required this.onTap});

  final TeachingSection section;
  final VoidCallback onTap;

  static IconData _iconOf(TeachingSection section) => switch (section) {
    TeachingSection.home => AppIcons.home,
    TeachingSection.plan => AppIcons.plan,
    TeachingSection.vault => AppIcons.files,
    TeachingSection.skills => AppIcons.starProject,
    TeachingSection.settings => AppIcons.settings,
  };

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: SizedBox(
        // 48:平板拇指也要够得着。
        height: 48,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
          child: Row(
            children: [
              Icon(_iconOf(section), size: 20, color: colors.onSurfaceVariant),
              const SizedBox(width: AppSpace.md),
              Expanded(child: Text(section.label, style: Theme.of(context).textTheme.bodyMedium)),
            ],
          ),
        ),
      ),
    );
  }
}

class _LessonRow extends StatelessWidget {
  const _LessonRow({required this.title, required this.onTap});

  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: SizedBox(
        height: 48,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
          child: Row(
            children: [
              Icon(AppIcons.school, size: 18, color: colors.onSurfaceVariant.withValues(alpha: 0.7)),
              const SizedBox(width: AppSpace.md),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
