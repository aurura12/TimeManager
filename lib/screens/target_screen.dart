import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/time_provider.dart';
import '../providers/wake_up_provider.dart';
import 'target_detail_screen.dart';
import 'add_target_screen.dart';
import '../models/target.dart';
import 'package:flutter_slidable/flutter_slidable.dart';

import '../theme/app_semantic_colors.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';
import '../widgets/desktop_target_card.dart';
import '../widgets/target_progress_indicator.dart';
import '../widgets/target_day_refresh.dart';
import '../services/target_progress_calculator.dart';
import '../widgets/desktop_shortcut_host.dart';
import '../widgets/main_tab_activity.dart';
import '../widgets/wake_up_card.dart';

class TargetScreen extends StatelessWidget {
  const TargetScreen({super.key});

  @override
  Widget build(BuildContext context) {
    if (context.read<WakeUpProvider?>() != null) {
      return const _TargetScreenContent();
    }
    return ChangeNotifierProvider(
      create: (_) => WakeUpProvider(),
      child: const _TargetScreenContent(),
    );
  }
}

class _TargetScreenContent extends StatelessWidget {
  const _TargetScreenContent();

  @override
  Widget build(BuildContext context) => TargetDayRefresh(
        builder: (context) => DesktopShortcutHost(
          autofocus: true,
          onNewItem: () => unawaited(showTargetEditor(context)),
          child: _buildPage(context),
        ),
      );

