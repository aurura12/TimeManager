import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_manager/models/diary_conflict.dart';
import 'package:time_manager/models/diary_kind.dart';
import 'package:time_manager/screens/diary_conflict_screen.dart';
import 'package:time_manager/theme/app_theme.dart';

Future<ValueNotifier<DiaryConflictDecision?>> _open(
  WidgetTester tester, {
  required String local,
  required String remote,
}) async {
  final result = ValueNotifier<DiaryConflictDecision?>(null);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () async {
                result.value =
                    await Navigator.of(context).push<DiaryConflictDecision>(
                  MaterialPageRoute(
                    builder: (_) => DiaryConflictScreen(
                      kind: DiaryKind.g,
                      date: DateTime(2026, 3, 5),
                      localBody: local,
                      remoteBody: remote,
                      remoteSha: 'abcdef1234567890',
                    ),
                  ),
                );
              },
              child: const Text('打开冲突页'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开冲突页'));
  await tester.pumpAndSettle();
  return result;
}

void main() {
  testWidgets('展示两侧差异与逐块选择', (tester) async {
    await _open(tester, local: '第一行\n本地新增', remote: '第一行\n远端新增');

    expect(find.text('处理冲突'), findsOneWidget);
    expect(find.text('本地'), findsOneWidget);
    expect(find.text('远端'), findsOneWidget);
    expect(find.text('用本地'), findsOneWidget);
    expect(find.text('用远端'), findsOneWidget);
    expect(find.text('两边都留'), findsOneWidget);
    expect(find.text('用远端覆盖本地'), findsOneWidget);
    expect(find.text('用本地覆盖远端'), findsOneWidget);
    expect(find.text('合并并上传'), findsOneWidget);
  });

  testWidgets('选择用远端覆盖会二次确认并返回 decision', (tester) async {
    final result = await _open(
      tester,
      local: '本地内容',
      remote: '远端内容',
    );

    await tester.tap(find.text('用远端覆盖本地'));
    await tester.pumpAndSettle();
    expect(find.text('用远端覆盖'), findsOneWidget);

    await tester.tap(find.text('用远端覆盖'));
    await tester.pumpAndSettle();

    expect(result.value, isA<DiaryUseRemote>());
  });

  testWidgets('取消二次确认时停留原页', (tester) async {
    final result = await _open(
      tester,
      local: '本地内容',
      remote: '远端内容',
    );

    await tester.tap(find.text('用本地覆盖远端'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(result.value, isNull);
    expect(find.text('处理冲突'), findsOneWidget);
  });

  testWidgets('合并并上传默认保留两边，可进入编辑并保存', (tester) async {
    final result = await _open(
      tester,
      local: '第一行\n本地新增',
      remote: '第一行\n远端新增',
    );

    await tester.tap(find.text('合并并上传'));
    await tester.pumpAndSettle();

    expect(find.text('合并编辑'), findsOneWidget);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller?.text, '第一行\n本地新增\n远端新增');

    await tester.enterText(find.byType(TextField), '手动合并后的内容');
    await tester.tap(find.text('保存合并结果'));
    await tester.pumpAndSettle();

    expect(result.value, isA<DiaryUseMerged>());
    expect((result.value as DiaryUseMerged).body, '手动合并后的内容');
  });

  testWidgets('把差异块改成用远端后，合并结果采用远端内容', (tester) async {
    final result = await _open(
      tester,
      local: '第一行\n本地新增',
      remote: '第一行\n远端新增',
    );

    await tester.tap(find.text('用远端'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('合并并上传'));
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller?.text, '第一行\n远端新增');

    await tester.tap(find.text('保存合并结果'));
    await tester.pumpAndSettle();
    expect((result.value as DiaryUseMerged).body, '第一行\n远端新增');
  });

  testWidgets('正文一致时提示无需处理', (tester) async {
    await _open(tester, local: '相同内容', remote: '相同内容');
    expect(find.text('本地与远端正文一致，无需处理。'), findsOneWidget);
  });
}
