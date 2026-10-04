import 'dart:async';
import 'dart:io';

import '../utils/platform_features.dart';

import 'package:flutter/material.dart';
import '../models/diary_reminder.dart';
import '../models/google_calendar_user.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import '../providers/theme_mode_provider.dart';
import '../providers/background_image_provider.dart';
import '../providers/time_provider.dart';
import '../providers/main_tab_provider.dart';
import '../screens/desktop_shortcut_settings_screen.dart';
import '../providers/desktop_shortcut_provider.dart';
import '../services/app_log_service.dart';
import '../services/data_backup_service.dart';
import '../services/diary_reminder_service.dart';
import '../services/update_service.dart';
import '../screens/app_log_screen.dart';
import '../screens/main_tab_settings_screen.dart';
import '../screens/sync_center_screen.dart';
import '../screens/word_cloud_screen.dart';
import '../screens/on_this_day_screen.dart';
import '../services/google_calendar_service.dart';
import '../services/app_identity_service.dart';
import '../models/diary_kind.dart';
import '../theme/app_semantic_colors.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';
import 'background_image_layer.dart';
import 'theme_color_sheet.dart';
import 'time_wheel_sheet.dart';

enum _ProfileDrawerSection {
  account('身份与连接'),
  review('记录回顾'),
  appearance('外观设置'),
  reminders('提醒设置'),
  backup('数据备份'),
  app('关于应用');

  const _ProfileDrawerSection(this.title);

