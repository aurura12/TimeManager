import 'dart:async';
import 'dart:io';

import '../utils/platform_features.dart';

import 'package:flutter/material.dart';
import '../models/diary_reminder.dart';
import '../models/google_calendar_user.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import '../providers/theme_mode_provider.dart';
import '../providers/time_provider.dart';
import '../services/app_log_service.dart';
import '../services/data_backup_service.dart';
import '../services/diary_reminder_service.dart';
import '../services/update_service.dart';
import '../screens/app_log_screen.dart';
import '../screens/sync_center_screen.dart';
import '../screens/word_cloud_screen.dart';
import '../screens/on_this_day_screen.dart';
import '../services/google_calendar_service.dart';
import '../services/app_identity_service.dart';
import '../models/diary_kind.dart';
import '../theme/app_semantic_colors.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';
import 'time_wheel_sheet.dart';

class ProfileSettingsDrawer extends StatefulWidget {
  final VoidCallback onChanged;
  final bool? desktopPlatformOverride;
  final bool? androidPlatformOverride;

  const ProfileSettingsDrawer({
    super.key,
    required this.onChanged,
    this.desktopPlatformOverride,
    this.androidPlatformOverride,
  });

  @override
  State<ProfileSettingsDrawer> createState() => _ProfileSettingsDrawerState();
}

class _ProfileSettingsDrawerState extends State<ProfileSettingsDrawer> {
  /// Windows 用户身份选择是否展开（选中角色后自动收起）
  bool _identityExpanded = false;
  bool _identitySwitching = false;

  /// 写日记提醒（仅 Android）。不放进 Provider：它不是业务数据，
  /// 只在抽屉里读写，且失败必须降级而不是影响其它页面。
  bool _diaryReminderLoaded = false;
  bool _diaryReminderBusy = false;
  DiaryReminderStatus? _diaryReminderStatus;

  @override
  void initState() {
    super.initState();
    unawaited(_loadDiaryReminderStatus());
  }

