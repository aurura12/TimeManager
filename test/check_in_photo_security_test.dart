import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:time_manager/services/check_in_gitee_service.dart';
import 'package:time_manager/services/check_in_photo_cache.dart';
import 'package:time_manager/services/check_in_photo_resource.dart';

const _validPhotoPath = 'images/乖乖/123.jpg';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory documentsDirectory;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

  setUp(() async {
    documentsDirectory =
        await Directory.systemTemp.createTemp('time_manager_photo_test_');
    messenger.setMockMethodCallHandler(
      pathProviderChannel,
      (call) async => documentsDirectory.path,
    );
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(pathProviderChannel, null);
    if (await documentsDirectory.exists()) {
      await documentsDirectory.delete(recursive: true);
    }
  });

  group('photo path validation', () {
    test(
        'normalizes Windows separators but rejects traversal and absolute paths',
        () {
      expect(
        CheckInPhotoResource.normalizePath(r'images\乖乖\123.jpg'),
        _validPhotoPath,
      );
      expect(
        CheckInPhotoResource.normalizePath('images/乖乖/../123.jpg'),
        isNull,
      );
      expect(
        CheckInPhotoResource.normalizePath(r'..\images\乖乖\123.jpg'),
        isNull,
      );
      expect(
        CheckInPhotoResource.normalizePath(r'C:\Users\alice\123.jpg'),
        isNull,
      );
      expect(
        CheckInPhotoResource.normalizePath(r'\\server\share\123.jpg'),
        isNull,
      );
      expect(
        CheckInPhotoResource.normalizePath('private/乖乖/123.jpg'),
        isNull,
      );
      expect(
        CheckInPhotoResource.normalizePath('images/not-allowed/123.jpg'),
        isNull,
      );
    });
  });

  group('photo payload validation', () {
    final validBytes = Uint8List.fromList(MockClient.pngResponse().bodyBytes);

    test('rejects damaged and over-sized images', () async {
      expect(
        await CheckInPhotoResource.validateBytes(
          Uint8List.fromList([0xff, 0xd8, 0xff, 0xd9]),
        ),
        isNotNull,
      );
      expect(
        await CheckInPhotoResource.validateBytes(
          Uint8List(CheckInPhotoResource.maxPhotoBytes + 1),
        ),
        contains('大小'),
      );
      expect(
        await CheckInPhotoResource.validateBytes(validBytes),
        isNull,
      );
    });

    test('cache accepts a normal image and rejects a path escape', () async {
      final saved = await CheckInPhotoCache.saveBytes(
        _validPhotoPath,
        validBytes,
      );
      expect(saved, isNotNull);
      expect(
        (await CheckInPhotoCache.getCachedFile(_validPhotoPath))?.path,
        saved?.path,
      );

      final escaped = await CheckInPhotoCache.saveBytes(
        r'images\乖乖\..\outside.jpg',
        validBytes,
      );
      expect(escaped, isNull);
      expect(
        await File(p.join(documentsDirectory.path, 'outside.jpg')).exists(),
        isFalse,
      );
    });

    test('cache enforces its total size limit', () async {
      final first = await CheckInPhotoCache.saveBytes(
        _validPhotoPath,
        validBytes,
        maxCacheBytes: validBytes.length,
      );
      expect(first, isNotNull);

      final second = await CheckInPhotoCache.saveBytes(
        'images/乖乖/456.jpg',
        validBytes,
        maxCacheBytes: validBytes.length,
      );
      expect(second, isNull);
    });

    test('does not return a damaged existing cache file', () async {
      final root = Directory(
        p.join(documentsDirectory.path, 'check_in_photos'),
      );
      await root.create(recursive: true);
      final damaged = File(p.join(root.path, 'images__乖乖__damaged.jpg'));
      await damaged.writeAsBytes(<int>[1, 2, 3]);

      expect(
        await CheckInPhotoCache.getCachedFile('images/乖乖/damaged.jpg'),
        isNull,
      );
      expect(await damaged.exists(), isFalse);
    });
  });

  group('remote photo transfer', () {
    final validBytes = Uint8List.fromList(MockClient.pngResponse().bodyBytes);

    test('downloads and validates a normal photo', () async {
      final client = MockClient((request) async {
        expect(request.url.path, contains('/contents/images/'));
        return http.Response(
          jsonEncode({'content': base64Encode(validBytes)}),
          200,
        );
      });
      addTearDown(client.close);

      final result = await CheckInGiteeService.pullBinary(
        token: 'test',
        path: r'images\乖乖\123.jpg',
        client: client,
      );

      expect(result.success, isTrue);
      expect(result.bytes, validBytes);
    });

    test('rejects a damaged remote photo', () async {
      final client = MockClient((_) async {
        return http.Response(
          jsonEncode({
            'content': base64Encode(<int>[1, 2, 3])
          }),
          200,
        );
      });
      addTearDown(client.close);

      final result = await CheckInGiteeService.pullBinary(
        token: 'test',
        path: _validPhotoPath,
        client: client,
      );

      expect(result.success, isFalse);
      expect(result.error, contains('无法解码'));
    });

    test('rejects an over-sized remote response before decoding', () async {
      final client = MockClient((_) async {
        return http.Response.bytes(
          Uint8List(CheckInPhotoResource.maxRemoteResponseBytes + 1),
          200,
        );
      });
      addTearDown(client.close);

      final result = await CheckInGiteeService.pullBinary(
        token: 'test',
        path: _validPhotoPath,
        client: client,
      );

      expect(result.success, isFalse);
      expect(result.error, '远端图片响应过大');
    });

    test('does not request an unsafe remote path', () async {
      var requested = false;
      final client = MockClient((_) async {
        requested = true;
        return http.Response('{}', 200);
      });
      addTearDown(client.close);

      final result = await CheckInGiteeService.pullBinary(
        token: 'test',
        path: r'C:\outside\photo.jpg',
        client: client,
      );

      expect(result.success, isFalse);
      expect(result.error, '照片路径无效');
      expect(requested, isFalse);
    });

    test('does not delete an unsafe remote path', () async {
      var requested = false;
      final client = MockClient((_) async {
        requested = true;
        return http.Response('{}', 200);
      });
      addTearDown(client.close);

      final result = await CheckInGiteeService.deleteFile(
        token: 'test',
        path: r'..\outside\photo.jpg',
        commitMessage: 'test',
        client: client,
      );

      expect(result.success, isFalse);
      expect(result.error, '照片路径无效');
      expect(requested, isFalse);
    });

    test('uploads a normal photo through the normalized path', () async {
      final client = MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, contains('/contents/images/'));
        return http.Response(
            jsonEncode({
              'content': {'sha': 'new-sha'}
            }),
            201);
      });
      addTearDown(client.close);

      final result = await CheckInGiteeService.pushBinary(
        token: 'test',
        path: r'images\乖乖\123.jpg',
        bytes: validBytes,
        commitMessage: 'test',
        skipGetSha: true,
        client: client,
      );

      expect(result.success, isTrue);
      expect(result.created, isTrue);
    });
  });
}
