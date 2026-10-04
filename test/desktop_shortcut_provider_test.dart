import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:time_manager/models/desktop_shortcut.dart';
import 'package:time_manager/providers/desktop_shortcut_provider.dart';

import 'support/fake_main_tab_preferences_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('重绑和停用持久化；身份切换不会更改快捷键', () async {
    final provider = DesktopShortcutProvider();
    addTearDown(provider.dispose);
    await provider.ready;
    final bindings = Map.of(provider.bindings);
    bindings[DesktopShortcutActionType.openSearch] = const DesktopKeyBinding(
        LogicalKeyboardKey.keyP,
        primary: true,
        shift: true);
    bindings[DesktopShortcutActionType.redo] = null;
    await provider.save(bindings);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('schedule_user_kind', 'j');
    final restored = DesktopShortcutProvider();
    addTearDown(restored.dispose);
    await restored.ready;
    expect(restored.bindings, bindings);
    expect(() => restored.bindings.clear(), throwsUnsupportedError);
    expect(
        prefs.getKeys().where((key) => key.startsWith('identity_')), isEmpty);
    await provider.save(defaultDesktopBindings());
    expect(provider.bindings, defaultDesktopBindings());
  });

  test('冲突、文字编辑保留键、系统按键与裸字母不能保存', () async {
    final provider = DesktopShortcutProvider();
    addTearDown(provider.dispose);
    await provider.ready;
    for (final binding in [
      const DesktopKeyBinding(LogicalKeyboardKey.keyK, primary: true),
      const DesktopKeyBinding(LogicalKeyboardKey.keyC, primary: true),
      const DesktopKeyBinding(LogicalKeyboardKey.keyY, primary: true),
      const DesktopKeyBinding(LogicalKeyboardKey.f4, alt: true),
      const DesktopKeyBinding(LogicalKeyboardKey.keyP),
    ]) {
      final invalid = Map.of(provider.bindings);
      invalid[DesktopShortcutActionType.newItem] = binding;
      expect(() => provider.save(invalid), throwsArgumentError);
    }
    expect(provider.bindings, defaultDesktopBindings());
  });

  test('损坏、冲突的偏好恢复默认，缺项兼容新增命令', () async {
    for (final raw in [
      '{broken',
      jsonEncode({
        'openSearch':
            const DesktopKeyBinding(LogicalKeyboardKey.keyF, primary: true)
                .toJson(),
      }),
      jsonEncode({
        'newItem': {'key': -1}
      })
    ]) {
      SharedPreferences.setMockInitialValues(
          {DesktopShortcutProvider.storageKey: raw});
      final provider = DesktopShortcutProvider();
      await provider.ready;
      expect(provider.bindings, defaultDesktopBindings());
      provider.dispose();
    }
    SharedPreferences.setMockInitialValues({
      DesktopShortcutProvider.storageKey:
          jsonEncode({'newItem': null, 'futureCommand': null})
    });
    final provider = DesktopShortcutProvider();
    addTearDown(provider.dispose);
    await provider.ready;
    expect(provider.bindings[DesktopShortcutActionType.newItem], isNull);
    expect(provider.bindings[DesktopShortcutActionType.saveForm],
        defaultDesktopBindings()[DesktopShortcutActionType.saveForm]);
  });

  test('写盘失败保留原设置，重建不会读取失败的缓存，重试可成功', () async {
    final original = SharedPreferencesStorePlatform.instance;
    final store = FakeMainTabPreferencesStore(rejectWrites: true);
    SharedPreferencesStorePlatform.instance = store;
    addTearDown(() => SharedPreferencesStorePlatform.instance = original);
    final provider = DesktopShortcutProvider();
    addTearDown(provider.dispose);
    await provider.ready;
    final changed = Map.of(provider.bindings)
      ..[DesktopShortcutActionType.redo] = null;
    await expectLater(provider.save(changed), throwsStateError);
    expect(provider.bindings, defaultDesktopBindings());
    final restored = DesktopShortcutProvider();
    addTearDown(restored.dispose);
    await restored.ready;
    expect(restored.bindings, defaultDesktopBindings());
    store.rejectWrites = false;
    await provider.save(changed);
    expect(provider.bindings, changed);
  });
}