  Future<void> _loadDiaryReminderStatus() async {
    DiaryReminderStatus status;
    try {
      status = await DiaryReminderService.loadStatus();
    } catch (error, stackTrace) {
      // 抽屉必须能打开：任何异常都降级成安全默认值，不允许抛进 build
      AppLogService.instance.warning(
        '读取写日记提醒设置失败',
        source: DiaryReminderService.logSource,
        error: error,
        stackTrace: stackTrace,
      );
      status = const DiaryReminderStatus.fallback();
    }
    if (!mounted) return;
    setState(() {
      _diaryReminderStatus = status;
      _diaryReminderLoaded = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<TimeProvider>();
    final googleUser = AppIdentityService.googleUser;
    final themeModeProvider = context.watch<ThemeModeProvider>();
    final colorScheme = Theme.of(context).colorScheme;
    final isAndroid = widget.androidPlatformOverride ?? Platform.isAndroid;

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
                  if (widget.desktopPlatformOverride ?? isDesktopPlatform) ...[
                    _buildManualIdentitySection(
                      context,
                      provider,
                      title: 'Windows 用户身份',
                    ),
                  ] else ...[
                    if (provider.isManualIdentityMode)
                      _buildManualIdentitySection(
                        context,
                        provider,
                        title: '手动用户身份',
                      )
                    else
                      _buildLoginSection(
                        context,
                        provider.isGoogleIdentityMode
                            ? AppIdentityService.googleUser
                            : googleUser,
                        provider,
                      ),
                    const Divider(height: 1),
                    _buildRemoteSyncSection(context, provider),
                  ],
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.sync_rounded),
                    title: const Text('同步中心'),
                    subtitle: Text(
                      provider.hasPendingSync
                          ? '有 ${provider.pendingSyncDates.length} 天待同步，查看全部状态'
                          : '查看各模块同步状态并重试',
                    ),
                    onTap: () {
                      final navigator = Navigator.of(context);
                      navigator.pop();
                      navigator.push(
                        MaterialPageRoute<void>(
                          builder: (_) => const SyncCenterScreen(),
                        ),
                      );
                    },
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.palette_outlined),
                    title: const Text('外观模式'),
                    subtitle:
                        Text(_themeModeLabel(themeModeProvider.themeMode)),
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
                    leading: const Icon(Icons.receipt_long_outlined),
                    title: const Text('运行日志'),
                    subtitle: const Text('查看问题记录并导出日志'),
                    onTap: () {
                      final navigator = Navigator.of(context);
                      navigator.pop();
                      navigator.push(
                        MaterialPageRoute<void>(
                          builder: (_) => const AppLogScreen(),
                        ),
                      );
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
                  ListTile(
                    leading: const Icon(Icons.history_rounded),
                    title: const Text('那年今日'),
                    subtitle: const Text('回顾往年今天的日记、出行和活动'),
                    onTap: () {
                      Navigator.pop(context);
                      OnThisDayScreen.open(context);
                    },
                  ),
                  // 独立分区，插在最后的「检查更新」之前，避免后续条目被视觉归到「提醒」下
                  if (isAndroid) ...[
                    const Divider(height: AppSizes.hairline),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        AppSpacing.pageHorizontal,
                        AppSpacing.lg,
                        AppSpacing.pageHorizontal,
                        AppSpacing.md,
                      ),
                      child: Text(
                        '提醒',
                        style: AppText.caption.copyWith(
                          fontWeight: FontWeight.w600,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    _buildDiaryReminderSection(context, colorScheme),
                  ],
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.system_update_outlined),
                    title: const Text('检查更新'),
                    subtitle: const Text('检查是否有新版本'),
                    onTap: () => _checkForUpdate(context),
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

  /// 写日记提醒分区。只读 [_diaryReminderStatus]，不自己探测平台能力。
  Widget _buildDiaryReminderSection(
    BuildContext context,
    ColorScheme colorScheme,
  ) {
    final status = _diaryReminderStatus;
    if (!_diaryReminderLoaded || status == null) {
      return const ListTile(
        leading: Icon(Icons.edit_calendar_outlined),
        title: Text('写日记提醒'),
        subtitle: Text('正在读取设置...'),
      );
    }

    final settings = status.settings;
    final blockEditing = status.issue == DiaryReminderIssue.unsupportedPlatform ||
        status.issue == DiaryReminderIssue.statusUnavailable ||
        status.issue == DiaryReminderIssue.identityUnavailable;
    final canEdit = !blockEditing && !_diaryReminderBusy;
    final message = status.message;

    return Column(
      children: [
        SwitchListTile(
          secondary: const Icon(Icons.edit_calendar_outlined),
          title: const Text('写日记提醒'),
          subtitle: Text(_diaryReminderSubtitle(status)),
          value: settings.enabled,
          onChanged:
              canEdit ? (value) => _handleDiaryReminderToggle(value) : null,
        ),
        ListTile(
          leading: const Icon(Icons.schedule_outlined),
          title: const Text('提醒时间'),
          subtitle: Text(settings.timeLabel),
          trailing: const Icon(Icons.chevron_right),
          enabled: canEdit && settings.enabled,
          onTap: _pickDiaryReminderTime,
        ),
        if (message != null)
          ListTile(
            leading:
                Icon(Icons.warning_amber_rounded, color: colorScheme.error),
            title: Text(message),
            subtitle: status.issue == DiaryReminderIssue.none
                ? null
                : const Text('点按前往系统设置'),
            onTap: status.issue == DiaryReminderIssue.none
                ? null
                : _openDiaryReminderSettings,
          ),
        ListTile(
          leading: const Icon(Icons.notifications_none_rounded),
          title: const Text('发送测试通知'),
          subtitle: const Text('立即验证通知权限、通道与图标是否正常'),
          enabled: !_diaryReminderBusy,
          onTap: _sendDiaryReminderTest,
        ),
      ],
    );
  }

  String _diaryReminderSubtitle(DiaryReminderStatus status) {
    switch (status.issue) {
      case DiaryReminderIssue.unsupportedPlatform:
        return '当前平台不支持';
      case DiaryReminderIssue.statusUnavailable:
        return '读取设置失败';
      case DiaryReminderIssue.identityUnavailable:
        return '请先选择上方用户身份';
      case DiaryReminderIssue.timezoneUnavailable:
        return '系统时区异常，已暂停提醒';
      case DiaryReminderIssue.notificationsDenied:
        return '通知权限未授予';
      case DiaryReminderIssue.channelDisabled:
        return '通知通道已被关闭';
      case DiaryReminderIssue.exactAlarmDenied:
        return status.scheduled ? '已开启（可能延迟几分钟）' : '尚未登记';
      case DiaryReminderIssue.scheduleFailed:
        return status.scheduled ? '已开启' : '排程失败';
      case DiaryReminderIssue.none:
        if (!status.settings.enabled) return '已关闭';
        if (!status.scheduled) return '已开启（未登记，重开抽屉会重试）';
        return '已开启 · 每天 ${status.settings.timeLabel}';
    }
  }

  Future<void> _handleDiaryReminderToggle(bool enabled) async {
    final current = _diaryReminderStatus?.settings;
    if (current == null) return;

    setState(() => _diaryReminderBusy = true);
    try {
      var status = await DiaryReminderService.saveSettings(
        current.copyWith(enabled: enabled),
      );

      if (enabled && status.issue != DiaryReminderIssue.none) {
        status = await DiaryReminderService.requestPermissions();
        if (_shouldRollBackToOff(status)) {
          // 不留下一个永远不会响的「已开启」：明确回滚并告知原因
          status = await DiaryReminderService.saveSettings(
            status.settings.copyWith(enabled: false),
          );
        }
      }

      if (!mounted) return;
      setState(() {
        _diaryReminderStatus = status;
        _diaryReminderBusy = false;
      });
      widget.onChanged();

      final message = status.message;
      if (message != null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(message)));
      }
    } catch (error, stackTrace) {
      AppLogService.instance.error(
        '切换写日记提醒失败',
        source: DiaryReminderService.logSource,
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      setState(() => _diaryReminderBusy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('切换失败，请查看运行日志')),
      );
    }
  }

