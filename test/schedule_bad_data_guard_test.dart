import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/models/category.dart';
import 'package:time_manager/models/diary_kind.dart';
import 'package:time_manager/providers/time_provider.dart';
import 'package:time_manager/services/schedule_gitee_service.dart';
import 'package:time_manager/services/schedule_sync_dependencies.dart';

/// 测试桩状态：可配置每日期远端内容 / notFound，并记录拉取与上传请求。
class _RemoteState {
  final Map<String, String> remoteContents = {}; // "userCode/dateKey" -> JSON
  final Set<String> notFound = {}; // "userCode/dateKey" -> 文件不存在
  final List<String> pullRequests = [];
  final List<({String userCode, String dateKey, String content})> uploads = [];
}

ScheduleSyncDependencies _fakeDependencies(
  _RemoteState state, {
  Map<String, String>? remoteFiles,
}) {
  return ScheduleSyncDependencies(
    loadToken: () async => 'fake-token',
    listPaths: ({required token, required userCode}) async {
      return ScheduleGiteeListWithShaResult.success(remoteFiles ?? const {});
    },
    pullDay: ({required token, required dateKey, required userCode}) async {
      state.pullRequests.add('$userCode/$dateKey');
      final key = '$userCode/$dateKey';
      if (state.notFound.contains(key)) {
        return ScheduleGiteePullResult.notFound();
      }
      final content = state.remoteContents[key];
      if (content != null) {
        return ScheduleGiteePullResult.success(content, 'sha-$key');
      }
      return ScheduleGiteePullResult.notFound();
    },
    pushDay: ({
      required token,
      required dateKey,
      required userCode,
      required content,
      required commitMessage,
    }) async {
      state.uploads.add((
        userCode: userCode,
        dateKey: dateKey,
        content: content,
      ));
      return ScheduleGiteePushResult.success(created: false);
    },
    pushGoogleDay: (slots, date) async => true,
    pullGoogleDay: (date) async => const [],
  );
}

Future<TimeProvider> _createProvider({
  Map<String, Object> initialPreferences = const {},
  _RemoteState? state,
  Duration debounce = const Duration(minutes: 5),
  Map<String, String>? remoteFiles,
}) async {
  SharedPreferences.setMockInitialValues(initialPreferences);
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
    scheduleGiteeDebounce: debounce,
    googleCalendarSyncPlatformOverride: false,
    googleCalendarSignedInOverride: false,
    scheduleSyncDependencies: _fakeDependencies(
      state ?? _RemoteState(),
      remoteFiles: remoteFiles,
    ),
  );
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!provider.isInitialLoadFinished && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  await provider.setScheduleUser(DiaryKind.g);
  await Future<void>.delayed(const Duration(milliseconds: 100));
  return provider;
}

String _keyOf(DateTime date) {
  final y = date.year.toString().padLeft(4, '0');
  final m = date.month.toString().padLeft(2, '0');
  final d = date.day.toString().padLeft(2, '0');
  return '$y-$m-$d';
}

