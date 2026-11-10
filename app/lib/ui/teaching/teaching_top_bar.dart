import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'teaching_types.dart';

/// 单行顶栏,高 50dp(不含状态栏):
///
/// ```
/// ◧   [ 对话 | 白板 | 教室 ]   ⏱ 🎚 📄 ⋯   ◌
/// ```
///
/// - `◧` 拉出原生 Drawer(上半 Notara 五大入口,下半最近课堂)
/// - 中间三视图:对话是原生 Flutter,白板/教室共用同一个 WebView
/// - `⏱` 课堂历史 / 计时,`🎚` 教学设置(讲课基调,不是模型 temperature),
///   `📄` 当前课堂文档 / 题目卡片小结,`⋯` 课堂更多操作——四者都以
///   毛玻璃浮层出现,和网页版同一个来源,不另造一套
/// - `◌` 毛玻璃纯净阅读:收掉顶栏与外壳,只留内容
///
/// 窄屏(手机竖屏)时 `⏱ 🎚 📄` 收进 `⋯`,三视图仍在——一行永远是 50dp,
/// 不做第二行。
class TeachingTopBar extends StatelessWidget {
  const TeachingTopBar({
    super.key,
    required this.view,
    required this.onView,
    required this.onMenu,
    required this.onHistory,
    required this.onTeachingSettings,
    required this.onDocument,
    required this.onMore,
    required this.onPureReading,
    this.modelChip,
    this.onTitleTap,
    this.title,
    this.boardFresh = false,
  });

  final TeachingView view;
  final ValueChanged<TeachingView> onView;
  final VoidCallback onMenu;

  /// `⏱` 课堂历史记录 / 计时。
  final VoidCallback onHistory;

  /// `🎚` 教学设置 / 课程选项(课中实时调整讲法基调)。
  final VoidCallback onTeachingSettings;

  /// `📄` 当前课堂文档 / 题目卡片小结。
  final VoidCallback onDocument;

  /// `⋯` 当前课堂更多操作。
  final VoidCallback onMore;

  /// `◌` 纯净阅读。
  final VoidCallback onPureReading;

  /// 模型选择 chip——**不能弄丢**,和主教师模型同步。放在三视图右侧的
  /// 紧凑位置;窄屏时它让位给三视图,改由 [onMore] 里的入口给出。
  final Widget? modelChip;

  /// 点标题(课堂名)看详情。
  final VoidCallback? onTitleTap;
  final String? title;

  /// 后台网页刚把白板改完:在「白板」上亮一个小点。
  final bool boardFresh;

  /// 不含状态栏的高度。48–52dp 区间取 50:一行放得下 44 的键,又不显空。
  static const barHeight = 50.0;

