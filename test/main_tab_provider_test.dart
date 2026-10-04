import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:time_manager/models/main_tab_id.dart';
import 'package:time_manager/providers/main_tab_provider.dart';

import 'support/fake_main_tab_preferences_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('旧用户默认显示六个标签，公开集合不可修改', () async {
    final provider = MainTabProvider();
    addTearDown(provider.dispose);
    await provider.ready;
    expect(provider.isLoaded, isTrue);
    expect(provider.order, MainTabId.values);
    expect(provider.visibleTabs, MainTabId.values);
    expect(provider.hiddenTabs, isEmpty);
    expect(() => provider.order.clear(), throwsUnsupportedError);
    expect(
        () => provider.hiddenTabs.add(MainTabId.diary), throwsUnsupportedError);
    expect(() => provider.visibleTabs.clear(), throwsUnsupportedError);
  });

  test('排序与隐藏一起持久化，重建后恢复，身份偏好不受影响', () async {
    SharedPreferences.setMockInitialValues({'schedule_user_kind': 'g'});
    final provider = MainTabProvider();
    addTearDown(provider.dispose);
    final order = MainTabId.values.reversed.toList();
    await provider.save(
      order: order,
      hiddenTabs: {MainTabId.travel, MainTabId.record},
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('schedule_user_kind', 'j');
    final restored = MainTabProvider();
    addTearDown(restored.dispose);
    await restored.ready;
    expect(restored.order, order);
    expect(restored.hiddenTabs, {MainTabId.travel, MainTabId.record});
    expect(restored.visibleTabs, [
      MainTabId.profile,
      MainTabId.target,
      MainTabId.checkIn,
      MainTabId.diary,
    ]);
    expect(prefs.getString('schedule_user_kind'), 'j');
  });

  test('恢复默认后重启仍为完整默认导航', () async {
    final provider = MainTabProvider();
    addTearDown(provider.dispose);
    await provider.save(
      order: MainTabId.values.reversed.toList(),
      hiddenTabs: {MainTabId.diary},
    );
    await provider.save(order: MainTabId.values, hiddenTabs: {});
    final restored = MainTabProvider();
    addTearDown(restored.dispose);
    await restored.ready;
    expect(restored.visibleTabs, MainTabId.values);
  });

  test('写盘失败时导航和偏好缓存保持原值，重试不被失败的保存队列阻断', () async {
    final originalStore = SharedPreferencesStorePlatform.instance;
    final store = FakeMainTabPreferencesStore(rejectWrites: true);
    SharedPreferencesStorePlatform.instance = store;
    addTearDown(() => SharedPreferencesStorePlatform.instance = originalStore);
    final provider = MainTabProvider();
    addTearDown(provider.dispose);
    await provider.ready;
    await expectLater(
      provider.save(order: MainTabId.values, hiddenTabs: {MainTabId.travel}),
      throwsStateError,
    );
    expect(provider.visibleTabs, MainTabId.values);
    final restored = MainTabProvider();
    addTearDown(restored.dispose);
    await restored.ready;
    expect(restored.visibleTabs, MainTabId.values);
    store.rejectWrites = false;
    await provider
        .save(order: MainTabId.values, hiddenTabs: {MainTabId.travel});
    expect(provider.hiddenTabs, {MainTabId.travel});
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    expect(jsonDecode(prefs.getString(MainTabProvider.storageKey)!)['hidden'],
        ['travel']);
  });

  test('读盘去重、忽略未知标签、补齐缺项并修复全隐藏的偏好', () async {
    SharedPreferences.setMockInitialValues({
      MainTabProvider.storageKey: jsonEncode({
        'order': ['target', 'target', 'unknown', null, 'diary'],
        'hidden': MainTabId.values.map((tab) => tab.id).toList(),
      }),
    });
    final provider = MainTabProvider();
    addTearDown(provider.dispose);
    await provider.ready;
    expect(provider.order, [
      MainTabId.target,
      MainTabId.diary,
      MainTabId.record,
      MainTabId.travel,
      MainTabId.checkIn,
      MainTabId.profile,
    ]);
    expect(provider.visibleTabs, [MainTabId.record, MainTabId.profile]);
  });

  test('损坏文档和错误类型回退默认，不阻止启动', () async {
    for (final value in ['{broken', '[]', 'null', 42]) {
      SharedPreferences.setMockInitialValues(
          {MainTabProvider.storageKey: value});
      final provider = MainTabProvider();
      await provider.ready;
      expect(provider.visibleTabs, MainTabId.values);
      expect(provider.isLoaded, isTrue);
      provider.dispose();
    }
    final unavailable = MainTabProvider(
      preferencesLoader: () async => throw StateError('unavailable'),
    );
    addTearDown(unavailable.dispose);
    await unavailable.ready;
    expect(unavailable.isLoaded, isTrue);
    expect(unavailable.visibleTabs, MainTabId.values);
  });

  test('禁止隐藏设置入口、少于两个可见标签和重复/缺项顺序', () async {
    final provider = MainTabProvider();
    addTearDown(provider.dispose);
    await provider.ready;
    for (final hidden in [
      {MainTabId.profile},
      MainTabId.values.where((tab) => tab != MainTabId.profile).toSet(),
    ]) {
      expect(
        () => provider.save(order: MainTabId.values, hiddenTabs: hidden),
        throwsArgumentError,
      );
    }
    for (final order in [
      [MainTabId.record],
      List.filled(MainTabId.values.length, MainTabId.profile),
    ]) {
      expect(
        () => provider.save(order: order, hiddenTabs: {}),
        throwsArgumentError,
      );
    }
    expect(provider.visibleTabs, MainTabId.values);
  });

  test('启动读盘与并发保存按顺序完成，最后一次选择不会被旧偏好覆盖', () async {
    SharedPreferences.setMockInitialValues({
      MainTabProvider.storageKey: jsonEncode({
        'order': MainTabId.values.reversed.map((tab) => tab.id).toList(),
        'hidden': ['diary'],
      }),
    });
    final preferences = Completer<SharedPreferences>();
    final provider = MainTabProvider(
      preferencesLoader: () => preferences.future,
    );
    addTearDown(provider.dispose);
    final first = provider.save(order: MainTabId.values, hiddenTabs: {});
    final last = provider.save(
      order: MainTabId.values,
      hiddenTabs: {MainTabId.travel},
    );
    preferences.complete(await SharedPreferences.getInstance());
    await Future.wait([first, last]);
    final restored = MainTabProvider();
    addTearDown(restored.dispose);
    await restored.ready;
    expect(restored.order, MainTabId.values);
    expect(restored.hiddenTabs, {MainTabId.travel});
  });

  test('读盘中销毁不会向已销毁的 Provider 发通知', () async {
    final preferences = Completer<SharedPreferences>();
    final provider = MainTabProvider(
      preferencesLoader: () => preferences.future,
    );
    provider.dispose();
    preferences.complete(await SharedPreferences.getInstance());
    await expectLater(provider.ready, completes);
  });
}