List<dynamic> _slotsOf(TimeProvider provider, String dateKey) {
  final map = provider.toBackupMap()['dailySlots'] as Map<String, dynamic>;
  return (map[dateKey] as List?) ?? const [];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('写出格式防御', () {
    test('toggleSlot 不能把空槽标记为已记录（不产生 l:null）', () async {
      final provider = await _createProvider();
      addTearDown(provider.dispose);
      final dateKey = _keyOf(provider.currentDate);

      provider.toggleSlot(98);

      final slots = provider.getSlotsForDate(dateKey);
      expect(slots, isNotNull);
      expect(slots![98].recorded, isFalse); // 空槽不得被标记为已记录
      // 序列化结果不含任何槽位
      expect(_slotsOf(provider, dateKey), isEmpty);
    });

    test('本地旧 l:null 坏记录加载后迁移为墓碑（导出 del:true 而非 l:null）',
        () async {
      final state = _RemoteState();
      final provider = await _createProvider(
        initialPreferences: {
          'daily_slots':
              '{"2026-09-06":[{"i":98,"l":null,"c":null,"ts":1788850893646}]}',
        },
        state: state,
      );
      addTearDown(provider.dispose);

      final entries = _slotsOf(provider, '2026-09-06');
      expect(entries.length, 1);
      expect(entries.single['i'], 98);
      expect(entries.single['del'], true);
      expect(entries.single['ts'], 1788850893646);
      // 不再存在任何 live 条目（空标签已被迁移成墓碑）
      expect(entries.where((e) => e['del'] != true), isEmpty);
    });

    test('删除槽后再编辑同一天其他槽位，墓碑保留为 del:true', () async {
      final state = _RemoteState();
      final provider = await _createProvider(
        initialPreferences: {
          'daily_slots':
              '{"2026-09-06":[{"i":98,"l":"八股","c":1,"ts":1000},{"i":114,"l":"运动","c":2,"ts":1000}]}',
        },
        state: state,
      );
      addTearDown(provider.dispose);
      final day = DateTime(2026, 9, 6);

      provider.removeEventFromSlot(98, date: day);
      provider.assignCategoryToSlots(
        {114},
        Category(name: '运动', color: Color(0xFF4A90E2)),
        date: day,
      );
      await provider.syncScheduleToGitee(dateKey: '2026-09-06');

      expect(state.uploads, hasLength(1));
      final uploaded = json.decode(state.uploads.single.content)
          as Map<String, dynamic>;
      final slots = (uploaded['slots'] as List).cast<Map<String, dynamic>>();
      final tomb = slots.singleWhere((e) => e['i'] == 98);
      expect(tomb['del'], true);
      final live = slots.singleWhere((e) => e['i'] == 114);
      expect(live['del'], isNot(true));
      expect(live['l'], '运动');
      expect(
        slots.where((e) => e['del'] != true && e['l'] == null),
        isEmpty,
      );

      // 写回本地后仍为墓碑
      final localEntries = _slotsOf(provider, '2026-09-06');
      expect(localEntries.singleWhere((e) => e['i'] == 98)['del'], true);
    });

    test('模拟 9/8 场景：删除 16:20-16:40(98/99) 再新增其它时段，墓碑不变空标签',
        () async {
      final state = _RemoteState();
      final provider = await _createProvider(
        initialPreferences: {
          'daily_slots':
              '{"2026-09-08":[{"i":98,"l":"八股","c":1,"ts":1000},{"i":99,"l":"八股","c":1,"ts":1000},{"i":60,"l":"工作","c":3,"ts":1000}]}',
        },
        state: state,
      );
      addTearDown(provider.dispose);
      final day = DateTime(2026, 9, 8);

      provider.removeEventFromSlot(98, date: day);
      provider.removeEventFromSlot(99, date: day);
      // 同一天再编辑其它槽位 → 整日重序列化
      provider.assignCategoryToSlots(
        {100},
        Category(name: '学习', color: Color(0xFF9CB86A)),
        date: day,
      );
      await provider.syncScheduleToGitee(dateKey: '2026-09-08');

      expect(state.uploads, hasLength(1));
      final uploaded = json.decode(state.uploads.single.content)
          as Map<String, dynamic>;
      final slots = (uploaded['slots'] as List).cast<Map<String, dynamic>>();
      for (final idx in const [98, 99]) {
        final tomb = slots.singleWhere((e) => e['i'] == idx);
        expect(tomb['del'], true, reason: '槽位 $idx 必须是删除墓碑');
        expect(tomb['l'], isNull);
      }
      expect(slots.singleWhere((e) => e['i'] == 100)['l'], '学习');
      expect(slots.where((e) => e['del'] != true && e['l'] == null), isEmpty);
    });
  });

  group('远端坏记录拒绝策略', () {
    test('单日拉取遇到远端 l:null：拒绝应用，本地保持不变', () async {
      final state = _RemoteState();
      final provider = await _createProvider(
        initialPreferences: {
          'daily_slots':
              '{"2026-09-06":[{"i":98,"l":"八股","c":1,"ts":1000}]}',
        },
        state: state,
      );
      addTearDown(provider.dispose);
      state.remoteContents['g/2026-09-06'] =
          '{"updated_at":2000,"slots":[{"i":98,"l":null,"c":null,"ts":1788850893646},{"i":114,"l":"新日程","ts":3000}]}';

      final ok = await provider.pullScheduleFromGitee(
        date: DateTime(2026, 9, 6),
      );

      expect(ok, isFalse);
      final slots = provider.getSlotsForDate('2026-09-06')!;
      expect(slots[98].recorded, isTrue);
      expect(slots[98].label, '八股');
      expect(slots[114].recorded, isFalse); // 坏文件中合法部分也不得部分应用
    });

    test('推送遇到远端 l:null：中止上传，待同步状态保留', () async {
      final state = _RemoteState();
      final provider = await _createProvider(
        initialPreferences: {
          'daily_slots':
              '{"2026-09-06":[{"i":98,"l":"八股","c":1,"ts":1000}]}',
          'pending_gitee_sync_dates': <String>['2026-09-06'],
        },
        state: state,
      );
      addTearDown(provider.dispose);
      state.remoteContents['g/2026-09-06'] =
          '{"updated_at":2000,"slots":[{"i":98,"l":null,"c":null,"ts":1788850893646}]}';

      await provider.syncScheduleToGitee(dateKey: '2026-09-06');

      expect(state.uploads, isEmpty);
      expect(provider.pendingGiteeSyncDates, contains('2026-09-06'));
    });

    test('全量拉取：坏日期被跳过且不应用，好日期正常应用', () async {
      final state = _RemoteState();
      final provider = await _createProvider(
        state: state,
        remoteFiles: {
          'schedule/g/2026-09-05.json': 'sha-05',
          'schedule/g/2026-09-06.json': 'sha-06',
        },
      );
      addTearDown(provider.dispose);
      state.remoteContents['g/2026-09-06'] =
          '{"updated_at":2000,"slots":[{"i":60,"l":"新日程","ts":3000}]}';
      // 09-05 远端是坏数据（l:null）
      state.remoteContents['g/2026-09-05'] =
          '{"updated_at":2000,"slots":[{"i":98,"l":null,"c":null,"ts":1}]}';

      await provider.pullAllSchedulesFromGitee();

      // 坏日期 09-05 未被应用（本地无该日）
      expect(provider.getSlotsForDate('2026-09-05'), isNull);
      // 好日期 09-06 已应用
      final applied = provider.getSlotsForDate('2026-09-06')!;
      expect(applied[60].recorded, isTrue);
      expect(applied[60].label, '新日程');
    });
  });

  group('身份与路径隔离', () {
    test('晶晶身份推送只写 schedule/j/', () async {
      final state = _RemoteState();
      final provider = await _createProvider(state: state);
      addTearDown(provider.dispose);

      await provider.setScheduleUser(DiaryKind.j);
      expect(provider.scheduleUser, DiaryKind.j);

      provider.assignCategoryToSlots(
        {0},
        Category(name: '晶晶专属', color: Color(0xFF9CB86A)),
        date: DateTime(2026, 9, 6),
      );
      await provider.syncScheduleToGitee(dateKey: '2026-09-06');

      expect(state.uploads.single.userCode, DiaryKind.j.code);
      expect(state.uploads.single.dateKey, '2026-09-06');
    });

    test('晶晶身份拉取只读 schedule/j/', () async {
      final state = _RemoteState();
      final provider = await _createProvider(state: state);
      addTearDown(provider.dispose);

      await provider.setScheduleUser(DiaryKind.j);
      state.remoteContents['j/2026-09-06'] =
          '{"updated_at":2000,"slots":[{"i":60,"l":"晶晶日程","ts":3000}]}';

      final ok = await provider.pullScheduleFromGitee(
        date: DateTime(2026, 9, 6),
      );

      expect(ok, isTrue);
      expect(state.pullRequests, contains('j/2026-09-06'));
      expect(state.pullRequests, isNot(contains('g/2026-09-06')));
      expect(provider.getSlotsForDate('2026-09-06')![60].label, '晶晶日程');
    });
  });
}
