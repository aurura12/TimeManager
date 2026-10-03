import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/providers/theme_mode_provider.dart';
import 'package:time_manager/theme/app_semantic_colors.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('旧用户保留系统外观模式和默认绿', () async {
    final provider = ThemeModeProvider();
    addTearDown(provider.dispose);
    await provider.ready;

    expect(provider.themeMode, ThemeMode.system);
    expect(provider.themeColor, AppSemanticColors.brand);
  });

  test('主题色保存后重建 Provider，外观模式保持原选择', () async {
    final provider = ThemeModeProvider();
    addTearDown(provider.dispose);
    await provider.setThemeMode(ThemeMode.dark);
    await provider.setThemeColor(AppSemanticColors.lavender);

    final restored = ThemeModeProvider();
    addTearDown(restored.dispose);
    await restored.ready;
    expect(restored.themeMode, ThemeMode.dark);
    expect(restored.themeColor, AppSemanticColors.lavender);

    await restored.setThemeColor(AppSemanticColors.brand);
    final defaults = ThemeModeProvider();
    addTearDown(defaults.dispose);
    await defaults.ready;
    expect(defaults.themeColor, AppSemanticColors.brand);
    expect(defaults.themeMode, ThemeMode.dark);
  });

  test('历史半透明色和自定义颜色在读写入口统一不透明', () async {
    SharedPreferences.setMockInitialValues({
      ThemeModeProvider.themeColorStorageKey: 0x804DA8EE,
    });
    final provider = ThemeModeProvider();
    addTearDown(provider.dispose);
    await provider.ready;
    expect(provider.themeColor, AppSemanticColors.identityGuaiGuai);

    await provider.setThemeColor(const Color(0x12345678));
    expect(provider.themeColor, const Color(0xFF345678));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt(ThemeModeProvider.themeColorStorageKey), 0xFF345678);
  });

  test('损坏或越界的偏好不会阻止初始化', () async {
    for (final invalid in ['invalid', -1, 1 << 32]) {
      SharedPreferences.setMockInitialValues({
        'app_theme_mode': 42,
        ThemeModeProvider.themeColorStorageKey: invalid,
      });
      final provider = ThemeModeProvider();
      await provider.ready;
      expect(provider.themeColor, AppSemanticColors.brand);
      expect(provider.themeMode, ThemeMode.system);
      provider.dispose();
    }
  });

  test('启动读盘尚未完成时应用默认绿，不会被旧偏好覆盖', () async {
    SharedPreferences.setMockInitialValues({
      ThemeModeProvider.themeColorStorageKey:
          AppSemanticColors.lavender.toARGB32(),
    });
    final preferences = Completer<SharedPreferences>();
    final provider = ThemeModeProvider(
      preferencesLoader: () => preferences.future,
    );
    addTearDown(provider.dispose);
    final selection = provider.setThemeColor(AppSemanticColors.brand);

    preferences.complete(await SharedPreferences.getInstance());
    await selection;
    expect(provider.themeColor, AppSemanticColors.brand);
    final restored = ThemeModeProvider();
    addTearDown(restored.dispose);
    await restored.ready;
    expect(restored.themeColor, AppSemanticColors.brand);
  });

  test('初始化期间退出不会向已销毁的 Provider 发通知', () async {
    final preferences = Completer<SharedPreferences>();
    final provider = ThemeModeProvider(
      preferencesLoader: () => preferences.future,
    );
    provider.dispose();
    preferences.complete(await SharedPreferences.getInstance());
    await expectLater(provider.ready, completes);
  });
}