  Widget _buildPage(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final platform = Theme.of(context).platform;
    final desktop =
        platform == TargetPlatform.windows || platform == TargetPlatform.macOS;
    return Scaffold(
      appBar: AppBar(
        title: Text(desktop ? '目标' : '我的计划'),
        centerTitle: !desktop,
        // 如果是在底部导航栏的主页，通常不需要 leading 返回键，如有需要可自行开启
        actions: [
          if (desktop)
            Padding(
              padding: const EdgeInsets.only(right: AppSpacing.lg),
              child: FilledButton.icon(
                onPressed: () => showTargetEditor(context),
                icon: const Icon(Icons.add),
                label: const Text('新建目标'),
              ),
            )
          else
            IconButton(
              tooltip: '新建目标',
              icon: const Icon(Icons.add),
              onPressed: () => showTargetEditor(context),
            ),
        ],
      ),
      body: Consumer<TimeProvider>(
        builder: (context, timeProvider, child) {
          if (desktop) {
            return _buildDesktopList(context, timeProvider);
          }
          if (timeProvider.targets.isEmpty) {
            return ListView(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
              children: [
                _wakeUpHeader(),
                Padding(
                  padding: const EdgeInsets.all(AppSpacing.xl),
                  child: Text(
                    "暂无计划，点击右上角添加",
                    textAlign: TextAlign.center,
                    style: AppText.body
                        .copyWith(color: colorScheme.onSurfaceVariant),
                  ),
                ),
              ],
            );
          }

          return ReorderableListView(
            padding: const EdgeInsets.symmetric(vertical: 12),
            header: _wakeUpHeader(),
            onReorderItem: (oldIndex, newIndex) {
              timeProvider.reorderTargets(oldIndex, newIndex);
            },
            children: timeProvider.targets.map((target) {
              final title = switch (target.type) {
                TargetType.duration =>
                  '${target.name}${target.compareType}${target.durationHours}小时',
                TargetType.frequency =>
                  '${target.name}${target.compareType}${target.frequencyCount}次',
                TargetType.timePoint =>
                  '${target.targetTime}${target.compareType}${target.name}',
              };
              final cardColor = context.adaptSemanticColor(target.color);
              final onCardColor = AppSemanticColors.onColor(cardColor);
              final progress = timeProvider.getTargetProgress(target);

              Widget? topRightWidget;
              if (RegExp(r'^每\d+天$').hasMatch(target.period) &&
                  progress.period.isValid) {
                final today = TargetProgressCalculator.day(DateTime.now());
                final start = progress.period.start;
                if (!today.isBefore(start)) {
                  final days = DateTime.utc(today.year, today.month, today.day)
                          .difference(
                              DateTime.utc(start.year, start.month, start.day))
                          .inDays +
                      1;
                  topRightWidget = Text('本周期第$days天',
                      style: AppText.caption.copyWith(color: onCardColor));
                }
              } else if (!TargetProgressCalculator.isRepeating(target) &&
                  progress.period.isValid) {
                topRightWidget = _CountdownText(
                  endTime: progress.period.end,
                  style: AppText.body.copyWith(color: onCardColor),
                );
              }

              return Slidable(
                key: ValueKey(target.id), // 必须有 Key
                endActionPane: ActionPane(
                  motion: const ScrollMotion(),
                  extentRatio: 0.2, // 侧滑按钮占据的宽度比例
                  children: [
                    // 编辑和删除按钮上下排列
                    Expanded(
                      child: Column(
                        children: [
                          // 编辑按钮
                          Expanded(
                            child: InkWell(
                              onTap: () {
                                // 处理编辑逻辑
                                showTargetEditor(context, target: target);
                              },
                              child: Center(
                                child: Icon(
                                  Icons.edit,
                                  color: colorScheme.primary,
                                ),
                              ),
                            ),
                          ),
                          // 删除按钮
                          Expanded(
                            child: InkWell(
                              onTap: () =>
                                  _confirmDelete(context, timeProvider, target),
                              child: Center(
                                child: Icon(Icons.delete_forever,
                                    color: AppSemanticColors.readableOn(
                                        AppSemanticColors.danger,
                                        AppSurfaces.of(context).page)),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                child: _buildTargetCard(
                  context: context,
                  key: ValueKey("card_${target.name}"), // 这里用不同的 key 区分
                  subtitle: target.period,
                  title: title,
                  progress: TargetProgressIndicator(
                      progress: progress,
                      showTodayLabel: true,
                      foregroundColor: onCardColor,
                      surface: cardColor),
                  topRightWidget: topRightWidget,
                  color: target.color,
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) =>
                            TargetDetailScreen(targetId: target.id),
                      ),
                    );
                  },
                ),
              );
            }).toList(),
          );
        },
      ),
    );
  }

  Widget _wakeUpHeader() => const Padding(
        padding:
            EdgeInsets.fromLTRB(AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.sm),
        child: WakeUpCard(),
      );

  Widget _buildDesktopList(BuildContext context, TimeProvider provider) {
    final scheme = Theme.of(context).colorScheme;
    if (provider.targets.isEmpty) {
      return Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints:
              const BoxConstraints(maxWidth: AppSizes.desktopContentMaxWidth),
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            children: [
              const WakeUpCard(),
              const SizedBox(height: AppSpacing.xl),
              Icon(Icons.flag_outlined,
                  size: AppSizes.minTapTarget, color: scheme.onSurfaceVariant),
              const SizedBox(height: AppSpacing.lg),
              const Text('暂无目标',
                  style: AppText.sectionTitle, textAlign: TextAlign.center),
              const SizedBox(height: AppSpacing.sm),
              Text('为已有事件设置时长、次数或时间点目标',
                  textAlign: TextAlign.center,
                  style: AppText.body.copyWith(color: scheme.onSurfaceVariant)),
              const SizedBox(height: AppSpacing.xl),
              Center(
                child: FilledButton.icon(
                  onPressed: () => showTargetEditor(context),
                  icon: const Icon(Icons.add),
                  label: const Text('新建目标'),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints:
            const BoxConstraints(maxWidth: AppSizes.desktopContentMaxWidth),
        child: ReorderableListView.builder(
          padding: const EdgeInsets.all(AppSpacing.lg),
          buildDefaultDragHandles: false,
          itemCount: provider.targets.length,
          onReorderItem: provider.reorderTargets,
          header: Column(children: [
            const WakeUpCard(),
            Padding(
              padding: AppSpacing.cardComfortable,
              child: Row(
                children: [
                  Expanded(
                    child: Text('共 ${provider.targets.length} 个目标',
                        style: AppText.caption
                            .copyWith(color: scheme.onSurfaceVariant)),
                  ),
                  Text('拖动把手排序 · 右键打开菜单',
                      style: AppText.caption
                          .copyWith(color: scheme.onSurfaceVariant)),
                ],
              ),
            ),
          ]),
          itemBuilder: (context, index) {
            final target = provider.targets[index];
            return DesktopTargetCard(
              key: ValueKey(target.id),
              target: target,
              provider: provider,
              index: index,
              onOpen: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => TargetDetailScreen(targetId: target.id),
                ),
              ),
              onEdit: () => showTargetEditor(context, target: target),
              onDelete: () => _confirmDelete(context, provider, target),
            );
          },
        ),
      ),
    );
  }

  // 自定义目标卡片构建方法
  Widget _buildTargetCard({
    required BuildContext context,
    required Key key,
    String? subtitle,
    required String title,
    required Widget progress,
    Widget? topRightWidget,
    required Color color,
    VoidCallback? onTap,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final cardColor = context.adaptSemanticColor(color);
    // 背景启用时卡片填充变半透明；文字色仍按不透明的 cardColor 算
    final cardFill = context.adaptSemanticFill(color);
    final onCardColor = AppSemanticColors.onColor(cardColor);

    return GestureDetector(
      key: key,
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 16.0),
        padding: const EdgeInsets.all(20.0),
        decoration: BoxDecoration(
          color: cardFill,
          borderRadius: AppRadius.cardAll,
          // 卡片：弱边框、少阴影
          border: Border.all(
              color: colorScheme.outlineVariant.withValues(alpha: 0.35)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: AppSpacing.lg,
              runSpacing: AppSpacing.sm,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (subtitle != null)
                  Text(
                    subtitle,
                    style: AppText.caption
                        .copyWith(color: onCardColor.withValues(alpha: 0.75)),
                  ),
                if (topRightWidget != null) topRightWidget,
              ],
            ),
            const SizedBox(height: 4),
            Text(
              title,
              style: TextStyle(
                color: onCardColor,
                fontSize: 19,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 24),
            Align(
              alignment: Alignment.bottomRight,
              child: progress,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDelete(
      BuildContext context, TimeProvider provider, Target target) async {
    return showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定要删除目标“${target.name}”吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              provider.deleteTarget(target); // 请确保你的 TimeProvider 中有这个方法
              Navigator.pop(context);
            },
            child: Text('确认',
                style: TextStyle(
                    color: AppSemanticColors.readableOn(
                        AppSemanticColors.danger,
                        AppSurfaces.of(context).card))),
          ),
        ],
      ),
    );
  }
}

class _CountdownText extends StatefulWidget {
  final DateTime endTime;
  final TextStyle style;

  const _CountdownText({required this.endTime, required this.style});

  @override
  State<_CountdownText> createState() => _CountdownTextState();
}

class _CountdownTextState extends State<_CountdownText> {
  Timer? _timer;
  Duration _remaining = Duration.zero;
  bool _isActive = false;

  @override
  void initState() {
    super.initState();
    _updateTime();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _isActive = MainTabActivity.isActiveOf(context);
    _refreshTimer();
  }

  void _refreshTimer() {
    _timer?.cancel();
    if (_isActive) {
      _updateTime();
      if (_remaining > Duration.zero) {
        _timer =
            Timer.periodic(const Duration(minutes: 1), (_) => _updateTime());
      }
    }
  }

  @override
  void didUpdateWidget(covariant _CountdownText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.endTime != oldWidget.endTime) {
      _refreshTimer();
    }
  }

  void _updateTime() {
    final now = DateTime.now().toUtc();
    final diff = widget.endTime.difference(now);
    if (mounted) {
      setState(() {
        _remaining = diff.isNegative ? Duration.zero : diff;
      });
    }
    if (diff <= Duration.zero) _timer?.cancel();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final days = _remaining.inDays;
    final hours = _remaining.inHours % 24;
    final minutes = _remaining.inMinutes % 60;

    String text;
    if (days > 0) {
      text =
          "$days天 ${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}";
    } else {
      text =
          "${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}";
    }

    return Text(" $text", style: widget.style);
  }
}