  /// 这些状态下的「已开启」名不副实，直接回滚成关闭。
  /// 通道被关闭、缺精确闹钟权限属于「能用但降级」，保留开启并由告警行引导。
  bool _shouldRollBackToOff(DiaryReminderStatus status) {
    switch (status.issue) {
      case DiaryReminderIssue.notificationsDenied:
      case DiaryReminderIssue.timezoneUnavailable:
      case DiaryReminderIssue.identityUnavailable:
      case DiaryReminderIssue.scheduleFailed:
      case DiaryReminderIssue.statusUnavailable:
      case DiaryReminderIssue.unsupportedPlatform:
        return true;
      case DiaryReminderIssue.none:
      case DiaryReminderIssue.channelDisabled:
      case DiaryReminderIssue.exactAlarmDenied:
        return false;
    }
  }

  Future<void> _pickDiaryReminderTime() async {
    final current = _diaryReminderStatus?.settings;
    if (current == null) return;

    final picked = await showTimeWheelSheet(
      context,
      initialTime: TimeOfDay(hour: current.hour, minute: current.minute),
      title: '提醒时间',
    );
    if (picked == null || !mounted) return;

    setState(() => _diaryReminderBusy = true);
    try {
      final status = await DiaryReminderService.saveSettings(
        current.copyWith(hour: picked.hour, minute: picked.minute),
      );
      if (!mounted) return;
      setState(() {
        _diaryReminderStatus = status;
        _diaryReminderBusy = false;
      });
      widget.onChanged();
      final message = status.message;
      if (message != null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(message)));
      }
    } catch (error, stackTrace) {
      AppLogService.instance.error(
        '保存写日记提醒时间失败',
        source: DiaryReminderService.logSource,
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      setState(() => _diaryReminderBusy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('保存失败，请查看运行日志')),
      );
    }
  }

  Future<void> _sendDiaryReminderTest() async {
    setState(() => _diaryReminderBusy = true);
    try {
      final status = await DiaryReminderService.sendTestNotification();
      if (!mounted) return;
      setState(() {
        _diaryReminderStatus = status;
        _diaryReminderBusy = false;
      });
      final message = status.message;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            message ?? '测试通知已发送；若没看到，请检查系统通知设置',
          ),
        ),
      );
    } catch (error, stackTrace) {
      AppLogService.instance.error(
        '发送写日记提醒测试通知失败',
        source: DiaryReminderService.logSource,
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      setState(() => _diaryReminderBusy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('发送失败，请查看运行日志')),
      );
    }
  }

  Future<void> _openDiaryReminderSettings() async {
    try {
      await DiaryReminderService.openSystemSettings();
    } catch (error, stackTrace) {
      AppLogService.instance.warning(
        '打开系统通知设置失败',
        source: DiaryReminderService.logSource,
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Widget _buildRemoteSyncSection(BuildContext context, TimeProvider provider) {
    return Column(
      children: [
        SwitchListTile(
          secondary: const Icon(Icons.calendar_month_outlined),
          title: const Text('Google 日历同步'),
          subtitle: Text(
            _identitySwitching
                ? '正在连接 Google...'
                : provider.googleCalendarSyncEnabled
                    ? '已开启'
                    : '已关闭（手动选择用户）',
          ),
          value: provider.googleCalendarSyncEnabled,
          onChanged: _identitySwitching
              ? null
              : (value) => _handleGoogleSyncToggle(context, provider, value),
        ),
      ],
    );
  }

  Future<void> _handleGoogleSyncToggle(
    BuildContext context,
    TimeProvider provider,
    bool enabled,
  ) async {
    setState(() => _identitySwitching = true);
    final ok = await provider.setGoogleCalendarSyncEnabled(enabled);
    if (!context.mounted) return;
    setState(() => _identitySwitching = false);
    widget.onChanged();
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            enabled
                ? (GoogleCalendarService.lastLoginError ?? 'Google 登录未完成')
                : '无法切换到手动身份',
          ),
        ),
      );
    }
  }

  Widget _buildManualIdentitySection(
    BuildContext context,
    TimeProvider provider, {
    required String title,
  }) {
    final selected =
        provider.hasSelectedScheduleUser ? provider.scheduleUser : null;
    // 未选择时强制展开以便选择；选中后默认收起，点击身份行可展开切换
    final expanded = selected == null || _identityExpanded;
    return Column(
      children: [
        ListTile(
          leading: const Icon(Icons.person_pin_outlined),
          title: Text(title),
          subtitle: Text(
            _identitySwitching
                ? '正在切换身份…'
                : selected == null
                    ? '请选择身份后再同步'
                    : '当前身份：${selected == DiaryKind.g ? '乖乖' : '晶晶'}',
          ),
          trailing: Icon(expanded ? Icons.expand_less : Icons.expand_more),
          onTap: () {
            if (_identitySwitching) return;
            setState(() => _identityExpanded = !_identityExpanded);
          },
        ),
        if (expanded)
          // 切换进行中禁止再次选择（桌面端可能要等旧身份补推完）
          AbsorbPointer(
            absorbing: _identitySwitching,
            child: RadioGroup<DiaryKind>(
              groupValue: selected,
              onChanged: (kind) {
                if (kind != null) {
                  _selectIdentity(provider, previous: selected, kind: kind);
                }
              },
              child: const Column(
                children: [
                  RadioListTile<DiaryKind>(
                    title: Text('乖乖'),
                    value: DiaryKind.g,
                  ),
                  RadioListTile<DiaryKind>(
                    title: Text('晶晶'),
                    value: DiaryKind.j,
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  /// 切换日程身份，两端都要二次确认，但文案不同。
  ///
  /// 桌面端本地时间块与待同步队列**不分身份**：切换会把对方身份的远端日程
  /// 合并进本机共享的本地记录，之后本机的修改也会同步到对方身份的文件——
  /// 两个人两台电脑时这就是数据串味。
  /// 移动端本地数据是按身份分片的，切换只是换一整套自己的数据，不会串；
  /// 文案不能说"与现有记录合并"，否则是错的。
  Future<void> _selectIdentity(
    TimeProvider provider, {
    required DiaryKind? previous,
    required DiaryKind kind,
  }) async {
    if (_identitySwitching) return;
    // 首次选择身份（previous == null）是前置条件，没有可切的数据，不打扰。
    if (previous != null && previous != kind) {
      final isDesktop = widget.desktopPlatformOverride ?? isDesktopPlatform;
      final targetLabel = kind == DiaryKind.g ? '乖乖' : '晶晶';
      final content = isDesktop
          ? '本机的时间块不分身份。切换到「$targetLabel」会从对方的远端文件拉取日程，'
              '与本机现有记录合并；之后本机上的修改也会同步到对方身份的文件。\n\n'
              '只想看看对方的日程，请改用首页的「查看对方日程」。'
          : '切换后会显示「$targetLabel」自己的时间块、日记、出行、打卡、目标等数据，'
              '与其它身份的数据互不影响。\n\n'
              '只想看看对方的日程，请改用首页的「查看对方日程」。';
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('确认切换身份'),
          content: Text(content),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('切换'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    setState(() => _identitySwitching = true);
    try {
      // 桌面端切换前可能要先等旧身份的补推跑完，必须 await 并在期间禁用选择，
      // 否则用户能在这段时间里再点另一个身份，两个切换流程会交错。
      await provider.setScheduleUser(kind);
    } finally {
      if (mounted) {
        setState(() {
          _identitySwitching = false;
          _identityExpanded = false; // 选中后收起
        });
      }
    }
    if (mounted) widget.onChanged();
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

  Future<void> _checkForUpdate(BuildContext context) async {
    final result = await UpdateService.checkForUpdate();

    if (!context.mounted) return;

    if (result.hasError) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result.error!)),
      );
      return;
    }

    if (!result.hasUpdate) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('当前已是最新版本')),
      );
      return;
    }

    final updateInfo = result.info!;

    // 显示更新内容弹窗
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('发现新版本 v${updateInfo.version}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (updateInfo.releaseNotes.isNotEmpty) ...[
              const Text('更新内容：',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Container(
                constraints: const BoxConstraints(maxHeight: 200),
                child: SingleChildScrollView(
                  child: Text(updateInfo.releaseNotes),
                ),
              ),
            ] else
              const Text('暂无更新说明'),
            if (!updateInfo.canAutoInstall) ...[
              const SizedBox(height: 12),
              Text(
                '该发布缺少可信的 SHA-256 校验摘要，仅可打开发布页手动下载；应用不会自动安装。',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('稍后'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(updateInfo.canAutoInstall ? '下载更新' : '打开发布页'),
          ),
        ],
      ),
    );

    if (confirmed == true && context.mounted) {
      if (updateInfo.canAutoInstall) {
        await UpdateService.downloadAndInstall(
          updateInfo.downloadUrl,
          updateInfo.version,
          context,
        );
      } else if (!await UpdateService.openReleasePage(updateInfo.version) &&
          context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('无法打开发布页，请稍后重试')),
        );
      }
    }
  }

  Widget _buildLoginSection(
    BuildContext context,
    GoogleCalendarUser? googleUser,
    TimeProvider provider,
  ) {
    if (googleUser != null) {
      final surface = AppSurfaces.of(context).card;
      final avatarBg = AppSemanticColors.tint(
          Theme.of(context).colorScheme.primary, surface, 0.12);
      final onAvatarBg = AppSemanticColors.onTint(
          Theme.of(context).colorScheme.primary, surface,
          alpha: 0.12);
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 28,
                  backgroundColor: avatarBg,
                  backgroundImage: googleUser.photoUrl != null
                      ? NetworkImage(googleUser.photoUrl!)
                      : null,
                  child: googleUser.photoUrl == null
                      ? Icon(
                          Icons.person,
                          size: 28,
                          color: onAvatarBg,
                        )
                      : null,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        googleUser.label,
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
                              color: GoogleCalendarService.isSignedIn
                                  ? Theme.of(context).colorScheme.primary
                                  : Theme.of(context).colorScheme.outline,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            GoogleCalendarService.isSignedIn
                                ? '日历已连接'
                                : '已识别身份，日历未连接',
                            style: TextStyle(
                              fontSize: 11,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
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
            if (!GoogleCalendarService.isSignedIn) ...[
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  icon: const Icon(Icons.link, size: 18),
                  label: const Text('重新连接 Google 日历'),
                  onPressed: () => _connectGoogle(context, provider),
                ),
              ),
              const SizedBox(height: 8),
            ],
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.logout_rounded, size: 18),
                label: const Text('退出登录'),
                onPressed: () async {
                  await GoogleCalendarService.logout(
                    clearManualIdentity: false,
                  );
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
              onPressed: () => _connectGoogle(context, provider),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _connectGoogle(
      BuildContext context, TimeProvider provider) async {
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
    final ok = await provider.setGoogleCalendarSyncEnabled(true);
    if (!context.mounted) return;
    if (ok) {
      provider.synchronizeCalendar();
      widget.onChanged();
      Navigator.pop(context);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            GoogleCalendarService.lastLoginError ?? 'Google 登录失败',
          ),
        ),
      );
    }
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

  String _backupExportedAtLabel(String? exportedAt) {
    if (exportedAt == null || exportedAt.trim().isEmpty) {
      return '未知导出时间';
    }
    final display =
        exportedAt.length > 16 ? exportedAt.substring(0, 16) : exportedAt;
    return '导出时间：${display.replaceFirst('T', ' ')}';
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
    final exportedLabel = _backupExportedAtLabel(preview.exportedAt);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认导入'),
        content: Text(
          '导入将覆盖当前日程数据，此操作不可撤销。\n'
          '备份包含时间块、分类、目标、日程模板及相关同步状态；'
          '不会覆盖日记、出行、打卡、照片、AI 复盘、日志或应用设置。\n\n'
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
