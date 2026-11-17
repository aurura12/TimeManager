import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../models/changelog_entry.dart';
import '../services/app_log_service.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';
import '../utils/changelog_parser.dart';

/// 更新日志 asset 路径，与 pubspec.yaml 的 assets 声明保持一致。
const String kChangelogAssetPath = 'docs/release-notes.md';

/// 按版本倒序展示更新日志，内容来自随包打进去的 docs/release-notes.md。
class ChangelogScreen extends StatefulWidget {
  const ChangelogScreen({
    super.key,
    this.contentLoader,
    this.currentVersionLabel,
  });

  /// 测试注入用；为空时读取 asset。
  final Future<String> Function()? contentLoader;

  /// 测试注入用；为空时通过 PackageInfo 读取当前版本。
  final String? currentVersionLabel;

  @override
  State<ChangelogScreen> createState() => _ChangelogScreenState();
}

class _ChangelogScreenState extends State<ChangelogScreen> {
  late Future<List<ChangelogEntry>> _changelog = _load();
  String? _currentLabel;

  @override
  void initState() {
    super.initState();
    _currentLabel = widget.currentVersionLabel;
    if (_currentLabel == null) {
      unawaited(_loadCurrentVersion());
    }
  }

  Future<void> _loadCurrentVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final label = '${info.version}+${info.buildNumber}';
      if (!mounted) return;
      setState(() => _currentLabel = label);
    } catch (_) {
      // 取不到版本时只是不高亮当前版本，不影响日志展示。
    }
  }

  Future<List<ChangelogEntry>> _load() async {
    try {
      final loader = widget.contentLoader ??
          () => rootBundle.loadString(kChangelogAssetPath);
      return parseChangelog(await loader());
    } catch (error, stackTrace) {
      try {
        AppLogService.instance.warning(
          '读取更新日志失败',
          source: 'changelog',
          error: error,
          stackTrace: stackTrace,
        );
      } catch (_) {
        // 日志服务未初始化时不要盖住原始错误，交给错误态展示。
      }
      rethrow;
    }
  }

  void _retry() {
    setState(() {
      _changelog = _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('更新日志')),
      body: FutureBuilder<List<ChangelogEntry>>(
        future: _changelog,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return _buildMessage(
              context,
              icon: Icons.menu_book_outlined,
              text: '更新日志加载失败',
              action: TextButton(onPressed: _retry, child: const Text('重试')),
            );
          }
          final entries = snapshot.data ?? const <ChangelogEntry>[];
          if (entries.isEmpty) {
            return _buildMessage(
              context,
              icon: Icons.menu_book_outlined,
              text: '暂无更新日志',
            );
          }
          return _buildList(context, entries);
        },
      ),
    );
  }

  Widget _buildList(BuildContext context, List<ChangelogEntry> entries) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: AppSizes.desktopFormMaxWidth,
        ),
        child: ListView.builder(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.pageHorizontal,
            vertical: AppSpacing.md,
          ),
          itemCount: entries.length,
          itemBuilder: (context, index) {
            final entry = entries[index];
            return _buildEntry(
              context,
              entry,
              isCurrent: entry.label == _currentLabel,
            );
          },
        ),
      ),
    );
  }

  Widget _buildEntry(
    BuildContext context,
    ChangelogEntry entry, {
    required bool isCurrent,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Stack(
        children: [
          Positioned(
            left: AppSizes.border * 3,
            top: 0,
            bottom: 0,
            child: Container(
              width: AppSizes.border * 2,
              color: scheme.outlineVariant.withValues(alpha: 0.6),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: AppSpacing.xl),
            child: Card(
              margin: EdgeInsets.zero,
              color: context.wallpaperFill(AppSurfaces.of(context).card),
              clipBehavior: Clip.antiAlias,
              shape: const RoundedRectangleBorder(
                borderRadius: AppRadius.cardAll,
              ),
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildHeading(context, entry, isCurrent),
                    if (entry.bullets.isNotEmpty) ...[
                      const SizedBox(height: AppSpacing.sm),
                      for (final bullet in entry.bullets)
                        _buildBullet(context, bullet),
                    ],
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            top: AppSpacing.sm + AppSpacing.md,
            child: Container(
              width: AppSizes.statusDot,
              height: AppSizes.statusDot,
              decoration: BoxDecoration(
                color: isCurrent ? scheme.primary : scheme.outline,
                shape: BoxShape.circle,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeading(
    BuildContext context,
    ChangelogEntry entry,
    bool isCurrent,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.xs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(entry.version, style: AppText.sectionTitle),
        if (entry.build.isNotEmpty)
          Text(
            '+${entry.build}',
            style: AppText.caption.copyWith(color: scheme.onSurfaceVariant),
          ),
        if (entry.date != null)
          Text(
            _formatDate(entry.date!),
            style: AppText.caption.copyWith(color: scheme.onSurfaceVariant),
          ),
        if (isCurrent)
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.sm,
              vertical: AppSpacing.xs,
            ),
            decoration: BoxDecoration(
              color: scheme.primaryContainer,
              borderRadius: AppRadius.badgeAll,
            ),
            child: Text(
              '当前版本',
              style: AppText.badge.copyWith(color: scheme.onPrimaryContainer),
            ),
          ),
      ],
    );
  }

  Widget _buildBullet(BuildContext context, String text) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.sm),
            child: Container(
              width: AppSpacing.xs,
              height: AppSpacing.xs,
              decoration: BoxDecoration(
                color: scheme.onSurfaceVariant,
                shape: BoxShape.circle,
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(child: Text(text, style: AppText.body)),
        ],
      ),
    );
  }

  Widget _buildMessage(
    BuildContext context, {
    required IconData icon,
    required String text,
    Widget? action,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                size: AppSizes.iconButton, color: scheme.onSurfaceVariant),
            const SizedBox(height: AppSpacing.md),
            Text(
              text,
              textAlign: TextAlign.center,
              style: AppText.body.copyWith(color: scheme.onSurfaceVariant),
            ),
            if (action != null) ...[
              const SizedBox(height: AppSpacing.md),
              action,
            ],
          ],
        ),
      ),
    );
  }

  static String _formatDate(DateTime date) {
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '${date.year}-$month-$day';
  }
}
