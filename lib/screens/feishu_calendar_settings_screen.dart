import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/diary_kind.dart';
import '../models/feishu_calendar_models.dart';
import '../providers/time_provider.dart';
import '../services/app_identity_service.dart';
import '../services/feishu_auth_sync.dart';
import '../services/feishu_calendar_constants.dart';
import '../services/feishu_calendar_sync_service.dart';
import '../services/feishu_credentials_store.dart';
import '../services/feishu_oauth_service.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';
import '../utils/app_snack_bar.dart';

/// 「飞书日历同步」设置页：连接、自动同步、手动补同步。
///
/// 单向：只把本 App 的时间块写到飞书，不会把飞书上的改动读回来。
class FeishuCalendarSettingsScreen extends StatefulWidget {
  const FeishuCalendarSettingsScreen({
    super.key,
    this.oauthService,
    this.syncService,
  });

  final FeishuOAuthService? oauthService;
  final FeishuCalendarSyncService? syncService;

  @override
  State<FeishuCalendarSettingsScreen> createState() =>
      _FeishuCalendarSettingsScreenState();
}

class _FeishuCalendarSettingsScreenState
    extends State<FeishuCalendarSettingsScreen> {
  final _appIdController = TextEditingController();
  final _appSecretController = TextEditingController();
  final _pasteController = TextEditingController();

  late final FeishuOAuthService _oauth =
      widget.oauthService ?? FeishuOAuthService();
  late final FeishuCalendarSyncService _sync =
      widget.syncService ?? FeishuCalendarSyncService.instance;

  DiaryKind? _kind;
  bool _loading = true;
  bool _hasCredentials = false;
  bool _connected = false;
  bool _needsReauth = false;
  bool _autoSync = false;
  bool _authorizing = false;
  bool _obscureSecret = true;
  DateTime? _lastSyncAt;
  String? _lastSummary;
  String? _authError;
  String? _authUri;
  FeishuAuthFlow? _flow;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    unawaited(_flow?.cancel());
    _appIdController.dispose();
    _appSecretController.dispose();
    _pasteController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final kind = AppIdentityService.personKind;
    if (kind == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    final localCredentials = await FeishuCredentialStore.loadCredentials(kind);
    final localTokens = await FeishuCredentialStore.loadTokens(kind);
    if (localCredentials == null || localTokens == null) {
      // 另一台设备授权过就能直接用，不用在这台再走一遍浏览器授权
      await _oauth.syncFromRemote(kind);
    }
    final credentials = await FeishuCredentialStore.loadCredentials(kind);
    final tokens = await FeishuCredentialStore.loadTokens(kind);
    final autoSync = await FeishuCredentialStore.loadAutoSync(kind);
    final needsReauth = await FeishuCredentialStore.loadNeedsReauth(kind);
    final lastSyncAt = await FeishuCredentialStore.loadLastSyncAt(kind);
    final lastSummary = await FeishuCredentialStore.loadLastSyncSummary(kind);
    final flow = await _oauth.resumePendingAuthorization(kind: kind);
    if (!mounted) return;
    setState(() {
      _kind = kind;
      _hasCredentials = credentials != null;
      _connected = tokens != null && !needsReauth;
      _needsReauth = needsReauth;
      _autoSync = autoSync;
      _lastSyncAt = lastSyncAt;
      _lastSummary = lastSummary;
      _flow = flow;
      _loading = false;
      if (credentials != null) {
        _appIdController.text = credentials.appId;
        _appSecretController.text = credentials.appSecret;
      }
    });
    // 另一台设备开着自动同步时，这一页会把开关一起继承过来，但此时
    // TimeProvider 的缓存可能还是「没读过」。同步刷新一次，否则开关
    // 显示为开着、实际推送仍被跳过。
    final provider = context.read<TimeProvider?>();
    if (provider != null) {
      await provider.refreshFeishuAutoSyncFromStore();
    }
  }

  Future<void> _saveAndAuthorize() async {
    final kind = _kind;
    if (kind == null) return;
    final credentials = FeishuCredentials(
      appId: _appIdController.text.trim(),
      appSecret: _appSecretController.text.trim(),
    );
    if (!credentials.isComplete) {
      showAppSnackBar(context, '请先填写 App ID 和 App Secret');
      return;
    }

    setState(() {
      _authorizing = true;
      _authError = null;
    });

    FeishuAuthFlow flow;
    try {
      await FeishuCredentialStore.saveCredentials(kind, credentials);
      flow = await _oauth.beginAuthorization(
        kind: kind,
        credentials: credentials,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _authorizing = false;
        _authError = '发起授权失败：$e';
      });
      return;
    }
    _flow = flow;
    setState(() => _authUri = flow.authUri.toString());

    var launched = false;
    try {
      launched = await launchUrl(
        flow.authUri,
        mode: LaunchMode.externalApplication,
      ).timeout(const Duration(seconds: 10), onTimeout: () => false);
    } on Object {
      launched = false;
    }
    if (!mounted) return;
    if (!launched) {
      setState(() {
        _authorizing = false;
        _authError = '没能自动打开浏览器，点上面的「复制链接」，在浏览器里粘贴打开';
      });
      return;
    }

    final result = await flow.result;
    if (!mounted) return;
    await _finishAuthorization(result);
  }

  Future<void> _copyAuthUri() async {
    final uri = _authUri;
    if (uri == null) return;
    await Clipboard.setData(ClipboardData(text: uri));
    if (!mounted) return;
    showAppSnackBar(context, '授权链接已复制');
  }

  Future<void> _copyRedirectUri() async {
    await Clipboard.setData(
      ClipboardData(text: FeishuCalendarConfig.redirectUri),
    );
    if (!mounted) return;
    showAppSnackBar(context, '重定向地址已复制');
  }

  Future<void> _openAuthUriAgain() async {
    final uri = _authUri;
    if (uri == null) return;
    var launched = false;
    try {
      launched = await launchUrl(
        Uri.parse(uri),
        mode: LaunchMode.externalApplication,
      ).timeout(const Duration(seconds: 10), onTimeout: () => false);
    } on Object {
      launched = false;
    }
    if (!mounted || launched) return;
    setState(() => _authError = '还是没能打开浏览器，请复制链接后手动粘贴打开');
  }

  Future<void> _cancelAuthorization() async {
    final flow = _flow;
    await flow?.cancel();
    if (!mounted) return;
    setState(() {
      _authorizing = false;
      _flow = null;
      _authUri = null;
      _authError = null;
    });
  }

  Future<void> _submitPastedCallback() async {
    final text = _pasteController.text.trim();
    if (text.isEmpty) {
      showAppSnackBar(context, '请先粘贴回调链接或授权码');
      return;
    }
    var flow = _flow;
    if (flow == null) {
      final kind = _kind;
      if (kind == null) return;
      flow = await _oauth.resumePendingAuthorization(kind: kind);
      if (flow == null) {
        if (!mounted) return;
        setState(() => _authError = '授权已过期，请重新发起授权');
        return;
      }
      _flow = flow;
    }
    FeishuAuthResult result;
    try {
      result = await flow.submitCallbackText(text);
    } catch (e) {
      if (!mounted) return;
      setState(() => _authError = '完成授权失败：$e');
      return;
    }
    if (!mounted) return;
    await _finishAuthorization(result);
  }

  Future<void> _finishAuthorization(FeishuAuthResult result) async {
    setState(() {
      _authorizing = false;
      _authError = result.success ? null : (result.message ?? '授权失败');
      _flow = null;
      _authUri = null;
    });
    if (result.success) {
      _pasteController.clear();
      showAppSnackBar(context, '飞书日历已连接');
      // 授权失效期间暂停的待推日期现在可以补推了。
      unawaited(context.read<TimeProvider>().resumeFeishuSyncAfterAuth());
      await _load();
    } else {
      showAppSnackBar(context, result.message ?? '授权失败');
    }
  }

  Future<void> _disconnect() async {
    final kind = _kind;
    if (kind == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('断开飞书日历'),
        content: const Text(
          '会清除这台设备和其它设备的飞书授权（需要重新授权），'
          '但不会删除飞书日历上已同步的日程。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('断开'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await FeishuCredentialStore.clearTokens(kind);
    await FeishuCredentialStore.saveNeedsReauth(kind, false);
    final revoked = await FeishuAuthSync().revoke(kind);
    if (!mounted) return;
    showAppSnackBar(
      context,
      revoked ? '已断开飞书日历' : '已在本机断开，但没能同步到仓库：另一台设备可能还连着，检查网络后再点一次「断开连接」',
    );
    await _load();
  }

  Future<void> _toggleAutoSync(TimeProvider provider, bool value) async {
    setState(() => _autoSync = value);
    await provider.setFeishuAutoSyncEnabled(value);
  }

  Future<void> _syncRecentDays(TimeProvider provider) async {
    final summary = await provider.syncFeishuRecentDays();
    if (!mounted) return;
    if (summary == null) {
      showAppSnackBar(context, '请先选择身份，并确认已连接飞书');
      return;
    }
    _showSummary(summary);
    await _load();
  }

  Future<void> _syncAllDays(TimeProvider provider) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('同步全部有记录的日期'),
        content: const Text('会逐日重建飞书上的日程，日期多时耗时较长。继续吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('开始'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final summary = await provider.syncFeishuAllRecordedDays();
    if (!mounted) return;
    if (summary == null) {
      showAppSnackBar(context, '没有需要同步的日期');
      return;
    }
    _showSummary(summary);
    await _load();
  }

  void _showSummary(FeishuSyncSummary summary) {
    final text = summary.message ?? summary.describe();
    showAppSnackBar(context, text);
    if (summary.needReauth) {
      setState(() {
        _connected = false;
        _needsReauth = true;
        _authError = '飞书授权已失效，请重新授权';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<TimeProvider>();
    return Scaffold(
      appBar: AppBar(title: const Text('飞书日历同步')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: AppSizes.desktopFormMaxWidth,
                ),
                child: ListView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.pageHorizontal,
                    vertical: AppSpacing.sm,
                  ),
                  children: [
                    _buildStatusCard(context),
                    const SizedBox(height: AppSpacing.lg),
                    if (_kind == null)
                      _buildNoIdentity(context)
                    else ...[
                      _buildCredentialsCard(context),
                      const SizedBox(height: AppSpacing.lg),
                      if (_connected) ...[
                        _buildSyncCard(context, provider),
                        const SizedBox(height: AppSpacing.lg),
                        _buildDisconnectTile(context),
                        const SizedBox(height: AppSpacing.lg),
                      ],
                      _buildSetupGuide(context),
                    ],
                  ],
                ),
              ),
            ),
    );
  }

  Widget _buildStatusCard(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final rows = <String>[];
    if (_kind != null) {
      rows.add('当前身份：${_kind == DiaryKind.g ? '乖乖' : '晶晶'}');
    }
    rows.add(_connected
        ? '已连接飞书日历'
        : _needsReauth
            ? '授权已失效，需要重新授权'
            : _hasCredentials
                ? '已填写应用凭据，还没授权'
                : '还没配置飞书应用');
    if (_lastSyncAt != null) {
      rows.add('上次同步：${_formatTime(_lastSyncAt!)}'
          '${_lastSummary == null ? '' : ' · $_lastSummary'}');
    }
    return Card(
      margin: EdgeInsets.zero,
      color: context.wallpaperFill(AppSurfaces.of(context).card),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('飞书日历（单向）', style: AppText.sectionTitle),
            const SizedBox(height: AppSpacing.sm),
            Text(
              '只把时间块写到飞书日历，不会把飞书上的改动读回来。'
              '自动同步产生的日程带固定标记，手改会被下次同步覆盖。'
              '授权会在同一身份的其它设备之间共用，一边授权过就不用再授权。',
              style: AppText.caption.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: AppSpacing.sm),
            for (final row in rows)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.xs),
                child: Text(row, style: AppText.body),
              ),
            if (_authError != null) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(
                _authError!,
                style: AppText.caption.copyWith(color: scheme.error),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildNoIdentity(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      color: context.wallpaperFill(AppSurfaces.of(context).card),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Text(
          '请先在「用户身份」里选择乖乖或晶晶，再配置飞书日历。',
          style: AppText.body.copyWith(color: scheme.onSurfaceVariant),
        ),
      ),
    );
  }

  Widget _buildCredentialsCard(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      color: context.wallpaperFill(AppSurfaces.of(context).card),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('飞书应用凭据', style: AppText.sectionTitle),
            const SizedBox(height: AppSpacing.sm),
            Text(
              '每个人用自己的飞书团队建一个自建应用，填自己的 App ID / Secret。',
              style: AppText.caption.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              key: const ValueKey('feishu-app-id'),
              controller: _appIdController,
              enabled: !_authorizing,
              decoration: const InputDecoration(
                labelText: 'App ID',
                hintText: 'cli_xxxxxxxx',
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              key: const ValueKey('feishu-app-secret'),
              controller: _appSecretController,
              enabled: !_authorizing,
              obscureText: _obscureSecret,
              decoration: InputDecoration(
                labelText: 'App Secret',
                suffixIcon: IconButton(
                  onPressed: () =>
                      setState(() => _obscureSecret = !_obscureSecret),
                  icon: Icon(
                    _obscureSecret
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Row(
              children: [
                FilledButton.icon(
                  key: const ValueKey('feishu-authorize'),
                  onPressed: _authorizing ? null : _saveAndAuthorize,
                  icon: _authorizing
                      ? SizedBox(
                          width: AppSizes.iconButton / 2,
                          height: AppSizes.iconButton / 2,
                          child:
                              const CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.link),
                  label: Text(_authorizing ? '等待浏览器授权…' : '保存并授权'),
                ),
              ],
            ),
            if (_authorizing) ...[
              const SizedBox(height: AppSpacing.sm),
              Row(
                children: [
                  SizedBox(
                    width: AppSizes.iconButton / 2,
                    height: AppSizes.iconButton / 2,
                    child: const CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      '在浏览器里点「同意」就会自动回到这里，不用做别的。',
                      style: AppText.caption.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  TextButton(
                    key: const ValueKey('feishu-cancel-authorize'),
                    onPressed: _cancelAuthorization,
                    child: const Text('取消'),
                  ),
                ],
              ),
            ],
            if (_authUri != null && !_authorizing) ...[
              const SizedBox(height: AppSpacing.sm),
              ExpansionTile(
                key: ValueKey('feishu-manual-${_authError != null}'),
                title: Text('没自动跳回来？手动完成', style: AppText.body),
                tilePadding: EdgeInsets.zero,
                initiallyExpanded: _authError != null,
                childrenPadding: const EdgeInsets.only(bottom: AppSpacing.sm),
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(AppSpacing.sm),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest,
                      borderRadius: AppRadius.controlAll,
                    ),
                    child: SelectableText(
                      _authUri!,
                      key: const ValueKey('feishu-auth-uri'),
                      maxLines: 4,
                      style: AppText.caption.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Wrap(
                    spacing: AppSpacing.sm,
                    runSpacing: AppSpacing.xs,
                    children: [
                      TextButton.icon(
                        key: const ValueKey('feishu-copy-auth-uri'),
                        onPressed: _copyAuthUri,
                        icon: const Icon(Icons.copy_rounded),
                        label: const Text('复制链接'),
                      ),
                      TextButton.icon(
                        key: const ValueKey('feishu-reopen-auth-uri'),
                        onPressed: _openAuthUriAgain,
                        icon: const Icon(Icons.open_in_new),
                        label: const Text('再打开一次'),
                      ),
                    ],
                  ),
                  TextField(
                    key: const ValueKey('feishu-callback-input'),
                    controller: _pasteController,
                    minLines: 1,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      hintText:
                          'http://127.0.0.1:17890/feishu/oauth/callback?code=...',
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Align(
                    alignment: Alignment.centerRight,
                    child: OutlinedButton(
                      key: const ValueKey('feishu-callback-submit'),
                      onPressed: _submitPastedCallback,
                      child: const Text('完成授权'),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSyncCard(BuildContext context, TimeProvider provider) {
    return ListenableBuilder(
      listenable: _sync,
      builder: (context, _) {
        final syncing = _sync.syncing;
        return Card(
          margin: EdgeInsets.zero,
          color: context.wallpaperFill(AppSurfaces.of(context).card),
          child: Column(
            children: [
              SwitchListTile(
                key: const ValueKey('feishu-auto-sync'),
                secondary: const Icon(Icons.bolt_outlined),
                title: const Text('自动同步当天日程'),
                subtitle: const Text('改完时间块约 3 秒后推到飞书'),
                value: _autoSync,
                onChanged: syncing
                    ? null
                    : (value) => _toggleAutoSync(provider, value),
              ),
              const Divider(height: AppSizes.hairline),
              ListTile(
                leading: const Icon(Icons.update),
                title: const Text('同步最近 7 天'),
                subtitle: const Text('按当前时间块重建这 7 天的飞书日程'),
                enabled: !syncing,
                onTap: () => _syncRecentDays(provider),
              ),
              ListTile(
                leading: const Icon(Icons.restore),
                title: const Text('同步全部有记录的日期'),
                subtitle: const Text('包含以前同步过、后来被清空的日期'),
                enabled: !syncing,
                onTap: () => _syncAllDays(provider),
              ),
              if (syncing)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg,
                    0,
                    AppSpacing.lg,
                    AppSpacing.md,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      LinearProgressIndicator(
                        value: _sync.total == 0
                            ? null
                            : _sync.completed / _sync.total,
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        '已完成 ${_sync.completed}/${_sync.total} 天'
                        '${_sync.currentDateKey == null ? '' : ' · 正在同步 ${_sync.currentDateKey}'}',
                        style: AppText.caption,
                      ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: _sync.cancel,
                          child: const Text('取消'),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildDisconnectTile(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      color: context.wallpaperFill(AppSurfaces.of(context).card),
      child: ListTile(
        key: const ValueKey('feishu-disconnect'),
        leading: Icon(Icons.link_off, color: scheme.error),
        title: Text('断开连接', style: AppText.body.copyWith(color: scheme.error)),
        subtitle: const Text('只清本机授权，不删飞书上已同步的日程'),
        onTap: _disconnect,
      ),
    );
  }

  Widget _buildSetupGuide(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final steps = [
      '打开飞书开发者后台 open.feishu.cn/app，创建「企业自建应用」。',
      '在「凭证与基础信息」复制 App ID 和 App Secret。',
      '「权限管理」开通两个权限：calendar:calendar（更新日历及日程信息）'
          '和 offline_access（持续访问已授权数据）。两个都要，缺一个会报 20027。',
      '「安全设置」开启「刷新 user_access_token」，重定向 URL 填下面这条。',
      '「版本管理与发布」创建版本并申请发布，管理员（自己）审核通过。',
      '回到这里填 App ID / App Secret，点「保存并授权」。',
    ];
    return Card(
      margin: EdgeInsets.zero,
      color: context.wallpaperFill(AppSurfaces.of(context).card),
      child: ExpansionTile(
        title: Text('怎么创建飞书应用', style: AppText.body),
        childrenPadding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          0,
          AppSpacing.lg,
          AppSpacing.lg,
        ),
        children: [
          for (var i = 0; i < steps.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${i + 1}. ', style: AppText.caption),
                  Expanded(
                    child: Text(
                      steps[i],
                      style: AppText.caption.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(AppSpacing.sm),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: AppRadius.controlAll,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '重定向 URL 填这一条：',
                  style: AppText.caption.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
                SelectableText(
                  FeishuCalendarConfig.redirectUri,
                  key: const ValueKey('feishu-redirect-uri'),
                  style: AppText.body,
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    key: const ValueKey('feishu-copy-redirect-uri'),
                    onPressed: _copyRedirectUri,
                    icon: const Icon(Icons.copy_rounded),
                    label: const Text('复制'),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: () => launchUrl(
                Uri.parse(FeishuCalendarConfig.openPlatformUrl),
                mode: LaunchMode.externalApplication,
              ),
              icon: const Icon(Icons.open_in_new),
              label: const Text('打开飞书开放平台'),
            ),
          ),
        ],
      ),
    );
  }

  static String _formatTime(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${time.year}-${two(time.month)}-${two(time.day)} '
        '${two(time.hour)}:${two(time.minute)}';
  }
}
