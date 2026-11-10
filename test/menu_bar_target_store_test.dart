import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/services/menu_bar_target_store.dart';
import 'package:time_manager/services/transactional_preference_string.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('保存后能读回完整目标', () async {
    final store = MenuBarTargetStore();
    expect(
      await store.save(
        const MenuBarTarget(
          categoryId: 'c1',
          categoryName: '工作',
          subLabel: '开会',
        ),
      ),
      isTrue,
    );

    final loaded = await MenuBarTargetStore().load();
    expect(loaded?.categoryId, 'c1');
    expect(loaded?.categoryName, '工作');
    expect(loaded?.subLabel, '开会');
  });

  test('subLabel 为 null 也能往返', () async {
    final store = MenuBarTargetStore();
    await store.save(const MenuBarTarget(categoryId: 'c2', categoryName: '休息'));

    final loaded = await store.load();
    expect(loaded?.categoryId, 'c2');
    expect(loaded?.subLabel, isNull);
  });

  test('脏数据一律返回 null', () async {
    final raw = TransactionalPreferenceString(MenuBarTargetStore.storageKey);
    for (final value in <String>[
      'not json',
      '{}',
      '[]',
      '{"v":1}',
      '{"v":1,"categoryId":""}',
      '{"v":1,"categoryId":123}',
    ]) {
      await raw.save(value);
      expect(await MenuBarTargetStore().load(), isNull, reason: value);
    }
  });

  test('空 subLabel 归一为 null', () async {
    final raw = TransactionalPreferenceString(MenuBarTargetStore.storageKey);
    await raw.save('{"v":1,"categoryId":"c1","subLabel":""}');
    expect((await MenuBarTargetStore().load())?.subLabel, isNull);
  });

  test('存储键名固定', () {
    expect(MenuBarTargetStore.storageKey, 'app_menu_bar_target_v1');
  });
}
