import 'package:flutter/material.dart';
import '../models/google_calendar_user.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import '../providers/theme_mode_provider.dart';
import '../providers/time_provider.dart';
import '../services/data_backup_service.dart';
import '../screens/word_cloud_screen.dart';
import '../services/google_calendar_service.dart';

class ProfileSettingsDrawer extends StatefulWidget {
  final VoidCallback onChanged;

  const ProfileSettingsDrawer({super.key, required this.onChanged});

  @override
  State<ProfileSettingsDrawer> createState() => _ProfileSettingsDrawerState();
}

class _ProfileSettingsDrawerState extends State<ProfileSettingsDrawer> {
  @override
  Widget build(BuildContext context) {
    final provider = context.watch<TimeProvider>();
    final googleUser = GoogleCalendarService.sessionUser;
    final themeModeProvider = context.watch<ThemeModeProvider>();
    final colorScheme = Theme.of(context).colorScheme;

    return Drawer(
      backgroundColor: colorScheme.surface,
      child: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
                    child: Text(
                      '账户与数据',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  _buildLoginSection(context, googleUser, provider),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.palette_outlined),
                    title: const Text('外观模式'),
                    subtitle: Text(_themeModeLabel(themeModeProvider.themeMode)),
                    trailing: DropdownButtonHideUnderline(
                      child: DropdownButton<ThemeMode>(
                        value: themeModeProvider.themeMode,
                        onChanged: (mode) {
                          if (mode != null) {
                            themeModeProvider.setThemeMode(mode);
                          }
                        },
                        items: const [
                          DropdownMenuItem(
                            value: ThemeMode.system,
                            child: Text('跟随系统'),
                          ),
                          DropdownMenuItem(
                            value: ThemeMode.light,
                            child: Text('浅色'),
                          ),
                          DropdownMenuItem(
                            value: ThemeMode.dark,
                            child: Text('深色'),
                          ),
                        ],
                      ),
                    ),
                  ),
                  ListTile(
                    leading: const Icon(Icons.upload_file_outlined),
                    title: const Text('导出备份'),
                    subtitle: const Text('保存 JSON 到本地'),
                    onTap: () async {
                      final rootContext =
                          Navigator.of(context, rootNavigator: true).context;
                      Navigator.pop(context);
                      await _handleExport(rootContext, provider);
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.download_outlined),
                    title: const Text('导入备份'),
                    subtitle: const Text('从 JSON 恢复数据'),
                    onTap: () async {
                      final rootContext =
                          Navigator.of(context, rootNavigator: true).context;
                      Navigator.pop(context);
                      await _handleImport(rootContext, provider);
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.bubble_chart_outlined),
                    title: const Text('事件词云'),
                    subtitle: const Text('按时长与出现次数查看事件热度'),
                    onTap: () {
                      Navigator.pop(context);
                      WordCloudScreen.open(context);
                    },
                  ),
                ],
              ),
            ),
            _buildVersionFooter(),
          ],
        ),
      ),
    );
  }

  Widget _buildVersionFooter() {
    return FutureBuilder<PackageInfo>(
      future: PackageInfo.fromPlatform(),
      builder: (context, snapshot) {
        final version = snapshot.data?.version;
        if (version == null || version.isEmpty) {
          return const SizedBox(height: 16);
        }
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Text(
            'v$version',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Theme.of(context).colorScheme.outline,
              fontSize: 12,
            ),
          ),
        );
      },
    );
  }

  Widget _buildLoginSection(
    BuildContext context,
    GoogleCalendarUser? googleUser,
    TimeProvider provider,
  ) {
    if (googleUser != null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 28,
                  backgroundColor:
                      Theme.of(context).colorScheme.primary.withValues(alpha: 0.12),
                  backgroundImage: googleUser.photoUrl != null
                      ? NetworkImage(googleUser.photoUrl!)
                      : null,
                  child: googleUser.photoUrl == null
                      ? Icon(
                          Icons.person,
                          size: 28,
                          color: Theme.of(context).colorScheme.primary,
                        )
                      : null,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        googleUser.displayName ?? 'Google 用户',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        googleUser.email,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          fontSize: 12,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Container(
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.primary,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            'Google 日历已连接',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.logout_rounded, size: 18),
                label: const Text('退出登录'),
                onPressed: () async {
                  await GoogleCalendarService.logout();
                  widget.onChanged();
                  if (context.mounted) Navigator.pop(context);
                },
              ),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 28,
                backgroundColor:
                    Theme.of(context).colorScheme.surfaceContainerHighest,
                child: Icon(
                  Icons.person_outline,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '未登录',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '连接 Google 日历以同步时间记录',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              icon: const Icon(Icons.g_mobiledata, size: 24),
              label: const Text('连接 Google 日历'),
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.primary,
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              onPressed: () async {
                if (!GoogleCalendarService.isConfigured) {
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        '请先在 lib/config/google_sign_in_config.dart 填写 Web 客户端 ID',
                      ),
                    ),
                  );
                  return;
                }
                final account = await GoogleCalendarService.login();
                if (!context.mounted) return;
                if (account == null) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        GoogleCalendarService.lastLoginError ?? 'Google 登录失败',
                      ),
                    ),
                  );
                  return;
                }
                provider.synchronizeCalendar();
                widget.onChanged();
                Navigator.pop(context);
              },
            ),
          ),
        ],
      ),
    );
  }

  String _themeModeLabel(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.system:
        return '当前：跟随系统';
      case ThemeMode.light:
        return '当前：浅色';
      case ThemeMode.dark:
        return '当前：深色';
    }
  }

  Future<void> _handleExport(
      BuildContext context, TimeProvider provider) async {
    final result = await DataBackupService.exportToFile(provider);
    if (!context.mounted || result.cancelled) return;

    final messenger = ScaffoldMessenger.of(context);
    if (result.success) {
      messenger.showSnackBar(const SnackBar(content: Text('备份已导出')));
    } else {
      messenger.showSnackBar(
        SnackBar(content: Text(result.error ?? '导出失败')),
      );
    }
  }

  Future<void> _handleImport(
      BuildContext context, TimeProvider provider) async {
    final picked = await DataBackupService.pickBackupFile(provider);
    if (!context.mounted || picked.result.cancelled) return;

    if (!picked.result.success ||
        picked.preview == null ||
        picked.json == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(picked.result.error ?? '无法读取备份文件')),
      );
      return;
    }

    final preview = picked.preview!;
    final exportedLabel = preview.exportedAt != null
        ? '导出时间：${preview.exportedAt!.substring(0, 16).replaceFirst('T', ' ')}'
        : '未知导出时间';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认导入'),
        content: Text(
          '导入将覆盖当前所有本地数据，此操作不可撤销。\n\n'
          '$exportedLabel\n'
          '${preview.dayCount} 天记录 · '
          '${preview.targetCount} 个目标 · '
          '${preview.categoryCount} 个分类 · '
          '${preview.templateCount} 个模板',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('覆盖导入'),
          ),
        ],
      ),
    );

    if (confirmed != true || !context.mounted) return;

    final result =
        await DataBackupService.importFromJson(provider, picked.json!);
    if (!context.mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(result.success ? '数据已恢复' : (result.error ?? '导入失败')),
      ),
    );
  }
}
