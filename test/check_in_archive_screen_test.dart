import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/models/check_in_document.dart';
import 'package:time_manager/models/check_in_goal.dart';
import 'package:time_manager/models/known_google_users.dart';
import 'package:time_manager/screens/check_in_archive_screen.dart';
import 'package:time_manager/services/app_identity_service.dart';
import 'package:time_manager/services/check_in_gitee_service.dart';
import 'package:time_manager/services/check_in_local_store.dart';
import 'package:time_manager/services/check_in_sync_service.dart';

CheckInGoal _archivedGoal() {
  return CheckInGoal(
    id: 'goal-1',
    ownerId: 'manual-j',
    ownerEmail: KnownGoogleUsers.jingJingEmail,
    ownerDisplayName: '晶晶',
    name: '早起',
    description: '',
    color: const Color(0xFF4CAF50),
    icon: Icons.flag,
    period: CheckInPeriod.daily,
    targetCount: 1,
    isArchived: true,
    archivedAt: DateTime(2026, 10, 20),
  );
}

CheckInDocument _archivedDocument() => CheckInDocument(
      goals: [_archivedGoal()],
      records: const [],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorage =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Directory documentsDirectory;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      AppIdentityService.modeKey: 'manual',
      AppIdentityService.legacyScheduleUserKey: 'j',
    });
    AppIdentityService.resetForTesting();
    messenger.setMockMethodCallHandler(secureStorage, (call) async => null);
    documentsDirectory =
        await Directory.systemTemp.createTemp('time_manager_archive_test_');
    messenger.setMockMethodCallHandler(
      pathProviderChannel,
      (call) async => documentsDirectory.path,
    );
    await CheckInLocalStore.saveDraft(_archivedDocument());
  });

  tearDown(() async {
    CheckInGiteeService.useClientForTesting(null);
    AppIdentityService.resetForTesting();
    messenger.setMockMethodCallHandler(secureStorage, null);
    messenger.setMockMethodCallHandler(pathProviderChannel, null);
    if (await documentsDirectory.exists()) {
      await documentsDirectory.delete(recursive: true);
    }
  });

  testWidgets('恢复归档目标不再弹确认，点了就生效', (tester) async {
    final document = _archivedDocument();
    CheckInGiteeService.useClientForTesting(MockClient((request) async {
      final path = request.url.pathSegments.join('/');
      if (request.method == 'GET' && path.endsWith(CheckInDocument.filePath)) {
        return http.Response(
          jsonEncode({
            'content': base64Encode(utf8.encode(document.toMarkdown())),
            'sha': 'doc-sha',
          }),
          200,
        );
      }
      if (request.method == 'PUT' && path.endsWith(CheckInDocument.filePath)) {
        return http.Response('{"content":{"sha":"new-doc-sha"}}', 200);
      }
      fail('未预期的请求: ${request.method} ${request.url}');
    }));

    final service = CheckInSyncService(tokenLoader: () async => 'token');
    await service.reloadLocal();

    await tester.pumpWidget(
      MaterialApp(home: CheckInArchiveScreen(syncService: service)),
    );
    await tester.pumpAndSettle();
    expect(find.text('早起'), findsOneWidget);

    await tester.tap(find.byTooltip('恢复'));
    await tester.pumpAndSettle();

    // 恢复是可逆的元数据切换：不再弹确认框，点了就直接生效。
    expect(find.byType(AlertDialog), findsNothing);
    expect(service.goalsWithRecords.single.isArchived, isFalse);
    expect(find.text('已恢复「早起」'), findsOneWidget);
  });
}
