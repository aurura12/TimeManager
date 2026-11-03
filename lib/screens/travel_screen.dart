import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../utils/platform_features.dart';

import '../models/sync_center_state.dart';
import '../models/travel_record.dart';
import '../services/diary_local_store.dart';
import '../services/app_identity_service.dart';
import '../services/sync_center_service.dart';
import '../services/sync_operation_lock.dart';
import '../services/travel_gitee_service.dart';
import '../services/travel_local_store.dart';

import '../theme/app_semantic_colors.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';
import '../utils/app_snack_bar.dart';
import '../utils/keyboard_dismiss.dart';
import '../utils/local_day_range.dart';
import '../widgets/day_change_boundary.dart';
import '../widgets/desktop_shortcut_host.dart';
import '../widgets/motion_transitions.dart';
import '../widgets/travel_date_details.dart';
import '../widgets/travel_desktop_calendar.dart';
import '../widgets/travel_tables.dart';
import '../widgets/sync_status_button.dart';
import 'sync_center_screen.dart';

enum _TravelViewMode { table, calendar, stats }

enum _TravelRecordAction { edit, delete }

class TravelScreen extends StatefulWidget {
  const TravelScreen({super.key});

  @override
  State<TravelScreen> createState() => _TravelScreenState();
}

class _TravelScreenState extends State<TravelScreen> {
  DateTime _selectedDate = DateTime.now();
  DateTime _calendarMonth = DateTime.now();
  bool _multiMonthCalendar = true;

  /// 多月视图当前实际展示的月份数量，由 [TravelDesktopCalendar] 在 build 时回写。
  /// 只作缓存、不触发重建，供 [build] 之外的导航吸附使用。
  int _visibleMonthCount = TravelDesktopCalendar.maxMultiMonthCount;
  _TravelViewMode _viewMode = _TravelViewMode.table;
  TravelRecordsDocument _document = const TravelRecordsDocument(records: []);
  String? _token;
  bool _loading = true;
  bool _processing = false;
  int _touchedIndex = -1;

  /// 全局同步状态中心。允许为空：独立构建出行页（例如页面级测试）时没
  /// 有 Provider 树，此时只跳过状态上报。
  SyncStatusCoordinator? _statusCoordinator;

  /// 同步中心「拉取远端」结束的通知；页面据此重读本地存储。
  StreamSubscription<SyncModule>? _pullCompletedSubscription;

  @override
  void initState() {
    super.initState();
    _statusCoordinator = context.read<SyncStatusCoordinator?>();
    // 同步中心的拉取跑在它自己的服务实例上，只写本地存储：不订阅这个信号，
    // 页面会一直用旧副本渲染，改动后的推送又会被判成内容冲突而中止。
    _pullCompletedSubscription = context
        .read<SyncCenterController?>()
        ?.pullCompleted
        .where((module) => module == SyncModule.travel)
        .listen((_) => unawaited(_reloadDocumentFromLocal()));
    _selectedDate = _normalizedDate(DateTime.now());
    _calendarMonth = DateTime(_selectedDate.year, _selectedDate.month);
    _loadInitial();
  }

  @override
  void dispose() {
    _pullCompletedSubscription?.cancel();
    super.dispose();
  }

  /// 重读本地存储里的出行记录。
  ///
  /// 走同一把同步锁，避免和页面自己的推送 / 拉取交错。
  Future<void> _reloadDocumentFromLocal() async {
    final document = await SyncOperationLock.instance.run(
      SyncModule.travel,
      () async {
        final raw = await TravelLocalStore.loadDraft();
        if (raw == null || raw.trim().isEmpty) {
          return const TravelRecordsDocument(records: []);
        }
        try {
          return TravelRecordsDocument.fromMarkdown(raw);
        } catch (_) {
          // 坏格式不覆盖内存，保留当前可用数据（与 _loadInitial 一致）。
          return null;
        }
      },
    );
    if (!mounted || document == null) return;
    setState(() => _document = document);
  }

  DateTime _normalizedDate(DateTime date) {
    return DateTime(date.year, date.month, date.day);
  }

  Future<void> _loadInitial() async {
    _token = await DiaryLocalStore.loadToken();
    final local = await TravelLocalStore.loadDraft();
    if (local != null && local.trim().isNotEmpty) {
      try {
        _document = TravelRecordsDocument.fromMarkdown(local);
      } catch (_) {
        _document = const TravelRecordsDocument(records: []);
      }
    }
    if (!mounted) return;
    setState(() => _loading = false);
    await _pullFromGitHub();
  }

  String _selectedDateText() => DateFormat('yyyy-MM-dd').format(_selectedDate);

  TravelRecord? _recordForDate(DateTime date) {
    final key = DateFormat('yyyy-MM-dd').format(date);
    for (final record in _document.records) {
      if (record.dateKey == key) return record;
    }
    return null;
  }

  Set<String> get _recordDateKeys =>
      _document.records.map((e) => e.dateKey).toSet();

