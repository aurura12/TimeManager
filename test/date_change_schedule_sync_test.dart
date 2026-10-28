import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/models/diary_kind.dart';
import 'package:time_manager/providers/time_provider.dart';
import 'package:time_manager/services/app_identity_service.dart';
import 'package:time_manager/services/schedule_gitee_service.dart';
import 'package:time_manager/services/schedule_sync_dependencies.dart';

class _RemoteState {
  final Map<String, String> remoteContents = {};
  final List<String> pullRequests = [];
}

ScheduleSyncDependencies _fakeDependencies(_RemoteState state) {
  return ScheduleSyncDependencies(
    loadToken: () async => 'fake-token',
    listPaths: ({required token, required userCode}) async {
      return ScheduleGiteeListWithShaResult.success(const {});
    },
    pullDay: ({required token, required dateKey, required userCode}) async {
      state.pullRequests.add('$userCode/$dateKey');
      final content = state.remoteContents['$userCode/$dateKey'];
      if (content == null) return ScheduleGiteePullResult.notFound();
      return ScheduleGiteePullResult.success(
        content,
        'sha-$userCode-$dateKey',
      );
    },
    pushDay: ({
      required token,
      required dateKey,
      required userCode,
      required content,
      required commitMessage,
      String? expectedSha,
      bool expectNotFound = false,
    }) async {
      return ScheduleGiteePushResult.success(created: false);
    },
    pullGoogleDay: (date) async => const [],
    pushGoogleDay: (slots, date) async => true,
  );
}

Future<TimeProvider> _createProvider(
  _RemoteState state, {
  required bool mobile,
}) async {
  SharedPreferences.setMockInitialValues({
    AppIdentityService.modeKey: 'manual',
    AppIdentityService.legacyScheduleUserKey: DiaryKind.g.code,
  });
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
    const MethodChannel('home_widget'),
    (call) async => null,
  );
  messenger.setMockMethodCallHandler(
    const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
    (call) async => null,
  );

  final provider = TimeProvider(
    identityModePlatformOverride: mobile,
    googleCalendarSyncPlatformOverride: false,
    scheduleSyncDependencies: _fakeDependencies(state),
  );
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!provider.isInitialLoadFinished && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  await Future<void>.delayed(const Duration(milliseconds: 100));
  return provider;
}

Future<void> _waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(AppIdentityService.resetForTesting);
  tearDown(AppIdentityService.resetForTesting);

  test('Android date change pulls only the selected date from Gitee', () async {
    final state = _RemoteState();
    final provider = await _createProvider(state, mobile: true);
    addTearDown(provider.dispose);
    final progressBeforeDateChange = provider.scheduleSyncProgress;

    // Ignore any startup request. This test is about the request caused by
    // changing the selected date.
    state.pullRequests.clear();
    state.remoteContents['g/2026-09-06'] =
        '{"updated_at":2000,"slots":[{"i":60,"l":"Windows日程","c":1,"ts":2000}]}';

    provider.goToDate(DateTime(2026, 9, 6));
    expect(
      identical(provider.scheduleSyncProgress, progressBeforeDateChange),
      isTrue,
      reason: '日期切换的后台拉取不应显示底部进度条',
    );
    await _waitUntil(
      () => provider.getSlotsForDate('2026-09-06')?[60].label == 'Windows日程',
    );

    expect(state.pullRequests, ['g/2026-09-06']);
    expect(
      provider.getSlotsForDate('2026-09-06')?[60].label,
      'Windows日程',
    );
  });

  test('Windows date change pulls the three visible dates from Gitee',
      () async {
    final state = _RemoteState();
    final provider = await _createProvider(state, mobile: false);
    addTearDown(provider.dispose);
    await provider.setScheduleUser(DiaryKind.g);

    state.pullRequests.clear();
    state.remoteContents['g/2026-09-06'] =
        '{"updated_at":2000,"slots":[{"i":60,"l":"Windows日程","c":1,"ts":2000}]}';

    provider.goToDate(DateTime(2026, 9, 6));
    await _waitUntil(
      () => provider.getSlotsForDate('2026-09-06')?[60].label == 'Windows日程',
    );

    expect(
      state.pullRequests,
      ['g/2026-09-05', 'g/2026-09-06', 'g/2026-09-07'],
    );
    expect(
      provider.getSlotsForDate('2026-09-06')?[60].label,
      'Windows日程',
    );
  });

  test('跨日且仍停留在今天时自动推进到新的一天', () async {
    final state = _RemoteState();
    final provider = await _createProvider(state, mobile: true);
    addTearDown(provider.dispose);
    await provider.setScheduleUser(DiaryKind.g);

    final now = DateTime.now();
    final tomorrow = DateTime(now.year, now.month, now.day + 1, 8, 30);
    var notifications = 0;
    provider.addListener(() => notifications++);

    expect(provider.advanceToTodayIfNeeded(now: tomorrow), isTrue);
    expect(
      provider.currentDate,
      DateTime(now.year, now.month, now.day + 1),
    );
    expect(notifications, greaterThan(0));

    // 同一天再次检查不会重复推进
    expect(
      provider.advanceToTodayIfNeeded(
        now: tomorrow.add(const Duration(hours: 3)),
      ),
      isFalse,
    );
  });

  test('用户手动停在历史日期时，跨日不抢视图', () async {
    final state = _RemoteState();
    final provider = await _createProvider(state, mobile: true);
    addTearDown(provider.dispose);
    await provider.setScheduleUser(DiaryKind.g);

    final now = DateTime.now();
    final yesterday = DateTime(now.year, now.month, now.day - 1);
    provider.goToDate(yesterday);
    final selected = provider.currentDate;
    expect(selected, yesterday);

    final tomorrow = DateTime(now.year, now.month, now.day + 1, 9);
    expect(provider.advanceToTodayIfNeeded(now: tomorrow), isFalse);
    expect(provider.currentDate, selected);

    // 之后每天检查也不会把用户从历史日期拉走
    expect(
      provider.advanceToTodayIfNeeded(
        now: tomorrow.add(const Duration(days: 2)),
      ),
      isFalse,
    );
    expect(provider.currentDate, selected);
  });
}