  final String title;
}

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
  _ProfileDrawerSection? _expandedSection;
  final _listKey = GlobalKey(debugLabel: 'profile-settings-list');
  final _sectionKeys = {
    for (final section in _ProfileDrawerSection.values)
      section: GlobalKey(debugLabel: section.name),
  };
  final _scrollController = ScrollController();
  late final Future<PackageInfo> _packageInfo = PackageInfo.fromPlatform();
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

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _toggleSection(_ProfileDrawerSection section) {
    final previous = _expandedSection;
    setState(() {
      _expandedSection = previous == section ? null : section;
    });
    if (previous == _ProfileDrawerSection.account ||
        _expandedSection == _ProfileDrawerSection.reminders) {
      unawaited(_loadDiaryReminderStatus());
    }
  }

  void _revealExpandedSection(_ProfileDrawerSection section) {
    if (!mounted || _expandedSection != section) return;
    final sectionContext = _sectionKeys[section]?.currentContext;
    final sectionBox = sectionContext?.findRenderObject();
    final listBox = _listKey.currentContext?.findRenderObject();
    if (sectionContext == null ||
        sectionBox is! RenderBox ||
        listBox is! RenderBox ||
        !sectionBox.hasSize ||
        !listBox.hasSize) {
      return;
    }
    final offset = sectionBox.localToGlobal(Offset.zero, ancestor: listBox);
    if (offset.dy >= 0 &&
        offset.dy + sectionBox.size.height <= listBox.size.height) {
      return;
    }
    unawaited(Scrollable.ensureVisible(
      sectionContext,
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : kThemeAnimationDuration,
      curve: Curves.easeInOut,
    ));
  }

  void _closeDrawer() {
    Navigator.of(context).pop();
  }

  void _openScreen(Widget screen) {
    final navigator = Navigator.of(context);
    _closeDrawer();
    navigator.push(MaterialPageRoute<void>(builder: (_) => screen));
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
    context.watch<BackgroundImageProvider>();
    final themeModeProvider = context.watch<ThemeModeProvider>();
    final colorScheme = Theme.of(context).colorScheme;
    final isAndroid = widget.androidPlatformOverride ?? Platform.isAndroid;
    final isDesktop = widget.desktopPlatformOverride ?? isDesktopPlatform;

    return Drawer(
      backgroundColor: Colors.transparent,
      child: BackgroundImagePanelLayer(
        panelColor: colorScheme.surface,
        panelOpacity: AppWallpaperTheme.of(context).surfaceOpacity,
        child: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: _buildSettingsList(
                  context,
                  provider,
                  themeModeProvider,
                  isAndroid,
                  isDesktop,
                ),
              ),
              _buildVersionFooter(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSettingsList(
    BuildContext context,
    TimeProvider provider,
    ThemeModeProvider themeModeProvider,
    bool isAndroid,
    bool isDesktop,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final reminderStatus = _diaryReminderStatus;
    final reminderNeedsAttention = reminderStatus != null &&
        (reminderStatus.issue != DiaryReminderIssue.none ||
            reminderStatus.message != null);

    return ListView(
      key: _listKey,
      controller: _scrollController,
      padding: AppSpacing.page,
      children: [
        const SizedBox(height: AppSpacing.lg),
        _buildExpandableSection(
          context,
          section: _ProfileDrawerSection.account,
          header: _buildIdentityHeader(context, provider, isDesktop),
        ),
        const SizedBox(height: AppSpacing.md),
        Material(
          color: context.wallpaperFill(colorScheme.primaryContainer),
          borderRadius: AppRadius.controlAll,
          clipBehavior: Clip.antiAlias,
          child: ListTile(
            leading:
                Icon(Icons.sync_rounded, color: colorScheme.onPrimaryContainer),
            title: Text('同步中心',
                style: AppText.sectionTitle
                    .copyWith(color: colorScheme.onPrimaryContainer)),
            subtitle: Text(
              provider.hasPendingSync
                  ? '有 ${provider.pendingSyncDates.length} 天待同步'
                  : '查看各模块同步状态',
              style: AppText.caption
                  .copyWith(color: colorScheme.onPrimaryContainer),
            ),
            trailing: Icon(Icons.chevron_right,
                color: colorScheme.onPrimaryContainer),
            onTap: () => _openScreen(const SyncCenterScreen()),
          ),
        ),
        const SizedBox(height: AppSpacing.xl),
        Text('工具与设置',
            style: AppText.caption.copyWith(
              color: colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            )),
        const SizedBox(height: AppSpacing.sm),
        _buildSettingsPanel(context, [
          _buildGroup(
            context,
            section: _ProfileDrawerSection.review,
            icon: Icons.history_rounded,
            subtitle: '事件词云 · 那年今日',
          ),
          _buildGroup(
            context,
            section: _ProfileDrawerSection.appearance,
            icon: Icons.palette_outlined,
            subtitle: '${switch (themeModeProvider.themeMode) {
              ThemeMode.system => '跟随系统',
              ThemeMode.light => '浅色模式',
              ThemeMode.dark => '深色模式',
            }} · ${AppThemeColorPreset.labelFor(themeModeProvider.themeColor)}',
          ),
          if (isAndroid)
            _buildGroup(
              context,
              section: _ProfileDrawerSection.reminders,
              icon: Icons.notifications_none_rounded,
              subtitle: !_diaryReminderLoaded || reminderStatus == null
                  ? '正在读取设置…'
                  : _diaryReminderSubtitle(reminderStatus),
              needsAttention: reminderNeedsAttention,
            ),
          _buildGroup(
            context,
            section: _ProfileDrawerSection.backup,
            icon: Icons.backup_outlined,
            subtitle: '导出备份 · 导入备份',
          ),
          _buildGroup(
            context,
            section: _ProfileDrawerSection.app,
            icon: Icons.info_outline_rounded,
            subtitle: '检查更新 · 运行日志',
          ),
        ]),
        const SizedBox(height: AppSpacing.lg),
      ],
    );
  }

  Widget _buildIdentityHeader(
    BuildContext context,
    TimeProvider provider,
    bool isDesktop,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final googleMode = !isDesktop && provider.isGoogleIdentityMode;
    final googleUser = googleMode ? AppIdentityService.googleUser : null;
    final selected = provider.hasSelectedScheduleUser;
    final label = googleMode
        ? googleUser?.label ?? '连接 Google 日历'
        : selected
            ? (provider.scheduleUser == DiaryKind.g ? '乖乖' : '晶晶')
            : '选择用户身份';
    final subtitle = _identitySwitching
        ? '正在切换身份…'
        : googleMode
            ? GoogleCalendarService.isSignedIn
                ? '当前身份 · Google 日历已连接'
                : '当前身份 · Google 日历未连接'
            : selected
                ? '当前身份 · 手动模式'
                : '选择后可同步数据';

    return Semantics(
      expanded: _expandedSection == _ProfileDrawerSection.account,
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        leading: CircleAvatar(
          radius: AppSizes.button / 2,
          backgroundColor: context.wallpaperFill(colorScheme.primaryContainer),
          foregroundColor: colorScheme.onPrimaryContainer,
          backgroundImage: googleUser?.photoUrl != null
              ? NetworkImage(googleUser!.photoUrl!)
              : null,
          child: googleUser?.photoUrl != null
              ? null
              : selected
                  ? Text(label.characters.first, style: AppText.sectionTitle)
                  : const Icon(Icons.person_outline_rounded),
        ),
        title: Text(label, style: AppText.sectionTitle),
        subtitle: Text(subtitle, style: AppText.caption),
        trailing: _buildExpansionArrow(context, _ProfileDrawerSection.account),
        onTap: () => _toggleSection(_ProfileDrawerSection.account),
      ),
    );
  }

  Widget _buildGroup(
    BuildContext context, {
    required _ProfileDrawerSection section,
    required IconData icon,
    required String subtitle,
    bool needsAttention = false,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final expanded = _expandedSection == section;
    return _buildExpandableSection(
      context,
      section: section,
      header: Semantics(
        expanded: expanded,
        child: ListTile(
          leading: Icon(icon,
              color: expanded
                  ? colorScheme.primary
                  : colorScheme.onSurfaceVariant),
          title: Text(section.title,
              style: AppText.sectionTitle.copyWith(
                color: expanded ? colorScheme.primary : colorScheme.onSurface,
              )),
          subtitle: expanded
              ? null
              : Text(
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.caption.copyWith(
                    color: needsAttention
                        ? colorScheme.error
                        : colorScheme.onSurfaceVariant,
                  ),
                ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (needsAttention) ...[
                Icon(Icons.error_outline_rounded,
                    color: colorScheme.error, size: AppSpacing.lg),
                const SizedBox(width: AppSpacing.xs),
              ],
              _buildExpansionArrow(context, section),
            ],
          ),
          onTap: () => _toggleSection(section),
        ),
      ),
    );
  }

  Widget _buildExpansionArrow(
    BuildContext context,
    _ProfileDrawerSection section,
  ) {
    return AnimatedRotation(
      turns: _expandedSection == section ? 0.25 : 0,
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : kThemeAnimationDuration,
      curve: Curves.easeInOut,
      child: const Icon(Icons.chevron_right),
    );
  }

  Widget _buildExpandableSection(
    BuildContext context, {
    required _ProfileDrawerSection section,
    required Widget header,
  }) {
    return Column(
      key: _sectionKeys[section],
      mainAxisSize: MainAxisSize.min,
      children: [
        header,
        AnimatedSize(
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : kThemeAnimationDuration,
          curve: Curves.easeInOut,
          alignment: Alignment.topCenter,
          onEnd: () => _revealExpandedSection(section),
          child: _expandedSection == section
              ? Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.sm,
                    0,
                    AppSpacing.sm,
                    AppSpacing.sm,
                  ),
                  child: Material(
                    color:
                        context.wallpaperFill(AppSurfaces.of(context).subtle),
                    borderRadius: AppRadius.controlAll,
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: _buildSectionItems(context, section),
                    ),
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }

  Widget _buildSettingsPanel(BuildContext context, List<Widget> children) {
    return Card(
      margin: EdgeInsets.zero,
      color: context.wallpaperFill(AppSurfaces.of(context).card),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0)
              const Divider(
                height: AppSizes.hairline,
                indent: AppSpacing.lg + AppSpacing.xl + AppSpacing.lg,
              ),
            children[i],
          ],
        ],
      ),
    );
  }

  List<Widget> _buildSectionItems(
    BuildContext context,
    _ProfileDrawerSection section,
  ) {
    final provider = context.read<TimeProvider>();
    final themeModeProvider = context.read<ThemeModeProvider>();
    final backgroundImage = context.read<BackgroundImageProvider>();
    final isDesktop = widget.desktopPlatformOverride ?? isDesktopPlatform;
    return switch (section) {
      _ProfileDrawerSection.account => [
          if (isDesktop || provider.isManualIdentityMode)
            _buildManualIdentitySection(context, provider, title: '用户身份')
          else
            _buildLoginSection(
                context, AppIdentityService.googleUser, provider),
          if (!isDesktop) _buildRemoteSyncSection(context, provider),
        ],
      _ProfileDrawerSection.review => [
          ListTile(
            leading: const Icon(Icons.bubble_chart_outlined),
            title: const Text('事件词云'),
            subtitle: const Text('查看事件时长与出现次数'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              _closeDrawer();
              WordCloudScreen.open(context);
            },
          ),
          ListTile(
            leading: const Icon(Icons.history_rounded),
            title: const Text('那年今日'),
            subtitle: const Text('回顾往年今天的记录'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              _closeDrawer();
              OnThisDayScreen.open(context);
            },
          ),
        ],
      _ProfileDrawerSection.appearance => [
          if (isDesktop && context.read<DesktopShortcutProvider?>() != null)
            ListTile(
              leading: const Icon(Icons.keyboard_outlined),
              title: const Text('键盘快捷键'),
              subtitle: const Text('查看、修改或停用快捷键'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _openScreen(DesktopShortcutSettingsScreen(
                provider: context.read<DesktopShortcutProvider>(),
              )),
            ),
          ListTile(
            leading: const Icon(Icons.view_day_outlined),
            title: const Text('底部标签'),
            subtitle: const Text('自定义显示与顺序'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _openScreen(
              MainTabSettingsScreen(provider: context.read<MainTabProvider>()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.palette_outlined),
            title: const Text('外观模式'),
            subtitle: DropdownButtonHideUnderline(
              child: DropdownButton<ThemeMode>(
                isExpanded: true,
                value: themeModeProvider.themeMode,
                style: AppText.body
                    .copyWith(color: Theme.of(context).colorScheme.onSurface),
                onChanged: (mode) {
                  if (mode != null) themeModeProvider.setThemeMode(mode);
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
            leading: const Icon(Icons.color_lens_outlined),
            title: const Text('主题色'),
            subtitle: Text(
                AppThemeColorPreset.labelFor(themeModeProvider.themeColor)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () =>
                showThemeColorSheet(context, provider: themeModeProvider),
          ),
          ListTile(
            leading: const Icon(Icons.wallpaper_outlined),
            title: const Text('背景图片'),
            subtitle: Text(!backgroundImage.hasPhoto
                ? '未设置'
                : backgroundImage.enabled
                    ? '已启用'
                    : '已设置 · 未启用'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _openBackgroundImageSettings(backgroundImage),
          ),
        ],
      _ProfileDrawerSection.reminders => [
          _buildDiaryReminderSection(context, Theme.of(context).colorScheme),
        ],
      _ProfileDrawerSection.backup => [
          ListTile(
            leading: const Icon(Icons.upload_file_outlined),
            title: const Text('导出备份'),
            subtitle: const Text('保存 JSON 到本地'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              final rootContext =
                  Navigator.of(context, rootNavigator: true).context;
              _closeDrawer();
              await _handleExport(rootContext, provider);
            },
          ),
          ListTile(
            leading: const Icon(Icons.download_outlined),
            title: const Text('导入备份'),
            subtitle: const Text('从 JSON 恢复数据'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              final rootContext =
                  Navigator.of(context, rootNavigator: true).context;
              _closeDrawer();
              await _handleImport(rootContext, provider);
            },
          ),
        ],
      _ProfileDrawerSection.app => [
          ListTile(
            leading: const Icon(Icons.system_update_outlined),
            title: const Text('检查更新'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _checkForUpdate(context),
          ),
          ListTile(
            leading: const Icon(Icons.receipt_long_outlined),
            title: const Text('运行日志'),
            subtitle: const Text('查看问题记录并导出'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _openScreen(const AppLogScreen()),
          ),
        ],
    };
  }

  Future<void> _openBackgroundImageSettings(
    BackgroundImageProvider backgroundImage,
  ) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: AppSurfaces.of(context).overlay,
      shape: const RoundedRectangleBorder(
        borderRadius: AppRadius.sheetTop,
      ),
      clipBehavior: Clip.antiAlias,
      builder: (_) => _BackgroundImageSettingsSheet(
        backgroundImage: backgroundImage,
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
    final blockEditing =
        status.issue == DiaryReminderIssue.unsupportedPlatform ||
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
        return '请先选择用户身份';
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
    unawaited(_loadDiaryReminderStatus());
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
        ),
        // 身份分组展开后直接列出选项，切换期间禁止重复选择。
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
        });
      }
    }
    if (mounted) {
      unawaited(_loadDiaryReminderStatus());
      widget.onChanged();
    }
  }

  Widget _buildVersionFooter() {
    return FutureBuilder<PackageInfo>(
      future: _packageInfo,
      builder: (context, snapshot) {
        final version = snapshot.data?.version;
        if (version == null || version.isEmpty) {
          return const SizedBox(height: AppSpacing.lg);
        }
        return Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.sm,
            AppSpacing.lg,
            AppSpacing.lg,
          ),
          child: DefaultTextStyle.merge(
            style: AppText.caption.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [const Text('Time Manager'), Text('v$version')],
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
            if (updateInfo.formattedSize != null) ...[
              const SizedBox(height: 12),
              Text('安装包大小：${updateInfo.formattedSize}'),
            ],
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
          expectedSizeBytes: updateInfo.sizeBytes,
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
                  if (context.mounted) _closeDrawer();
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
                backgroundColor: context.wallpaperFill(
                    Theme.of(context).colorScheme.surfaceContainerHighest),
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
      _closeDrawer();
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

class _BackgroundImageSettingsSheet extends StatefulWidget {
  const _BackgroundImageSettingsSheet({required this.backgroundImage});

  final BackgroundImageProvider backgroundImage;

  @override
  State<_BackgroundImageSettingsSheet> createState() =>
      _BackgroundImageSettingsSheetState();
}

class _BackgroundImageSettingsSheetState
    extends State<_BackgroundImageSettingsSheet> {
  bool _picking = false;
  String? _message;

  Future<void> _pickPhoto() async {
    if (_picking) return;
    setState(() {
      _picking = true;
      _message = null;
    });

    final result = await widget.backgroundImage.pickAndApply();
    if (!mounted) return;
    setState(() {
      _picking = false;
      _message = switch (result) {
        BackgroundImagePickResult.applied ||
        BackgroundImagePickResult.cancelled =>
          null,
        BackgroundImagePickResult.tooLarge => '照片不能超过 32 MB',
        BackgroundImagePickResult.unavailable => '无法读取这张照片，请重新选择',
        BackgroundImagePickResult.failed => '照片保存失败，请重试',
      };
    });
  }

  Future<void> _setEnabled(bool value) async {
    try {
      await widget.backgroundImage.setEnabled(value);
      if (mounted) setState(() => _message = null);
    } on Object {
      if (mounted) setState(() => _message = '保存背景设置失败，请重试');
    }
  }

  Future<void> _commitOpacity() async {
    try {
      await widget.backgroundImage.commitOpacity();
      if (mounted) setState(() => _message = null);
    } on Object {
      if (mounted) setState(() => _message = '保存不透明度失败，请重试');
    }
  }

  Future<void> _commitSurfaceOpacity() async {
    try {
      await widget.backgroundImage.commitSurfaceOpacity();
      if (mounted) setState(() => _message = null);
    } on Object {
      if (mounted) setState(() => _message = '保存界面不透明度失败，请重试');
    }
  }

  Future<void> _removePhoto() async {
    try {
      await widget.backgroundImage.clear();
      if (mounted) setState(() => _message = null);
    } on Object {
      if (mounted) setState(() => _message = '移除照片失败，请重试');
    }
  }

  @override
  Widget build(BuildContext context) {
    final background = widget.backgroundImage;
    final colorScheme = Theme.of(context).colorScheme;
    final wallpaperTheme = AppWallpaperTheme.of(context);
    final safePercent = (wallpaperTheme.safePhotoOpacity * 100).round();
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    return AnimatedBuilder(
      animation: background,
      builder: (context, _) {
        final opacityPercent = (background.opacity * 100).round();
        final surfaceOpacityPercent = (background.surfaceOpacity * 100).round();
        final opacityExceedsSafeValue =
            background.opacity > wallpaperTheme.safePhotoOpacity;
        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.md,
            AppSpacing.lg,
            AppSpacing.lg + bottomInset,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: AppSizes.hairline * 4,
                  decoration: BoxDecoration(
                    color: colorScheme.outlineVariant,
                    borderRadius: AppRadius.badgeAll,
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              Text('背景图片', style: AppText.sectionTitle),
              const SizedBox(height: AppSpacing.md),
              BackgroundImagePreview(
                path: background.hasPhoto ? background.path : null,
                opacity: background.opacity,
              ),
              const SizedBox(height: AppSpacing.md),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _picking ? null : _pickPhoto,
                  icon: _picking
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.photo_library_outlined),
                  label: Text(background.hasPhoto ? '更换照片' : '选择照片'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, AppSizes.minTapTarget),
                  ),
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('启用背景'),
                value: background.enabled,
                onChanged: _setEnabled,
              ),
              Row(
                children: [
                  const Expanded(child: Text('照片不透明度')),
                  Text('$opacityPercent%'),
                ],
              ),
              Slider(
                value: background.opacity,
                min: 0,
                max: 1,
                divisions: 100,
                label: '$opacityPercent%',
                onChanged: background.setOpacity,
                onChangeEnd: (_) => _commitOpacity(),
              ),
              if (opacityExceedsSafeValue)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.warning_amber_rounded,
                        color: colorScheme.error,
                        size: 20,
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Text(
                          '当前不透明度高于 $safePercent% 的安全建议值，'
                          '照片可能降低文字和图标的对比度。',
                          style: AppText.caption.copyWith(
                            color: colorScheme.error,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              Row(
                children: [
                  const Expanded(child: Text('界面不透明度')),
                  Text('$surfaceOpacityPercent%'),
                ],
              ),
              Slider(
                value: background.surfaceOpacity,
                min: BackgroundImageProvider.minSurfaceOpacity,
                max: 1,
                divisions: 80,
                label: '$surfaceOpacityPercent%',
                onChanged: background.setSurfaceOpacity,
                onChangeEnd: (_) => _commitSurfaceOpacity(),
              ),
              if (_message != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                  child: Text(
                    _message!,
                    style: AppText.caption.copyWith(color: colorScheme.error),
                  ),
                ),
              SizedBox(
                width: double.infinity,
                child: TextButton.icon(
                  onPressed: background.hasPhoto ? _removePhoto : null,
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('移除背景照片'),
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, AppSizes.minTapTarget),
                    foregroundColor: colorScheme.error,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