  int _nextRecordVersion(String dateKey) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final deletedAt = _document.deletedAtByDate[dateKey];
    if (deletedAt == null || now > deletedAt) return now;
    // 防止系统时钟回拨或同一毫秒内重新新增，确保复活版本严格晚于
    // tombstone，而不是在下一次同步时再次被判定为删除。
    return deletedAt + 1;
  }

  /// 本地有、远端没有的日期。
  Set<String> _localOnlyDateKeys(TravelRecordsDocument remote) =>
      _recordDateKeys
          .difference(remote.records.map((e) => e.dateKey).toSet())
          .difference(remote.deletedDateKeys);

  /// 远端有、本地没有的日期。
  Set<String> _remoteOnlyDateKeys(TravelRecordsDocument remote) =>
      remote.recordDateKeys
          .difference(_recordDateKeys)
          .difference(_document.deletedDateKeys);

  Future<bool> _confirmReplaceExistingRecord({
    required TravelRecord existing,
    required TravelRecord replacement,
  }) async {
    if (!mounted) return false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('目标日期已有记录'),
          content: Text(
            '${replacement.dateKey} 已有「${existing.location}」的出行记录，'
            '继续保存会覆盖原记录，是否继续？',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('覆盖并保存'),
            ),
          ],
        );
      },
    );
    return confirmed == true;
  }

  /// 落盘成功返回 true；失败时提示用户，避免「界面已改、重启回滚」。
  Future<bool> _saveDraft() async {
    final saved = await TravelLocalStore.saveDraft(_document.toMarkdown());
    if (!saved && mounted) {
      _showMessage('本地保存失败，请检查存储空间后重试');
    }
    return saved;
  }

  void _reportTravel(SyncOperationResult result, {String source = '出行页'}) {
    _statusCoordinator?.report(
      SyncModule.travel,
      result,
      scope: SyncStatusCoordinator.defaultScopeFor(SyncModule.travel),
      source: source,
    );
  }

  void _markTravelPending() {
    _statusCoordinator?.markPending(
      SyncModule.travel,
      uploadCount: 1,
      message: '有出行记录待上传',
      scope: SyncStatusCoordinator.defaultScopeFor(SyncModule.travel),
      source: '出行页',
    );
  }

  Future<DateTime?> _pickDate({
    required DateTime initialDate,
    DatePickerMode initialMode = DatePickerMode.day,
  }) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
      initialDatePickerMode: initialMode,
    );
    if (picked == null) return null;
    return _normalizedDate(picked);
  }

  Future<bool> _saveRecord({
    required DateTime date,
    required String location,
    required String event,
    DateTime? previousDate,
  }) async {
    if (location.trim().isEmpty) {
      _showMessage('地点不能为空');
      return false;
    }
    final normalizedDate = _normalizedDate(date);
    final record = TravelRecord(
      date: normalizedDate,
      location: location.trim(),
      event: event.trim(),
      updatedAt: _nextRecordVersion(
        DateFormat('yyyy-MM-dd').format(normalizedDate),
      ),
    );

    final previousDateKey = previousDate == null
        ? null
        : DateFormat('yyyy-MM-dd').format(_normalizedDate(previousDate));
    final existingTarget = _recordForDate(normalizedDate);
    if (existingTarget != null && existingTarget.dateKey != previousDateKey) {
      final confirmed = await _confirmReplaceExistingRecord(
        existing: existingTarget,
        replacement: record,
      );
      if (!confirmed) return false;
    }
    if (!mounted) return false;

    setState(() {
      _document = previousDateKey == null
          ? _document.upsert(record)
          : _document.replaceDate(
              previousDateKey: previousDateKey,
              record: record,
            );
      _selectedDate = normalizedDate;
      _calendarMonth = DateTime(normalizedDate.year, normalizedDate.month);
    });
    if (!await _saveDraft()) return false;
    _markTravelPending();
    return true;
  }

  /// 即时删除出行记录，提示条提供撤销入口。
  ///
  /// 保留「内存先删、落盘失败回滚」的结构：落盘失败时界面不能显示
  /// 已删除、重启后又出现，此时也不弹撤销提示条。
  Future<void> _deleteRecord(DateTime date) async {
    if (_processing) return;
    final normalizedDate = _normalizedDate(date);
    final record = _recordForDate(normalizedDate);
    if (record == null) return;

    // 删除先只改内存，落盘失败时回滚，避免界面显示已删除、重启后又出现。
    final previousDocument = _document;
    final previousSelectedDate = _selectedDate;
    final previousCalendarMonth = _calendarMonth;
    setState(() {
      _document = _document.deleteByDate(record.date);
      if (_selectedDateText() == record.dateKey) {
        if (_document.records.isNotEmpty) {
          _selectedDate = _document.records.first.date;
        } else {
          _selectedDate = _normalizedDate(DateTime.now());
        }
        _calendarMonth = DateTime(_selectedDate.year, _selectedDate.month);
      }
    });

    if (!await _saveDraft()) {
      if (mounted) {
        setState(() {
          _document = previousDocument;
          _selectedDate = previousSelectedDate;
          _calendarMonth = previousCalendarMonth;
        });
      }
      return;
    }
    _markTravelPending();
    if (!mounted) return;
    // 本地已经落盘，撤销入口立刻给出来；远端推送放到后台，慢网络下不能
    // 拖着提示条一起等（等太久用户已经离开这一屏，撤销就白给了）。
    showAppUndoSnackBar(
      context,
      message: '已删除 ${record.dateKey} 的出行记录',
      identityToken: AppIdentityService.identityStamp,
      onUndo: () async {
        if (!mounted) return;
        // 该日期已被用户写入新记录时撤销失效。
        if (_recordForDate(record.date) != null) {
          throw StateError('该日期已有新记录，撤销已失效');
        }
        // upsert 自带墓碑仲裁：updatedAt <= 墓碑时自动盖成 deletedAt+1，
        // 恢复后的记录在与远端文档合并时能胜过旧墓碑。
        setState(() {
          _document = _document.upsert(record);
        });
        if (!await _saveDraft()) {
          throw StateError('撤销保存失败');
        }
        _markTravelPending();
        await _pushToGitHub();
      },
    );
    unawaited(_pushToGitHub());
  }

  Future<void> _showAddRecordDialog({DateTime? initialDate}) async {
    var tempDate = _normalizedDate(initialDate ?? DateTime.now());
    final locationController = TextEditingController();
    final eventController = TextEditingController();
    String? locationError;
    ModalRoute<bool>? dialogRoute;

    final shouldSave = await showDialog<bool>(
      context: context,
      // 输入类弹窗不响应遮罩点击：键盘弹起后弹窗上移、上方遮罩变大，
      // 手滑点到就会连输入一起丢掉。
      barrierDismissible: false,
      builder: (context) {
        dialogRoute = ModalRoute.of<bool>(context);
        return StatefulBuilder(
          builder: (context, setDialogState) {
            void submit() {
              if (locationController.text.trim().isEmpty) {
                setDialogState(() => locationError = '地点不能为空');
                return;
              }
              Navigator.of(context).pop(true);
            }

            return DesktopShortcutHost(
              onSaveForm: submit,
              child: AlertDialog(
                title: const Text('新增出行记录'),
                content: SingleChildScrollView(
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      OutlinedButton.icon(
                        onPressed: () async {
                          final picked = await _pickDate(initialDate: tempDate);
                          if (picked == null) return;
                          setDialogState(() => tempDate = picked);
                        },
                        icon:
                            const Icon(Icons.calendar_today_outlined, size: 16),
                        label: Text(DateFormat('yyyy-MM-dd').format(tempDate)),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: locationController,
                        autofocus: isDesktopPlatform,
                        onTapOutside: dismissKeyboardOnTapOutside,
                        onChanged: (_) {
                          if (locationError != null) {
                            setDialogState(() => locationError = null);
                          }
                        },
                        decoration: InputDecoration(
                          labelText: '地点',
                          border: const OutlineInputBorder(),
                          isDense: true,
                          errorText: locationError,
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: eventController,
                        onTapOutside: dismissKeyboardOnTapOutside,
                        decoration: const InputDecoration(
                          labelText: '事件',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: const Text('取消'),
                  ),
                  FilledButton(
                    onPressed: submit,
                    child: const Text('保存'),
                  ),
                ],
              ),
            );
          },
        );
      },
    );

    if (shouldSave == true) {
      final saved = await _saveRecord(
        date: tempDate,
        location: locationController.text,
        event: eventController.text,
      );
      if (saved) await _pushToGitHub();
    }
    // pop 的结果早于退出动画结束，控件仍挂载时不能销毁它们的 controller。
    await dialogRoute?.completed;
    locationController.dispose();
    eventController.dispose();
  }

  Future<void> _showEditRecordDialog(DateTime date) async {
    final normalizedDate = _normalizedDate(date);
    final existing = _recordForDate(normalizedDate);
    var tempDate = normalizedDate;
    final locationController =
        TextEditingController(text: existing?.location ?? '');
    final eventController = TextEditingController(text: existing?.event ?? '');
    String? locationError;
    ModalRoute<bool>? dialogRoute;

    final shouldSave = await showDialog<bool>(
      context: context,
      // 输入类弹窗不响应遮罩点击：键盘弹起后弹窗上移、上方遮罩变大，
      // 手滑点到就会连输入一起丢掉。
      barrierDismissible: false,
      builder: (context) {
        dialogRoute = ModalRoute.of<bool>(context);
        return StatefulBuilder(
          builder: (context, setDialogState) {
            void submit() {
              if (locationController.text.trim().isEmpty) {
                setDialogState(() => locationError = '地点不能为空');
                return;
              }
              Navigator.of(context).pop(true);
            }

            return DesktopShortcutHost(
              onSaveForm: submit,
              child: AlertDialog(
                title: const Text('编辑出行记录'),
                content: SingleChildScrollView(
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      OutlinedButton.icon(
                        onPressed: () async {
                          final picked = await _pickDate(initialDate: tempDate);
                          if (picked == null) return;
                          setDialogState(() => tempDate = picked);
                        },
                        icon:
                            const Icon(Icons.calendar_today_outlined, size: 16),
                        label: Text(DateFormat('yyyy-MM-dd').format(tempDate)),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: locationController,
                        autofocus: isDesktopPlatform,
                        onTapOutside: dismissKeyboardOnTapOutside,
                        onChanged: (_) {
                          if (locationError != null) {
                            setDialogState(() => locationError = null);
                          }
                        },
                        decoration: InputDecoration(
                          labelText: '地点',
                          border: const OutlineInputBorder(),
                          isDense: true,
                          errorText: locationError,
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: eventController,
                        onTapOutside: dismissKeyboardOnTapOutside,
                        decoration: const InputDecoration(
                          labelText: '事件',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: const Text('取消'),
                  ),
                  FilledButton(
                    onPressed: submit,
                    child: const Text('保存'),
                  ),
                ],
              ),
            );
          },
        );
      },
    );

    if (shouldSave == true) {
      final saved = await _saveRecord(
        date: tempDate,
        location: locationController.text,
        event: eventController.text,
        previousDate: normalizedDate,
      );
      if (saved) await _pushToGitHub();
    }
    await dialogRoute?.completed;
    locationController.dispose();
    eventController.dispose();
  }

  Future<bool> _ensureToken() async {
    final token = (_token ?? '').trim();
    if (token.isNotEmpty) return true;
    _showMessage('未配置当前平台同步 Token，请先配置日记模块 token');
    return false;
  }

  /// 自动拉取远端出行记录。
  ///
  /// 页面不再提供手动拉取：遇到本地独有日期 / 内容冲突时保持本地不变，
  /// 由同步中心的「拉取远端」（带确认）处理。
  Future<void> _pullFromGitHub() {
    return SyncOperationLock.instance.run(
      SyncModule.travel,
      _pullFromGitHubInternal,
    );
  }

  Future<void> _pullFromGitHubInternal() async {
    final token = (_token ?? '').trim();
    if (token.isEmpty) {
      _reportTravel(
        const SyncOperationResult.offline('出行远端未连接，本地记录会保留'),
      );
      return;
    }
    if (!mounted) return;
    setState(() => _processing = true);
    final result = await TravelGiteeService.pullFile(
      token: _token!,
      path: TravelRecordsDocument.filePath,
    );
    if (!mounted) return;
    if (result.success) {
      try {
        final doc = TravelRecordsDocument.fromMarkdown(result.content!);
        // 远端缺了本地已有的日期、或同日期内容不同：保持本地不变，
        // 交给同步中心的「拉取远端」让用户确认后再覆盖。
        final localOnly = _localOnlyDateKeys(doc);
        final conflicting = _document.conflictingDateKeys(doc);
        if (localOnly.isNotEmpty || conflicting.isNotEmpty) {
          setState(() => _processing = false);
          return;
        }
        final merged = _document.mergeRemotePreservingLocalDeletions(doc);
        final previous = _document;
        _document = merged;
        if (!await _saveDraft()) {
          _document = previous;
          _reportTravel(const SyncOperationResult.failed(
            '出行拉取失败：本地保存失败，请检查存储空间后重试',
            pendingDownloadCount: 1,
          ));
          if (mounted) setState(() => _processing = false);
          return;
        }
        final stillPending = merged.toSyncPayload() != doc.toSyncPayload();
        _reportTravel(
          stillPending
              ? const SyncOperationResult.pending(
                  '已拉取远端记录，但本地仍有删除/新增待上传',
                  pendingUploadCount: 1,
                )
              : const SyncOperationResult.success(message: '出行记录已拉取'),
        );
      } catch (e) {
        _reportTravel(SyncOperationResult.failed('解析远端出行记录失败：$e'));
      }
      if (!mounted) return;
      setState(() => _processing = false);
      return;
    }
    setState(() => _processing = false);
    if (result.notFound) {
      _reportTravel(
        _document.records.isEmpty && _document.deletedDateKeys.isEmpty
            ? const SyncOperationResult.success(message: '远端暂无出行记录文件')
            : const SyncOperationResult.pending(
                '远端暂无出行记录文件，本地记录待上传',
                pendingUploadCount: 1,
              ),
      );
      return;
    }
    _reportTravel(
      SyncOperationResult.failed('出行同步失败：${result.error ?? '拉取失败'}'),
    );
  }

  Future<void> _pushToGitHub() {
    return SyncOperationLock.instance.run(
      SyncModule.travel,
      _pushToGitHubInternal,
    );
  }

  Future<void> _pushToGitHubInternal() async {
    final ok = await _ensureToken();
    if (!ok) {
      _reportTravel(
        const SyncOperationResult.offline(
          '出行远端未连接，本地记录会保留',
          pendingUploadCount: 1,
        ),
      );
      return;
    }
    if (!mounted) return;
    setState(() => _processing = true);
    if (!await _saveDraft()) {
      _reportTravel(const SyncOperationResult.failed(
        '出行同步未开始：本地保存失败，请检查存储空间后重试',
        pendingUploadCount: 1,
      ));
      if (mounted) setState(() => _processing = false);
      return;
    }
    if (!mounted) return;

    // 先读远端：读不到就中止，绝不用本地内容覆盖一个未知状态的远端。
    final pull = await TravelGiteeService.pullFile(
      token: _token!,
      path: TravelRecordsDocument.filePath,
    );
    if (!mounted) return;
    TravelRecordsDocument? remoteDocument;
    if (!pull.success && !pull.notFound) {
      setState(() => _processing = false);
      _showMessage('远端读取失败，已中止同步：${pull.error ?? '未知错误'}');
      _reportTravel(
        SyncOperationResult.failed(
          '出行同步失败：${pull.error ?? '远端记录不可读'}',
          pendingUploadCount: 1,
        ),
      );
      return;
    }
    if (pull.success && pull.content != null) {
      try {
        final remote = TravelRecordsDocument.fromMarkdown(pull.content!);
        remoteDocument = remote;
        final remoteOnly = _remoteOnlyDateKeys(remote);
        if (remoteOnly.isNotEmpty) {
          setState(() => _processing = false);
          final preview = remoteOnly.take(5).join('、');
          _showMessage(
            '远端有本地没有的记录（$preview），已中止同步，请先执行「拉取」',
          );
          _reportTravel(
            SyncOperationResult.conflict(
              '远端有本地没有的出行记录，请先在出行页执行「拉取」',
              conflictCount: remoteOnly.length,
              details: remoteOnly.take(10).toList(growable: false),
            ),
          );
          return;
        }
        final conflicting = _document.conflictingDateKeys(remote);
        if (conflicting.isNotEmpty) {
          final tombstoneConflicts =
              _document.tombstoneConflictDateKeys(remote);
          setState(() => _processing = false);
          final preview = conflicting.take(5).join('、');
          final suffix = conflicting.length > 5 ? ' 等' : '';
          _showMessage(tombstoneConflicts.isNotEmpty
              ? '本地重新记录与远端删除标记存在版本冲突（$preview$suffix），'
                  '已中止同步，请先执行「拉取」并确认处理'
              : '本地与远端同日记录内容不同（$preview$suffix），'
                  '已中止同步，请先执行「拉取」并确认覆盖');
          _reportTravel(
            SyncOperationResult.conflict(
              '本地与远端出行记录存在内容冲突，请先在出行页确认',
              conflictCount: conflicting.length,
              details: conflicting.take(10).toList(growable: false),
            ),
          );
          return;
        }
      } catch (_) {
        setState(() => _processing = false);
        _showMessage('远端记录格式无法解析，已中止同步以保护远端数据');
        _reportTravel(
          const SyncOperationResult.failed(
            '出行同步失败：远端记录格式无法解析',
            pendingUploadCount: 1,
          ),
        );
        return;
      }
    }

    final remoteSha = pull.success ? pull.sha : null;
    final remoteWasNotFound = pull.notFound;
    final outgoing = remoteDocument == null
        ? _document
        : _document.preparePush(remoteDocument);
    final content = outgoing.toMarkdown();
    if (remoteDocument != null &&
        outgoing.toSyncPayload() == remoteDocument.toSyncPayload()) {
      final previous = _document;
      _document = outgoing;
      final saved = await _saveDraft();
      if (!saved) _document = previous;
      if (mounted) setState(() => _processing = false);
      if (!saved) {
        _reportTravel(const SyncOperationResult.failed(
          '出行记录已与远端一致，但本地保存失败，请检查存储空间后重试',
          pendingDownloadCount: 1,
        ));
        return;
      }
      _showMessage('已确认与远端一致，无需重复提交');
      _reportTravel(
        const SyncOperationResult.success(message: '出行记录已确认同步'),
      );
      return;
    }
    final latest = outgoing.records.isEmpty ? null : outgoing.records.first;
    final result = await TravelGiteeService.pushFile(
      token: _token!,
      path: TravelRecordsDocument.filePath,
      content: content,
      commitMessage: latest == null
          ? 'travel: update'
          : 'travel: update ${latest.dateKey} ${latest.location}',
      expectedSha: remoteSha,
      expectNotFound: remoteWasNotFound,
    );
    if (result.success) {
      final previous = _document;
      _document = outgoing;
      final saved = await _saveDraft();
      if (!saved) _document = previous;
      if (mounted) setState(() => _processing = false);
      if (!saved) {
        _reportTravel(const SyncOperationResult.failed(
          '远端已同步，但本地保存失败，请检查存储空间后重试',
          pendingDownloadCount: 1,
        ));
        return;
      }
      _showMessage(result.created ? '同步成功（已新建远端文件）' : '同步成功');
      _reportTravel(
        SyncOperationResult.success(
          message: result.created ? '出行记录已同步（新建远端文件）' : '出行记录已同步',
        ),
      );
      return;
    }
    if (mounted) setState(() => _processing = false);
    _showMessage(result.error ?? '同步失败');
    _reportTravel(
      SyncOperationResult.failed(
        '出行同步失败：${result.error ?? '远端写入失败'}',
        pendingUploadCount: 1,
      ),
    );
  }

  void _showMessage(String text) {
    if (!mounted) return;
    showAppSnackBar(context, text);
  }

  void _handleRecordAction(_TravelRecordAction action, DateTime date) {
    switch (action) {
      case _TravelRecordAction.edit:
        unawaited(_showEditRecordDialog(date));
      case _TravelRecordAction.delete:
        unawaited(_deleteRecord(date));
    }
  }

  Widget _buildViewSwitch() {
    return SegmentedButton<_TravelViewMode>(
      segments: const [
        ButtonSegment(
          value: _TravelViewMode.table,
          label: Text('表格'),
          icon: Icon(Icons.table_rows_outlined),
        ),
        ButtonSegment(
          value: _TravelViewMode.calendar,
          label: Text('日历'),
          icon: Icon(Icons.calendar_month_outlined),
        ),
        ButtonSegment(
          value: _TravelViewMode.stats,
          label: Text('统计'),
          icon: Icon(Icons.insights_outlined),
        ),
      ],
      selected: {_viewMode},
      onSelectionChanged: (selection) {
        if (selection.isEmpty) return;
        setState(() {
          _viewMode = selection.first;
          _touchedIndex = -1;
        });
      },
    );
  }

  Widget _buildTableView() {
    final colorScheme = Theme.of(context).colorScheme;
    final rows = _document.records;
    if (rows.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.luggage_outlined,
              size: 42,
              color: colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            const Text('还没有出行记录'),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _processing ? null : () => _showAddRecordDialog(),
              icon: const Icon(Icons.add),
              label: const Text('新增记录'),
            ),
          ],
        ),
      );
    }
    return TravelRecordTable(
      records: rows,
      selectedDateKey: _selectedDateText(),
      onSelectDate: _selectTravelDate,
      actionsBuilder: _buildRecordActions,
    );
  }

  void _selectTravelDate(DateTime date) {
    setState(() {
      _selectedDate = _normalizedDate(date);
      _calendarMonth = DateTime(date.year, date.month);
    });
  }

  void _selectCalendarDate(DateTime date) {
    final normalizedDate = _normalizedDate(date);
    setState(() {
      _selectedDate = normalizedDate;
      if (!_multiMonthCalendar &&
          (normalizedDate.year != _calendarMonth.year ||
              normalizedDate.month != _calendarMonth.month)) {
        _calendarMonth = DateTime(normalizedDate.year, normalizedDate.month);
      }
    });
  }

  Widget _buildRecordActions(TravelRecord record) {
    return PopupMenuButton<_TravelRecordAction>(
      tooltip: '记录操作',
      padding: EdgeInsets.zero,
      style: IconButton.styleFrom(
        minimumSize: const Size(AppSizes.minTapTarget, AppSizes.minTapTarget),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      onSelected: (action) => _handleRecordAction(action, record.date),
      itemBuilder: (context) => const [
        PopupMenuItem(
          value: _TravelRecordAction.edit,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.edit_outlined),
              SizedBox(width: AppSpacing.md),
              Text('编辑'),
            ],
          ),
        ),
        PopupMenuItem(
          value: _TravelRecordAction.delete,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.delete_outline),
              SizedBox(width: AppSpacing.md),
              Text('删除'),
            ],
          ),
        ),
      ],
    );
  }

  void _changeCalendarMonth(int delta) {
    final nextMonth =
        DateTime(_calendarMonth.year, _calendarMonth.month + delta);
    final monthCount = _multiMonthCalendar ? _visibleMonthCount : 1;
    final selectedMonthOffset = (_selectedDate.year - nextMonth.year) * 12 +
        _selectedDate.month -
        nextMonth.month;
    setState(() {
      _calendarMonth = nextMonth;
      if (selectedMonthOffset < 0 || selectedMonthOffset >= monthCount) {
        final lastDay = DateTime(nextMonth.year, nextMonth.month + 1, 0).day;
        _selectedDate = DateTime(
          nextMonth.year,
          nextMonth.month,
          _selectedDate.day > lastDay ? lastDay : _selectedDate.day,
        );
      }
    });
  }

  void _setMultiMonthCalendar(bool multiMonth) {
    if (_multiMonthCalendar == multiMonth) return;
    setState(() {
      _multiMonthCalendar = multiMonth;
      if (!multiMonth) {
        _calendarMonth = DateTime(_selectedDate.year, _selectedDate.month);
      }
    });
  }

  Future<void> _pickCalendarMonth() async {
    final picked = await _showMonthPickerDialog(
      initialMonth: DateTime(_calendarMonth.year, _calendarMonth.month, 1),
    );
    if (picked == null) return;
    setState(() {
      _calendarMonth = DateTime(picked.year, picked.month);
      final maxDay = DateTime(picked.year, picked.month + 1, 0).day;
      final nextDay = _selectedDate.day > maxDay ? maxDay : _selectedDate.day;
      _selectedDate = DateTime(picked.year, picked.month, nextDay);
    });
  }

  Future<DateTime?> _showMonthPickerDialog({
    required DateTime initialMonth,
  }) async {
    var selectedYear = initialMonth.year;
    var selectedMonth = initialMonth.month;
    final years = List<int>.generate(81, (i) => 2020 + i);

    return showDialog<DateTime>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('选择年月'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButton<int>(
                    value: selectedYear,
                    isExpanded: true,
                    items: years
                        .map(
                          (year) => DropdownMenuItem<int>(
                            value: year,
                            child: Text('$year 年'),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value == null) return;
                      setDialogState(() => selectedYear = value);
                    },
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: List.generate(12, (index) {
                      final month = index + 1;
                      return ChoiceChip(
                        label: Text('$month月'),
                        selected: month == selectedMonth,
                        onSelected: (_) {
                          setDialogState(() => selectedMonth = month);
                        },
                      );
                    }),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () {
                    Navigator.of(
                      context,
                    ).pop(DateTime(selectedYear, selectedMonth, 1));
                  },
                  child: const Text('确定'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildCalendarContent() {
    if (isDesktopPlatform) {
      return TravelDesktopCalendar(
        month: _calendarMonth,
        selectedDate: _selectedDate,
        records: _document.records,
        multiMonth: _multiMonthCalendar,
        selectedDateDetails:
            _buildSelectedDateCard(_recordForDate(_selectedDate)),
        onSelectDate: _selectCalendarDate,
        onChangeMonth: _changeCalendarMonth,
        onToggleMultiMonth: _setMultiMonthCalendar,
        onVisibleMonthCount: (count) => _visibleMonthCount = count,
        onPickMonth: () => unawaited(_pickCalendarMonth()),
        onToday: () => _selectTravelDate(DateTime.now()),
      );
    }
    return _buildCalendarView();
  }

  Widget _buildCalendarView() {
    final colorScheme = Theme.of(context).colorScheme;
    final selectedRecord = _recordForDate(_selectedDate);
    final year = _calendarMonth.year;
    final month = _calendarMonth.month;
    final firstDayOfMonth = DateTime(year, month, 1);
    final daysInMonth = DateTime(year, month + 1, 0).day;
    final startWeekday = firstDayOfMonth.weekday;
    final today = DateTime.now();
    final todayKey = DateFormat('yyyy-MM-dd').format(today);

    return ListView(
      padding: EdgeInsets.zero,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            IconButton(
              tooltip: '上个月',
              onPressed: () => _changeCalendarMonth(-1),
              icon: const Icon(Icons.chevron_left),
            ),
            InkWell(
              onTap: _pickCalendarMonth,
              borderRadius: AppRadius.badgeAll,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  children: [
                    Text(
                      '$year年$month月',
                      style: AppText.sectionTitle,
                    ),
                    const SizedBox(width: 4),
                    const Icon(Icons.unfold_more, size: 16),
                  ],
                ),
              ),
            ),
            IconButton(
              tooltip: '下个月',
              onPressed: () => _changeCalendarMonth(1),
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          children: ['一', '二', '三', '四', '五', '六', '日']
              .map(
                (d) => Expanded(
                  child: Center(
                    child: Text(
                      d,
                      style: AppText.caption.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              )
              .toList(),
        ),
        const SizedBox(height: 4),
        GridView.count(
          crossAxisCount: 7,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          childAspectRatio: 1.0,
          children: List.generate(42, (index) {
            final dayOffset = index - (startWeekday - 1);
            if (dayOffset < 0 || dayOffset >= daysInMonth) {
              return const SizedBox.shrink();
            }
            final day = dayOffset + 1;
            final date = DateTime(year, month, day);
            final dateKey = DateFormat('yyyy-MM-dd').format(date);
            final isSelected = dateKey == _selectedDateText();
            final isToday = dateKey == todayKey;
            final hasEvent = _recordDateKeys.contains(dateKey);

            return GestureDetector(
              onTap: () {
                setState(() {
                  _selectedDate = date;
                });
              },
              child: Container(
                margin: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: isSelected
                      ? context.wallpaperFill(colorScheme.primaryContainer)
                      : hasEvent
                          ? context
                              .wallpaperFill(colorScheme.surfaceContainerHigh)
                          : null,
                  border: isToday
                      ? Border.all(color: colorScheme.primary, width: 1.5)
                      : null,
                  borderRadius: AppRadius.badgeAll,
                ),
                child: Center(
                  child: Text(
                    '$day',
                    style: AppText.body.copyWith(
                      fontWeight:
                          isSelected ? FontWeight.bold : FontWeight.normal,
                      color: isSelected ? colorScheme.onPrimaryContainer : null,
                    ),
                  ),
                ),
              ),
            );
          }),
        ),
        const SizedBox(height: 12),
        _buildSelectedDateCard(selectedRecord),
      ],
    );
  }

  Widget _buildSelectedDateCard(TravelRecord? record) => ValueChangeTransition(
        value: _selectedDate,
        child: TravelDateDetails(
          date: _selectedDate,
          record: record,
          enabled: !_processing,
          onAdd: () =>
              unawaited(_showAddRecordDialog(initialDate: _selectedDate)),
          onEdit: () => unawaited(_showEditRecordDialog(_selectedDate)),
          onDelete: () => unawaited(_deleteRecord(_selectedDate)),
        ),
      );

  Widget _buildStatsView() {
    final colorScheme = Theme.of(context).colorScheme;
    final records = _document.records;

    if (records.isEmpty) {
      return const Center(child: Text('暂无出行记录，无法统计'));
    }

    // 按地点统计（空格分隔的多个地点分别计数）
    final locationCounts = <String, int>{};
    for (final r in records) {
      for (final loc in r.location.split(RegExp(r'\s+'))) {
        final trimmed = loc.trim();
        if (trimmed.isNotEmpty) {
          locationCounts[trimmed] = (locationCounts[trimmed] ?? 0) + 1;
        }
      }
    }
    final sortedLocations = locationCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    // 按月统计
    final monthCounts = <String, int>{};
    final monthLocations = <String, Set<String>>{};
    for (final r in records) {
      final key = DateFormat('yyyy-MM').format(r.date);
      monthCounts[key] = (monthCounts[key] ?? 0) + 1;
      for (final loc in r.location.split(RegExp(r'\s+'))) {
        final trimmed = loc.trim();
        if (trimmed.isNotEmpty) {
          monthLocations.putIfAbsent(key, () => {}).add(trimmed);
        }
      }
    }
    final sortedMonths = monthCounts.entries.toList()
      ..sort((a, b) => b.key.compareTo(a.key));

    // 饼图数据：Top 7 + 其他
    final topLocations = sortedLocations.take(7).toList();
    final otherCount = sortedLocations.length > 7
        ? sortedLocations.skip(7).fold(0, (sum, e) => sum + e.value)
        : 0;
    final pieData = [...topLocations];
    if (otherCount > 0) {
      pieData.add(MapEntry('其他', otherCount));
    }
    final total = records.length;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 汇总信息
          Row(
            children: [
              _buildStatCard(
                colorScheme: colorScheme,
                value: '$total',
                label: '出行次数',
                accentColor: colorScheme.primary,
              ),
              const SizedBox(width: 12),
              _buildStatCard(
                colorScheme: colorScheme,
                value: '${locationCounts.length}',
                label: '到访地点',
                accentColor: AppSemanticColors.info,
              ),
            ],
          ),
          const SizedBox(height: 20),

          // 地点分布饼图
          Text(
            '地点分布',
            style: AppText.body.copyWith(
              fontWeight: FontWeight.w600,
              color: colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerLowest,
              borderRadius: AppRadius.cardAll,
            ),
            child: Column(
              children: [
                SizedBox(
                  height: 220,
                  child: PieChart(
                    PieChartData(
                      pieTouchData: PieTouchData(
                        touchCallback: (FlTouchEvent event, pieTouchResponse) {
                          setState(() {
                            if (!event.isInterestedForInteractions ||
                                pieTouchResponse == null ||
                                pieTouchResponse.touchedSection == null) {
                              if (event is FlTapUpEvent) {
                                _touchedIndex = -1;
                              }
                              return;
                            }
                            _touchedIndex = pieTouchResponse
                                .touchedSection!.touchedSectionIndex;
                          });
                        },
                      ),
                      sectionsSpace: 2,
                      centerSpaceRadius: 36,
                      sections: List.generate(pieData.length, (i) {
                        final entry = pieData[i];
                        final color = AppSemanticColors.chartAt(i);
                        final percentage = entry.value / total * 100;
                        final isTouched = i == _touchedIndex;
                        return PieChartSectionData(
                          color: color,
                          value: entry.value.toDouble(),
                          title: isTouched
                              ? '${entry.key}\n${percentage.toStringAsFixed(1)}%'
                              : (percentage < 5
                                  ? ''
                                  : '${percentage.toStringAsFixed(1)}%'),
                          radius: isTouched ? 56.0 : 48.0,
                          titlePositionPercentageOffset: isTouched ? 1.5 : 0.5,
                          titleStyle:
                              (isTouched ? AppText.caption : AppText.badge)
                                  .copyWith(
                            fontWeight: FontWeight.bold,
                            color: isTouched
                                ? colorScheme.onSurface
                                : AppSemanticColors.onColor(color),
                          ),
                        );
                      }),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 14,
                  runSpacing: 6,
                  alignment: WrapAlignment.center,
                  children: List.generate(pieData.length, (i) {
                    final entry = pieData[i];
                    final color = AppSemanticColors.chartAt(i);
                    return Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: color,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          entry.key,
                          style: AppText.caption.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    );
                  }),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          // 月度统计表格
          Text(
            '月度统计',
            style: AppText.body.copyWith(
              fontWeight: FontWeight.w600,
              color: colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 8),
          TravelMonthlyTable(
            monthCounts: sortedMonths,
            locationsByMonth: monthLocations,
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _buildStatCard({
    required ColorScheme colorScheme,
    required String value,
    required String label,
    required Color accentColor,
  }) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerLowest,
          borderRadius: AppRadius.cardAll,
        ),
        child: Column(
          children: [
            Text(
              value,
              style: AppText.display.copyWith(
                fontWeight: FontWeight.bold,
                color: accentColor,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: AppText.caption.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => DayChangeBoundary(
        onDayChanged: _handleDayChanged,
        canHandleDayChange: () => !_loading && !_processing,
        builder: (_) => DesktopShortcutHost(
          autofocus: true,
          onNewItem: () => unawaited(_showAddRecordDialog()),
          isAvailable: (_) => !_loading && !_processing,
          child: _buildPage(context),
        ),
      );

  /// 跨过午夜且仍停在“今天”时，把选中日期和日历月份推进到新的一天。
  void _handleDayChanged(DateTime previousDay, DateTime today) {
    if (!mounted || _loading || _processing) return;
    if (!isSameLocalDay(_selectedDate, previousDay)) return;
    setState(() {
      _selectedDate = today;
      _calendarMonth = DateTime(today.year, today.month);
    });
  }

  void _openSyncCenter() {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) =>
            const SyncCenterScreen(initialModule: SyncModule.travel),
      ),
    );
  }

  Widget _buildPage(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('出行')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('出行'),
        actions: [
          SyncStatusButton(
            modules: const [SyncModule.travel],
            onPressed: _openSyncCenter,
          ),
          IconButton(
            tooltip: desktopShortcutTooltip(
                context, '新增记录', DesktopShortcutActionType.newItem),
            onPressed: _processing ? null : () => _showAddRecordDialog(),
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      body: Padding(
        padding: AppSpacing.cardComfortable,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildViewSwitch(),
            const SizedBox(height: AppSpacing.md),
            Expanded(
              child: ValueChangeTransition(
                value: _viewMode,
                child: _viewMode == _TravelViewMode.table
                    ? _buildTableView()
                    : _viewMode == _TravelViewMode.calendar
                        ? _buildCalendarContent()
                        : _buildStatsView(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
