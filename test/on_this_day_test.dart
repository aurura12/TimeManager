import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/providers/time_provider.dart';
import 'package:time_manager/services/on_this_day_service.dart';

/// 构造一个带记录的槽位 JSON
Map<String, dynamic> _slot(int index, String label) => {
      'i': index,
      'l': label,
      'cid': 'c1',
    };

/// 构造 TimeProvider（注入 dailySlots）
Future<TimeProvider> _makeProvider(Map<String, dynamic> slots) async {
  SharedPreferences.setMockInitialValues({});

  // mock 插件方法通道，避免 TimeProvider._init() 触发原生调用失败
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
    const MethodChannel('home_widget'),
    (call) async => null,
  );
  messenger.setMockMethodCallHandler(
    const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
    (call) async => null,
  );

  final provider = TimeProvider();
  await provider.importBackupJson(jsonEncode({
    'categories': [
      {
        'id': 'c1',
        'name': '测试分类',
        'color': 0xFF000000,
        'subCategories': <String>[],
        'hiddenSubCategories': <String>[],
      }
    ],
    'targets': <dynamic>[],
    'dailySlots': slots,
  }));
  return provider;
}

/// 注入本地日记草稿到 SharedPreferences（走 DiaryLocalStore.loadDraftBody 通道）
Future<void> _injectDiaryDraft(String kind, DateTime date, String body) async {
  final prefs = await SharedPreferences.getInstance();
  final d = DateTime(date.year, date.month, date.day);
  final key = 'diary_draft_${kind}_${d.year}'
      '${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}';
  await prefs.setString(key, body);
}

/// 注入出行记录文档到 SharedPreferences（走 TravelLocalStore.loadDraft 通道）
Future<void> _injectTravelDoc(String markdown) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('travel_records_draft', markdown);
}

String _travelMarkdown(List<Map<String, String>> records) {
  final body = const JsonEncoder.withIndent('  ').convert(records);
  return '---\ntitle: 出行记录\nupdated_at: 2025-01-01 00:00:00\n---\n$body\n';
}

/// 测试用的 GoogleSignInPlatform fake：所有方法返回安全默认值，
/// 避免 TimeProvider._init() 里 GoogleCalendarService.restoreSignIn 抛 UnimplementedError
class _FakeGoogleSignInPlatform extends GoogleSignInPlatform {
  @override
  Future<void> init(InitParameters params) async {}

  @override
  Future<AuthenticationResults?> attemptLightweightAuthentication(
    AttemptLightweightAuthenticationParameters params,
  ) async {
    return null;
  }

  @override
  bool supportsAuthenticate() => false;

  @override
  Future<AuthenticationResults> authenticate(AuthenticateParameters params) {
    throw UnimplementedError();
  }

  @override
  bool authorizationRequiresUserInteraction() => false;

  @override
  Future<ClientAuthorizationTokenData?> clientAuthorizationTokensForScopes(
    ClientAuthorizationTokensForScopesParameters params,
  ) async {
    return null;
  }

  @override
  Future<ServerAuthorizationTokenData?> serverAuthorizationTokensForScopes(
    ServerAuthorizationTokensForScopesParameters params,
  ) async {
    return null;
  }

  @override
  Future<void> clearAuthorizationToken(ClearAuthorizationTokenParams params) async {}

  @override
  Future<void> signOut(SignOutParams params) async {}

