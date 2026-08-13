import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/models/category.dart';
import 'package:time_manager/providers/time_provider.dart';

/// 测试用的 GoogleSignInPlatform fake：所有方法返回安全默认值，
/// 避免 TimeProvider 初始化时 GoogleCalendarService.restoreSignIn 抛 UnimplementedError
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
  Future<void> clearAuthorizationToken(
      ClearAuthorizationTokenParams params) async {}

  @override
  Future<void> signOut(SignOutParams params) async {}

  @override
  Future<void> disconnect(DisconnectParams params) async {}
}

Future<TimeProvider> _createProvider() async {
  final provider = TimeProvider();
  // 等待本地数据加载完成，避免后续 addCategory 被初始化覆盖
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!provider.isInitialLoadFinished &&
      DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  return provider;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    GoogleSignInPlatform.instance = _FakeGoogleSignInPlatform();
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
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => '/tmp/time_manager_test',
    );
  });

  test('getParentStatistics 聚合隐藏子事件并把无归属标签归入"临时"', () async {
    final provider = await _createProvider();

    provider.addCategory(Category(
      name: '家庭',
      color: Colors.red,
      subCategories: ['做饭'],
      hiddenSubCategories: ['打扫'],
      updatedAt: 1,
    ));
    provider.addCategory(Category(
      name: '娱乐',
      color: Colors.blue,
      updatedAt: 1,
    ));

    final yesterday = DateTime.now().subtract(const Duration(days: 1));
    // 子事件
    provider.assignCategoryToSlots({0}, Category(name: '做饭', color: Colors.red),
        date: yesterday);
    // 隐藏子事件 → 应并入"家庭"
    provider.assignCategoryToSlots({1}, Category(name: '打扫', color: Colors.red),
        date: yesterday);
    // 父事件本身
    provider.assignCategoryToSlots({2}, Category(name: '娱乐', color: Colors.blue),
        date: yesterday);
    // 临时事件（无归属）
    provider.assignCategoryToSlots({3}, Category(name: '随口记录', color: Colors.grey),
        date: yesterday);
    // 边界：恰好命名为"临时"的标签也应归入聚合项
    provider.assignCategoryToSlots(
        {4}, Category(name: TimeProvider.temporaryCategoryName, color: Colors.grey),
        date: yesterday);

    final stats = provider.getParentStatistics(yesterday, yesterday);

    // 每个槽位 1/6 小时：做饭+打扫 → 家庭 = 1/3；娱乐 = 1/6；随口记录+临时 = 1/3
    expect(stats['家庭'], closeTo(1 / 3, 1e-9));
    expect(stats['娱乐'], closeTo(1 / 6, 1e-9));
    expect(stats[TimeProvider.temporaryCategoryName], closeTo(1 / 3, 1e-9));
    // 子事件与临时标签不得独立成项
    expect(stats.containsKey('做饭'), isFalse);
    expect(stats.containsKey('打扫'), isFalse);
    expect(stats.containsKey('随口记录'), isFalse);
    expect(stats.length, 3);
  });

  test('getTemporaryLabels 收集无归属标签并排除分类/子分类', () async {
    final provider = await _createProvider();

    provider.addCategory(Category(
      name: '家庭',
      color: Colors.red,
      subCategories: ['做饭'],
      hiddenSubCategories: ['打扫'],
      updatedAt: 1,
    ));

    final yesterday = DateTime.now().subtract(const Duration(days: 1));
    provider.assignCategoryToSlots({0}, Category(name: '做饭', color: Colors.red),
        date: yesterday);
    provider.assignCategoryToSlots({1}, Category(name: '打扫', color: Colors.red),
        date: yesterday);
    provider.assignCategoryToSlots({2}, Category(name: '家庭', color: Colors.red),
        date: yesterday);
    provider.assignCategoryToSlots({3}, Category(name: '随口记录', color: Colors.grey),
        date: yesterday);
    provider.assignCategoryToSlots(
        {4}, Category(name: TimeProvider.temporaryCategoryName, color: Colors.grey),
        date: yesterday);

    final temps = provider.getTemporaryLabels();

    expect(temps, contains('随口记录'));
    // 边界：恰好命名为"临时"的标签也识别为临时事件
    expect(temps, contains(TimeProvider.temporaryCategoryName));
    expect(temps.contains('做饭'), isFalse);
    expect(temps.contains('打扫'), isFalse);
    expect(temps.contains('家庭'), isFalse);
  });

  test('getEventHistory("临时") 展开为所有临时事件明细', () async {
    final provider = await _createProvider();

    provider.addCategory(Category(
      name: '家庭',
      color: Colors.red,
      subCategories: ['做饭'],
      hiddenSubCategories: ['打扫'],
      updatedAt: 1,
    ));

    final yesterday = DateTime.now().subtract(const Duration(days: 1));
    provider.assignCategoryToSlots({0}, Category(name: '做饭', color: Colors.red),
        date: yesterday);
    provider.assignCategoryToSlots({1}, Category(name: '随口记录', color: Colors.grey),
        date: yesterday);
    // 与"随口记录"不相邻（间隔空白槽），确保形成独立时间段
    provider.assignCategoryToSlots(
        {5}, Category(name: TimeProvider.temporaryCategoryName, color: Colors.grey),
        date: yesterday);

    final history =
        provider.getEventHistory(TimeProvider.temporaryCategoryName, 3);

    final ranges = history['${yesterday.month}月${yesterday.day}日'];
    expect(ranges, isNotNull, reason: '临时事件所在日期应出现在明细中');

    final labels = ranges!.map((r) => r.label).toSet();
    expect(labels, contains('随口记录'));
    expect(labels, contains(TimeProvider.temporaryCategoryName));
    expect(labels.contains('做饭'), isFalse);
  });

  test('删除父事件后，原父事件和子事件都归入临时', () async {
    final provider = await _createProvider();
    provider.addCategory(Category(
      name: '项目',
      color: Colors.red,
      subCategories: ['开发'],
      updatedAt: 1,
    ));

    final yesterday = DateTime.now().subtract(const Duration(days: 1));
    provider.assignCategoryToSlots(
        {0}, Category(name: '项目', color: Colors.red), date: yesterday);
    provider.assignCategoryToSlots(
        {1}, Category(name: '开发', color: Colors.red), date: yesterday);

    final index = provider.categories.indexWhere((cat) => cat.name == '项目');
    provider.deleteCategory(index);

    final stats = provider.getParentStatistics(yesterday, yesterday);
    expect(stats[TimeProvider.temporaryCategoryName], closeTo(1 / 3, 1e-9));
    expect(stats.length, 1);

    final history = provider.getEventHistory(
        TimeProvider.temporaryCategoryName, 3);
    final ranges = history['${yesterday.month}月${yesterday.day}日'];
    expect(ranges, isNotNull);
    expect(ranges!.map((range) => range.label), containsAll(['项目', '开发']));
  });

  test('全部事件统计只将无归属标签合并为临时', () async {
    final provider = await _createProvider();
    provider.addCategory(Category(
      name: '工作',
      color: Colors.blue,
      subCategories: ['会议'],
      updatedAt: 1,
    ));

    final yesterday = DateTime.now().subtract(const Duration(days: 1));
    provider.assignCategoryToSlots(
        {0}, Category(name: '会议', color: Colors.blue), date: yesterday);
    provider.assignCategoryToSlots(
        {1}, Category(name: '临时拜访', color: Colors.grey), date: yesterday);

    final stats = provider.getStatisticsWithTemporaryGrouped(yesterday, yesterday);

    expect(stats['会议'], closeTo(1 / 6, 1e-9));
    expect(stats[TimeProvider.temporaryCategoryName], closeTo(1 / 6, 1e-9));
    expect(stats.containsKey('临时拜访'), isFalse);
  });
}
