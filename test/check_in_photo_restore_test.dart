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
import 'package:time_manager/models/check_in_record.dart';
import 'package:time_manager/services/app_identity_service.dart';
import 'package:time_manager/services/check_in_gitee_service.dart';
import 'package:time_manager/services/check_in_local_store.dart';
import 'package:time_manager/services/check_in_photo_cache.dart';
import 'package:time_manager/services/check_in_sync_service.dart';

const _photoPath = 'images/乖乖/123.jpg';

CheckInGoal _goal() {
  return CheckInGoal(
    id: 'goal-1',
    ownerId: 'uid-j',
    ownerEmail: 'j@example.com',
    ownerDisplayName: '晶晶',
    name: '早起',
    description: '',
    color: const Color(0xFF4CAF50),
    icon: Icons.flag,
    period: CheckInPeriod.daily,
    targetCount: 1,
  );
}

CheckInRecord _record({String? photoPath}) {
  return CheckInRecord(
    id: 'record-1',
    goalId: 'goal-1',
    userId: 'uid-j',
    userEmail: 'j@example.com',
    timestamp: DateTime(2026, 10, 1, 8),
    photoPath: photoPath,
    note: '晨跑',
  );
}

/// 远端文档：记录已被墓碑删除（撤销前的状态）。
CheckInDocument _remoteDocumentWithTombstone() {
  return CheckInDocument(
    goals: [_goal()],
    records: const [],
    deletedRecordIds: {'record-1'},
  );
}

/// 请求路径按段拼回来才是解码后的（照片名里有中文）。
String _pathOf(http.Request request) => request.url.pathSegments.join('/');

CheckInDocument _documentFromPushBody(http.Request request) {
  final body = json.decode(request.body) as Map<String, dynamic>;
  final content = utf8.decode(base64Decode(body['content'] as String));
  return CheckInDocument.fromMarkdown(content);
}

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
        await Directory.systemTemp.createTemp('time_manager_restore_test_');
    messenger.setMockMethodCallHandler(
      pathProviderChannel,
      (call) async => documentsDirectory.path,
    );

    // 本地是「刚删完」的状态：记录已被墓碑标记，远端也已收到这份墓碑。
    await CheckInLocalStore.saveDraft(_remoteDocumentWithTombstone());
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

  test('撤销删除会把照片重传并把记录放回远端文档', () async {
    final photoBytes = Uint8List.fromList(MockClient.pngResponse().bodyBytes);
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      final path = _pathOf(request);
      if (request.method == 'GET' && path.endsWith(CheckInDocument.filePath)) {
        return http.Response(
          jsonEncode({
            'content': base64Encode(
                utf8.encode(_remoteDocumentWithTombstone().toMarkdown())),
            'sha': 'doc-sha',
          }),
          200,
        );
      }
      if (path.endsWith(_photoPath)) {
        // skipGetSha 走 POST 新建；同字节覆盖无害。
        return http.Response('{"content":{"sha":"photo-sha"}}', 201);
      }
      if (request.method == 'PUT' && path.endsWith(CheckInDocument.filePath)) {
        return http.Response('{"content":{"sha":"new-doc-sha"}}', 200);
      }
      fail('未预期的请求: ${request.method} ${request.url}');
    });
    CheckInGiteeService.useClientForTesting(client);

    final service = CheckInSyncService(tokenLoader: () async => 'token');
    await service.reloadLocal();
    final result = await service.restoreCheckInRecord(
      goal: _goal(),
      record: _record(photoPath: _photoPath),
      photoBytes: photoBytes,
    );

    expect(result.success, isTrue, reason: result.error);
    // 照片预取到字节时必须真的重传：一次拉文档、一次传照片、一次推文档。
    expect(requests.map((r) => r.method), ['GET', 'POST', 'PUT']);
    expect(_pathOf(requests[0]),
        endsWith('/contents/${CheckInDocument.filePath}'));
    expect(_pathOf(requests[1]), endsWith('/contents/$_photoPath'));
    expect(_pathOf(requests[2]),
        endsWith('/contents/${CheckInDocument.filePath}'));
    expect(json.decode(requests[1].body)['content'], base64Encode(photoBytes));

    // 推送出去的文档里记录复活、墓碑被清除。
    final pushed = _documentFromPushBody(requests.last);
    final restored = pushed.records.singleWhere((r) => r.id == 'record-1');
    expect(restored.photoPath, _photoPath);
    expect(pushed.deletedRecordIds, isEmpty);

    // 本地也回到「已恢复」状态，照片进了缓存（缩略图能直接显示）。
    final local = await CheckInLocalStore.loadDraft();
    expect(local!.records.singleWhere((r) => r.id == 'record-1').photoPath,
        _photoPath);
    expect(await CheckInPhotoCache.getCachedFile(_photoPath), isNotNull);
  });

  test('照片字节取不到时不重传照片，恢复出来的记录不带照片', () async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      final path = _pathOf(request);
      if (request.method == 'GET' && path.endsWith(CheckInDocument.filePath)) {
        return http.Response(
          jsonEncode({
            'content': base64Encode(
                utf8.encode(_remoteDocumentWithTombstone().toMarkdown())),
            'sha': 'doc-sha',
          }),
          200,
        );
      }
      if (request.method == 'PUT' && path.endsWith(CheckInDocument.filePath)) {
        return http.Response('{"content":{"sha":"new-doc-sha"}}', 200);
      }
      fail('未预期的请求: ${request.method} ${request.url}');
    });
    CheckInGiteeService.useClientForTesting(client);

    final service = CheckInSyncService(tokenLoader: () async => 'token');
    await service.reloadLocal();
    final result = await service.restoreCheckInRecord(
      goal: _goal(),
      record: _record(photoPath: _photoPath),
    );

    expect(result.success, isTrue, reason: result.error);
    // 没有照片可传时不能发出照片请求，也不能留下指向坏引用的 photoPath。
    expect(requests, hasLength(2));
    final restored = _documentFromPushBody(requests.last)
        .records
        .singleWhere((r) => r.id == 'record-1');
    expect(restored.photoPath, isNull);
    expect(restored.note, '晨跑');
  });
}