  /// 顶栏总高度(含状态栏)。列表顶部留白按它算,与 [ChatHeader] 的契约一致。
  static double heightOf(BuildContext context) => MediaQuery.paddingOf(context).top + barHeight;

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    return SizedBox(
      height: padding.top + barHeight,
      child: Padding(
        padding: EdgeInsets.only(top: padding.top),
        child: LayoutBuilder(
          builder: (context, constraints) {
            // 手机竖屏放不下四个小键时,后三个收进 `⋯`。阈值随系统字号缩放:
            // 字调大以后同一行能装下的键更少。
            final scaler = MediaQuery.textScalerOf(context);
            final compact = constraints.maxWidth < 430 * scaler.scale(1);
            return Row(
              children: [
                _BarKey(
                  icon: AppIcons.menu,
                  tooltip: '菜单',
                  onPressed: onMenu,
                  size: 48,
                ),
                const SizedBox(width: 2),
                Expanded(
                  child: Row(
                    children: [
                      Flexible(child: _ViewSwitch(view: view, onView: onView, compact: compact, boardFresh: boardFresh)),
                      if (modelChip != null && !compact) ...[
                        const SizedBox(width: AppSpace.sm),
                        Flexible(child: modelChip!),
                      ],
                      const Spacer(),
                      if (title != null && !compact)
                        Flexible(
                          child: _TitlePill(title: title!, onTap: onTitleTap),
                        ),
                    ],
                  ),
                ),
                if (!compact) ...[
                  _BarKey(icon: AppIcons.history, tooltip: '课堂历史', onPressed: onHistory, size: 40),
                  _BarKey(icon: AppIcons.settings, tooltip: '教学设置', onPressed: onTeachingSettings, size: 40),
                  _BarKey(icon: AppIcons.document, tooltip: '课堂文档', onPressed: onDocument, size: 40),
                ],
                _BarKey(icon: AppIcons.more, tooltip: '更多', onPressed: onMore, size: 40),
                _PureKey(onPressed: onPureReading),
                const SizedBox(width: AppSpace.xs),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// 三视图分段控件。选中态用底部一条细线,不做整块高亮——顶栏只有一行,
/// 色块会把 50dp 撑满,反而看不清选的是哪个。
class _ViewSwitch extends StatelessWidget {
  const _ViewSwitch({
    required this.view,
    required this.onView,
    required this.compact,
    required this.boardFresh,
  });

  final TeachingView view;
  final ValueChanged<TeachingView> onView;
  final bool compact;
  final bool boardFresh;

  /// 只有这三个是「视图」。抽屉的分区状态([TeachingView.section])不上顶栏,
  /// 否则会多出一个第四键,而且它本来就不该高亮任何一个课堂页签。
  static const _tabs = [TeachingView.chat, TeachingView.board, TeachingView.lesson];

  @override
  Widget build(BuildContext context) {
    // FittedBox(scaleDown):页签自然宽度装不下分配的空间时整体等比缩小,
    // 不再让里层的 min 宽把 Row 撑溢出——CI 的 discard_guard / remote_traffic
    // 在 360dp 视口就是差这 6px 溢出挂掉的。装得下时原样渲染,视觉无变化。
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final item in _tabs)
            _ViewTab(
              label: item.label,
              active: item == view,
              dot: item == TeachingView.board && boardFresh,
              onTap: () {
                if (item == view) return;
                HapticFeedback.selectionClick();
                onView(item);
              },
              compact: compact,
            ),
        ],
      ),
    );
  }
}

class _ViewTab extends StatelessWidget {
  const _ViewTab({
    required this.label,
    required this.active,
    required this.onTap,
    required this.compact,
    this.dot = false,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;
  final bool compact;

  /// 后台白板刚画完新图:在标签右上角点一个点。
  final bool dot;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.labelLarge;
    return Semantics(
      selected: active,
      button: true,
      label: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: ConstrainedBox(
          // 44 高,热区横向再撑到 48 以上(见 compact 分支)
          constraints: BoxConstraints(minWidth: compact ? 44 : 56, minHeight: 44),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Text(
                    label,
                    style: style?.copyWith(
                      fontSize: compact ? 13 : 14,
                      fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                      color: active ? colors.onSurface : colors.onSurfaceVariant,
                    ),
                  ),
                  if (dot)
                    Positioned(
                      right: -6,
                      top: -1,
                      child: Container(
                        width: 5,
                        height: 5,
                        decoration: BoxDecoration(color: colors.primary, shape: BoxShape.circle),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 3),
              AnimatedContainer(
                duration: AppMotion.quick,
                curve: AppMotion.std,
                height: 2,
                width: active ? (compact ? 16 : 20) : 0,
                decoration: BoxDecoration(color: colors.primary, borderRadius: BorderRadius.circular(1)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TitlePill extends StatelessWidget {
  const _TitlePill({required this.title, this.onTap});

  final String title;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.md),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: colors.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(color: colors.onSurfaceVariant),
        ),
      ),
    );
  }
}

/// 顶栏的普通键。视觉 20 的图标,热区按 [size] 撑满(≥ 40,菜单键 48)。
class _BarKey extends StatelessWidget {
  const _BarKey({required this.icon, required this.tooltip, required this.onPressed, required this.size});

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkResponse(
        onTap: () {
          HapticFeedback.selectionClick();
          onPressed();
        },
        radius: size / 2,
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(icon, size: 20, color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      ),
    );
  }
}

/// `◌` 纯净阅读:毛玻璃圆键,与左侧的普通键区分开——它是「换一种看法」,
/// 不是又一个操作。
class _PureKey extends StatelessWidget {
  const _PureKey({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Tooltip(
      message: '纯净阅读',
      child: GestureDetector(
        onTap: () {
          HapticFeedback.selectionClick();
          onPressed();
        },
        child: Container(
          width: 44,
          height: 44,
          alignment: Alignment.center,
          child: ClipOval(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
              child: Container(
                width: 32,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: colors.surfaceContainerHighest.withValues(alpha: 0.55),
                  border: Border.all(color: colors.outlineVariant.withValues(alpha: 0.5)),
                ),
                child: Icon(AppIcons.preview, size: 18, color: colors.onSurfaceVariant),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
