import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import '../providers/time_provider.dart';
import '../services/data_backup_service.dart';
import '../services/google_calendar_service.dart';

class ProfileSettingsDrawer extends StatelessWidget {
  final VoidCallback onChanged;

  const ProfileSettingsDrawer({super.key, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final googleUser = GoogleCalendarService.currentUser;
    final provider = context.read<TimeProvider>();

    return Drawer(
      backgroundColor: const Color(0xFFF8F9FA),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
              child: Text(
                '账户与数据',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey[600],
                ),
              ),
            ),
            _buildLoginSection(context, googleUser, provider),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.upload_file_outlined),
              title: const Text('导出备份'),
              subtitle: const Text('保存 JSON 到本地'),
              onTap: () async {
                Navigator.pop(context);
                await _handleExport(context, provider);
              },
            ),
            ListTile(
              leading: const Icon(Icons.download_outlined),
              title: const Text('导入备份'),
              subtitle: const Text('从 JSON 恢复数据'),
              onTap: () async {
                Navigator.pop(context);
                await _handleImport(context, provider);
              },
            ),
            const Spacer(),
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
            style: TextStyle(color: Colors.grey[400], fontSize: 12),
          ),
        );
      },
    );
  }

  Widget _buildLoginSection(
    BuildContext context,
    GoogleSignInAccount? googleUser,
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
                      const Color(0xFF9CB86A).withValues(alpha: 0.1),
                  backgroundImage: googleUser.photoUrl != null
                      ? NetworkImage(googleUser.photoUrl!)
                      : null,
                  child: googleUser.photoUrl == null
                      ? const Icon(Icons.person,
                          size: 28, color: Color(0xFF9CB86A))
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
                        style: TextStyle(color: Colors.grey[500], fontSize: 12),
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Container(
                            width: 6,
                            height: 6,
                            decoration: const BoxDecoration(
                              color: Color(0xFF9CB86A),
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            'Google 日历已连接',
                            style: TextStyle(
                              color: Colors.grey[600],
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
                  onChanged();
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
                backgroundColor: Colors.grey[200],
                child: Icon(Icons.person_outline, color: Colors.grey[500]),
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
                      style: TextStyle(color: Colors.grey[500], fontSize: 12),
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
                backgroundColor: const Color(0xFF9CB86A),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              onPressed: () async {
                await GoogleCalendarService.login();
                provider.synchronizeCalendar();
                onChanged();
                if (context.mounted) Navigator.pop(context);
              },
            ),
          ),
        ],
      ),
    );
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
