import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/models/category.dart';
import 'package:time_manager/models/target.dart';
import 'package:time_manager/providers/time_provider.dart';

class _FakeGoogleSignInPlatform extends GoogleSignInPlatform {
  @override
  Future<void> init(InitParameters params) async {}

  @override
  Future<AuthenticationResults?> attemptLightweightAuthentication(
          AttemptLightweightAuthenticationParameters params) async =>
      null;

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
          ClientAuthorizationTokensForScopesParameters params) async =>
      null;

  @override
  Future<ServerAuthorizationTokenData?> serverAuthorizationTokensForScopes(
          ServerAuthorizationTokensForScopesParameters params) async =>
      null;

  @override
  Future<void> clearAuthorizationToken(
      ClearAuthorizationTokenParams params) async {}

  @override
  Future<void> signOut(SignOutParams params) async {}

  @override
  Future<void> disconnect(DisconnectParams params) async {}
}

Future<TimeProvider> _createProvider() async {
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

  final provider = TimeProvider();
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!provider.isInitialLoadFinished && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  return provider;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('按日期撤销只影响目标日期，不会误撤其他日期的编辑', () async {
    final provider = await _createProvider();
    addTearDown(provider.dispose);

    final dateA = provider.currentDate;
    final dateB = dateA.add(const Duration(days: 1));
    final category = Category(
      id: 'work',
      name: '工作',
      color: Colors.blue,
      subCategories: const [],
    );

    provider.assignCategoryToSlots(const {100}, category, date: dateA);
    provider.assignCategoryToSlots(const {110}, category, date: dateB);

    // 删除 A 日的块：即时生效。
    expect(provider.removeEventFromSlot(100, date: dateA), isTrue);
    expect(provider.slotsForDate(dateA)[100].recorded, isFalse);
    expect(provider.slotsForDate(dateB)[110].recorded, isTrue);

    // 提示条撤销：按 A 日定位。
    expect(provider.undoLastChangeOnDate(provider.dateKeyFor(dateA)), isTrue);
    expect(provider.slotsForDate(dateA)[100].recorded, isTrue);
    expect(provider.slotsForDate(dateA)[100].label, '工作');
    // B 日编辑不受影响。
    expect(provider.slotsForDate(dateB)[110].recorded, isTrue);
  });

  test('没有可撤销编辑的日期返回 false', () async {
    final provider = await _createProvider();
    addTearDown(provider.dispose);

    expect(provider.undoLastChangeOnDate('2026-01-01'), isFalse);
  });

  test('撤销后栈耗尽再撤销返回 false', () async {
    final provider = await _createProvider();
    addTearDown(provider.dispose);

    final dateA = provider.currentDate;
    final category = Category(
      id: 'work',
      name: '工作',
      color: Colors.blue,
      subCategories: const [],
    );

    // 记录 + 删除各入栈一次：两次撤销把栈耗尽，第三次返回 false。
    provider.assignCategoryToSlots(const {100}, category, date: dateA);
    expect(provider.removeEventFromSlot(100, date: dateA), isTrue);
    expect(provider.undoLastChangeOnDate(provider.dateKeyFor(dateA)), isTrue);
    expect(provider.undoLastChangeOnDate(provider.dateKeyFor(dateA)), isTrue);
    expect(provider.undoLastChangeOnDate(provider.dateKeyFor(dateA)), isFalse);
  });

  test('模板删除后可撤销恢复，同 id 已存在时拒绝恢复', () async {
    final provider = await _createProvider();
    addTearDown(provider.dispose);

    final category = Category(
      id: 'work',
      name: '工作',
      color: Colors.blue,
      subCategories: const [],
    );
    provider.assignCategoryToSlots(const {100, 101}, category);
    expect(provider.saveTemplateFromCurrentDay('晨间例程'), isTrue);
    final template = provider.templates.single;
    expect(template.name, '晨间例程');

    provider.deleteTemplate(template.id);
    expect(provider.templates, isEmpty);

    // 撤销：恢复同一模板对象。
    expect(provider.undoDeleteTemplate(template), isTrue);
    expect(provider.templates.single.id, template.id);

    // 同 id 已存在（例如用户已重建）时撤销失效。
    expect(provider.undoDeleteTemplate(template), isFalse);
    expect(provider.templates.single.id, template.id);
  });

  test('目标删除后可撤销恢复，同 id 已存在时拒绝恢复', () async {
    final provider = await _createProvider();
    addTearDown(provider.dispose);

    final target = Target(
      id: 'target-1',
      name: '健身',
      categoryId: 'work',
      type: TargetType.duration,
      color: Colors.blue,
      period: 'day',
      updatedAt: DateTime(2026, 1, 1).millisecondsSinceEpoch,
    );
    provider.addTarget(target);
    expect(provider.targets.any((t) => t.id == 'target-1'), isTrue);

    expect(provider.deleteTarget(target), isTrue);
    expect(provider.targets.any((t) => t.id == 'target-1'), isFalse);

    // 撤销：addTarget 会移除墓碑并把 updatedAt 提到当前时间，
    // 恢复后的目标在与远端文档合并时能胜过旧墓碑。
    expect(provider.undoDeleteTarget(target), isTrue);
    final restored = provider.targets.firstWhere((t) => t.id == 'target-1');
    expect(
      restored.updatedAt,
      greaterThan(DateTime(2026, 1, 1).millisecondsSinceEpoch),
    );

    // 同 id 已存在时撤销失效。
    expect(provider.undoDeleteTarget(target), isFalse);
  });

  test('分类删除后撤销恢复分类与级联目标，并清理删除关系', () async {
    final provider = await _createProvider();
    addTearDown(provider.dispose);

    provider.addCategory(Category(
      name: '工作',
      color: Colors.blue,
      subCategories: ['开会'],
    ));
    // 空偏好下 provider 会预置默认分类，按名称定位刚加的分类。
    final workIndex = provider.categories.indexWhere((c) => c.name == '工作');
    expect(workIndex, greaterThanOrEqualTo(0));
    final categoryId = provider.categories[workIndex].id;
    final target = Target(
      id: 'target-1',
      name: '健身',
      categoryId: categoryId,
      type: TargetType.duration,
      color: Colors.blue,
      period: 'day',
    );
    provider.addTarget(target);

    final yesterday = DateTime.now().subtract(const Duration(days: 1));
    provider.assignCategoryToSlots(
      const {0},
      Category(id: categoryId, name: '开会', color: Colors.blue),
      subLabel: '开会',
      date: yesterday,
    );

    // 删除：分类与级联目标即时消失，历史标签进入「已删除/临时」口径。
    final snapshot = provider.deleteCategory(workIndex);
    expect(snapshot, isNotNull);
    expect(snapshot!.category.name, '工作');
    expect(snapshot.cascadeDeletedTargets.single.id, 'target-1');
    expect(provider.categories.any((c) => c.name == '工作'), isFalse);
    expect(provider.targets, isEmpty);
    // 历史标签「开会」落入临时口径，不再归入已删除的分类。
    final statsAfterDelete =
        provider.getParentStatistics(yesterday, yesterday);
    expect(statsAfterDelete.containsKey('工作'), isFalse);

    // 撤销：分类放回原位置、目标恢复、删除关系清理，
    // 历史标签重新归入恢复的分类。
    expect(provider.undoDeleteCategory(snapshot), isTrue);
    final restored = provider.categories
        .firstWhere((c) => c.name == '工作');
    expect(restored.updatedAt, greaterThan(snapshot.category.updatedAt));
    expect(provider.targets.single.id, 'target-1');
    expect(provider.targets.single.updatedAt, greaterThan(target.updatedAt));
    final statsAfterUndo =
        provider.getParentStatistics(yesterday, yesterday);
    expect(statsAfterUndo['工作'], isNotNull);
    expect(statsAfterUndo['工作'], closeTo(1 / 6, 1e-9));

    // 分类已回到列表时再次撤销失效。
    expect(provider.undoDeleteCategory(snapshot), isFalse);
    expect(provider.categories.where((c) => c.name == '工作').length, 1);
  });

  // 跨身份安全说明：移动端身份切换经 _invalidateIdentityScopedOperations
  // 清空撤销栈；桌面端本地时间块本就不分身份，撤销栈共享同一份数据。
  // 提示条撤销的身份校验由 showAppUndoSnackBar 的 identityToken 承担，
  // 用例见 test/app_snack_bar_test.dart。
}