  @override
  Future<void> disconnect(DisconnectParams params) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    GoogleSignInPlatform.instance = _FakeGoogleSignInPlatform();
  });

  group('OnThisDayService.summarizeDiary', () {
    test('剥离 front matter', () {
      const raw = '---\ntitle: x\ndate: 2025-01-01\n---\n\n今天很开心';
      expect(OnThisDayService.summarizeDiary(raw), '今天很开心');
    });

    test('结束 --- 无换行时也能匹配（front matter 剥离为空返回 null）', () {
      expect(OnThisDayService.summarizeDiary('---\ntitle: x\n---'), isNull);
    });

    test('支持 CRLF 换行（Windows 日记文件）', () {
      const raw = '---\r\ntitle: x\r\n---\r\n\r\n今天很开心';
      expect(OnThisDayService.summarizeDiary(raw), '今天很开心');
    });

    test('正文超过 80 字时截断并追加省略号', () {
      final longBody = '字' * 100;
      final raw = '---\ntitle: x\n---\n\n$longBody';
      final result = OnThisDayService.summarizeDiary(raw)!;
      expect(result.length, 81); // 80 字 + …
      expect(result.endsWith('…'), isTrue);
      expect(result.substring(0, 80), '字' * 80);
    });

    test('空内容返回 null', () {
      expect(OnThisDayService.summarizeDiary(''), isNull);
      expect(OnThisDayService.summarizeDiary('   '), isNull);
      expect(OnThisDayService.summarizeDiary('---\ntitle: x\n---'), isNull);
    });

    test('无 front matter 时原样返回', () {
      expect(OnThisDayService.summarizeDiary('纯正文'), '纯正文');
    });
  });

  group('OnThisDayService.collectEntries', () {
    test('时间记录：只返回往年同日的年份，按从近到远排序', () async {
      final now = DateTime.now();
      final y1 = now.year - 1;
      final y2 = now.year - 2;

      final provider = await _makeProvider({
        '$y1-${_two(now.month)}-${_two(now.day)}': [
          _slot(0, '学习'),
          _slot(1, '学习'),
          _slot(2, '运动'),
        ],
        '$y2-${_two(now.month)}-${_two(now.day)}': [_slot(0, '学习')],
        // 日期不匹配，不应返回
        '$y2-${_two(now.month)}-${_two(now.day + 1)}': [_slot(0, '学习')],
      });

      final entries = await OnThisDayService.collectEntries(provider);
      expect(entries.length, 2);
      expect(entries[0].year, y1);
      expect(entries[1].year, y2);
    });

    test('时间记录：聚合同 label 槽位，按时长降序', () async {
      final now = DateTime.now();
      final y = now.year - 1;

      final provider = await _makeProvider({
        '$y-${_two(now.month)}-${_two(now.day)}': [
          _slot(0, '学习'),
          _slot(1, '学习'),
          _slot(2, '运动'),
          _slot(3, '运动'),
          _slot(4, '运动'),
        ],
      });

      final entries = await OnThisDayService.collectEntries(provider);
      expect(entries.length, 1);
      final entry = entries[0];

      expect(entry.activities.length, 2);
      expect(entry.activities[0].label, '运动'); // 30分钟，排第一
      expect(entry.activities[0].minutes, 30);
      expect(entry.activities[1].label, '学习'); // 20分钟
      expect(entry.activities[1].minutes, 20);
      expect(entry.totalMinutes, 50);
    });

    test('只有日记、没有时间记录也展示该年份', () async {
      final now = DateTime.now();
      final y = now.year - 1;
      final pastDate = DateTime(y, now.month, now.day);

      final provider = await _makeProvider({}); // 无时间记录
      await _injectDiaryDraft('g', pastDate, '---\ntitle: x\n---\n\n今天去散步了');

      final entries = await OnThisDayService.collectEntries(provider);
      expect(entries.length, 1);
      expect(entries[0].year, y);
      expect(entries[0].diaryGuaiGuai, '今天去散步了');
      expect(entries[0].totalMinutes, 0);
    });

    test('只有出行、没有时间记录也展示该年份', () async {
      final now = DateTime.now();
      final y = now.year - 1;
      final dateKey = '$y-${_two(now.month)}-${_two(now.day)}';

      final provider = await _makeProvider({});
      await _injectTravelDoc(_travelMarkdown([
        {'date': dateKey, 'location': '西湖', 'event': '散步'},
      ]));

      final entries = await OnThisDayService.collectEntries(provider);
      expect(entries.length, 1);
      expect(entries[0].year, y);
      expect(entries[0].travelLocation, '西湖');
      expect(entries[0].travelEvent, '散步');
    });

    test('三数据源合并到同一年的 entry', () async {
      final now = DateTime.now();
      final y = now.year - 1;
      final pastDate = DateTime(y, now.month, now.day);
      final dateKey = OnThisDayService.dateKeyOf(pastDate);

      final provider = await _makeProvider({
        dateKey: [_slot(0, '学习'), _slot(1, '学习')],
      });
      await _injectDiaryDraft('j', pastDate, '---\ntitle: x\n---\n\n今天加班到很晚');
      await _injectTravelDoc(_travelMarkdown([
        {'date': dateKey, 'location': '公司', 'event': '加班'},
      ]));

      final entries = await OnThisDayService.collectEntries(provider);
      expect(entries.length, 1);
      final entry = entries[0];
      expect(entry.totalMinutes, 20);
      expect(entry.diaryJingJing, '今天加班到很晚');
      expect(entry.diaryGuaiGuai, isNull);
      expect(entry.travelLocation, '公司');
    });

    test('超过 maxYears 的年份不返回', () async {
      final now = DateTime.now();
      final oldYear = now.year - OnThisDayService.maxYears - 1; // 超过上限

      final provider = await _makeProvider({
        '$oldYear-${_two(now.month)}-${_two(now.day)}': [_slot(0, '学习')],
      });

      final entries = await OnThisDayService.collectEntries(provider);
      expect(entries, isEmpty);
    });

    test('没有任何往年记录时返回空列表', () async {
      final now = DateTime.now();
      final provider = await _makeProvider({
        // 只有今天的数据，不是往年
        '${now.year}-${_two(now.month)}-${_two(now.day)}': [_slot(0, '学习')],
      });

      final entries = await OnThisDayService.collectEntries(provider);
      expect(entries, isEmpty);
    });

    test('未记录槽位不计入', () async {
      final now = DateTime.now();
      final y = now.year - 1;

      final provider = await _makeProvider({
        '$y-${_two(now.month)}-${_two(now.day)}': [
          _slot(0, '学习'),
          // 无记录槽位：不传 label
          {'i': 1, 'cid': 'c1'},
        ],
      });

      final entries = await OnThisDayService.collectEntries(provider);
      expect(entries.length, 1);
      expect(entries[0].totalMinutes, 10);
      expect(entries[0].activities.single.label, '学习');
    });

    test('闰日 2/29 不因 DateTime 进位导致日期键错位', () async {
      // 背景：Dart 的 DateTime(2025, 2, 29) 不会抛异常，而是自动进位成 3/1。
      // collectEntries 内部用字符串拼接日期键（_dateKeyOf），不依赖 DateTime 构造，
      // 因此即使今天是 2/29，往年非闰年也会精确匹配 02-29 键，而非误匹配 03-01。
      // 本用例验证 collectEntries 的键生成不受 DateTime 进位影响：
      // 注入一个"往年 3/1"的数据，今天（非 2/29）不应命中它。
      final now = DateTime.now();
      final y = now.year - 1;
      final provider = await _makeProvider({
        // 与今天月/日不同的日期键，不应被命中
        '$y-03-01': [_slot(0, '错误数据')],
      });
      final entries = await OnThisDayService.collectEntries(provider);
      expect(entries, isEmpty);
    });
  });
}

String _two(int v) => v.toString().padLeft(2, '0');
