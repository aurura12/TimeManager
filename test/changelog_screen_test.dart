import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:time_manager/screens/changelog_screen.dart';
import 'package:time_manager/theme/app_theme.dart';

const String _sample = '''
## 1.2.0+3（2026-05-28）

- 新功能。

## 1.1.0+2（2026-05-20）

- 旧修复。
''';

Future<void> _pumpScreen(
  WidgetTester tester, {
  Future<String> Function()? loader,
  bool readAsset = false,
  String? currentVersion,
  double textScale = 1.0,
  Size size = const Size(400, 800),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: MediaQuery.withClampedTextScaling(
        minScaleFactor: textScale,
        maxScaleFactor: textScale,
        child: ChangelogScreen(
          contentLoader: readAsset ? null : (loader ?? () async => _sample),
          currentVersionLabel: currentVersion,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders versions in file order and marks the current one',
      (tester) async {
    await _pumpScreen(tester, currentVersion: '1.2.0+3');

    expect(find.text('1.2.0'), findsOneWidget);
    expect(find.text('1.1.0'), findsOneWidget);
    expect(find.text('当前版本'), findsOneWidget);
    expect(find.text('新功能。'), findsOneWidget);
    expect(find.text('旧修复。'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('1.2.0')).dy,
      lessThan(tester.getTopLeft(find.text('1.1.0')).dy),
    );
  });

  testWidgets('shows error and retries', (tester) async {
    var calls = 0;
    await _pumpScreen(
      tester,
      loader: () async {
        calls++;
        if (calls == 1) throw Exception('boom');
        return _sample;
      },
    );

    expect(find.text('更新日志加载失败'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    expect(find.text('更新日志加载失败'), findsNothing);
    expect(find.text('新功能。'), findsOneWidget);
    expect(calls, 2);
  });

  testWidgets('shows empty state', (tester) async {
    await _pumpScreen(tester, loader: () async => '');

    expect(find.text('暂无更新日志'), findsOneWidget);
  });

  testWidgets('reads the bundled asset when no loader is injected',
      (tester) async {
    await _pumpScreen(tester, readAsset: true, currentVersion: '1.178.0+2067');

    // 更新日志会随版本继续变长，1.178.0 不一定落在首屏，先滚动到它再断言。
    await tester.scrollUntilVisible(find.text('1.178.0'), 400);
    expect(find.text('1.178.0'), findsOneWidget);
    expect(find.text('当前版本'), findsOneWidget);
  });

  testWidgets('scrolls through a long changelog', (tester) async {
    final buffer = StringBuffer();
    for (var i = 30; i >= 1; i--) {
      buffer.write('## 1.$i.0+$i（2026-01-${i.toString().padLeft(2, '0')}）\n\n');
      buffer.write('- 第 $i 版的内容。\n\n');
    }
    await _pumpScreen(tester, loader: () async => buffer.toString());

    await tester.scrollUntilVisible(find.text('1.1.0'), 400);
    expect(find.text('1.1.0'), findsOneWidget);
  });

  testWidgets('supports large text on a narrow screen', (tester) async {
    await _pumpScreen(
      tester,
      currentVersion: '1.2.0+3',
      textScale: 2.0,
      size: const Size(320, 720),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('新功能。'), findsOneWidget);
  });
}
