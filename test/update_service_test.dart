import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:time_manager/config/remote_repo_config.dart';
import 'package:time_manager/services/update_service.dart';

class _FakeResponse {
  final int statusCode;
  final List<List<int>> chunks;
  final Map<String, String> headers;
  final int? contentLength;

  const _FakeResponse({
    required this.statusCode,
    this.chunks = const <List<int>>[],
    this.headers = const <String, String>{},
    this.contentLength,
  });
}

class _FakeClient extends http.BaseClient {
  final List<_FakeResponse> responses;
  int requestCount = 0;
  Uri? lastUri;
  final List<Map<String, String>> requestHeaders = [];

  _FakeClient(this.responses);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    lastUri = request.url;
    requestHeaders.add(Map<String, String>.from(request.headers));
    final response = responses[requestCount++];
    return http.StreamedResponse(
      Stream<List<int>>.fromIterable(response.chunks),
      response.statusCode,
      headers: response.headers,
      contentLength: response.contentLength,
      request: request,
    );
  }
}

void main() {
  late Directory tempDirectory;

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp('update_service_');
  });

  tearDown(() async {
    if (await tempDirectory.exists()) {
      await tempDirectory.delete(recursive: true);
    }
  });

  test('only accepts safe versions and configured HTTPS asset paths', () {
    expect(UpdateService.isSafeVersionForTesting('v1.95.0+10'), isTrue);
    expect(UpdateService.isSafeVersionForTesting('1.95.0-beta.1'), isTrue);
    expect(UpdateService.isSafeVersionForTesting('1.95.0/../../x'), isFalse);
    expect(UpdateService.isSafeVersionForTesting('1.95.0.exe'), isFalse);

    final attachUrl =
        'https://gitee.com/${RemoteRepoConfig.giteeOwner}/time_manager_releases/attach_files/123/app.apk';
    final apiUrl =
        'https://gitee.com/api/v5/repos/${RemoteRepoConfig.giteeOwner}/time_manager_releases/releases/assets/123';
    expect(UpdateService.isAllowedDownloadUrlForTesting(attachUrl), isTrue);
    expect(UpdateService.isAllowedDownloadUrlForTesting(apiUrl), isTrue);
    expect(
      UpdateService.isAllowedDownloadUrlForTesting(
        attachUrl.replaceFirst('https://', 'http://'),
      ),
      isFalse,
    );
    expect(
      UpdateService.isAllowedDownloadUrlForTesting(
        attachUrl.replaceFirst('gitee.com', 'example.com'),
      ),
      isFalse,
    );
    expect(
      UpdateService.isAllowedDownloadUrlForTesting(
        'https://gitee.com/${RemoteRepoConfig.giteeOwner}/other_repo/attach_files/123/app.apk',
      ),
      isFalse,
    );
    expect(
      UpdateService.isAllowedDownloadUrlForTesting(
        'https://foruda.gitee.com/attach_file/123/app.apk?token=test&ts=123',
      ),
      isFalse,
    );
  });

  test('accepts only explicit SHA-256 metadata', () {
    const digest =
        '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824';

    expect(
      UpdateService.extractSha256ForTesting({'sha256': digest.toUpperCase()}),
      digest,
    );
    expect(
      UpdateService.extractSha256ForTesting({'digest': 'sha256:$digest'}),
      digest,
    );
    expect(
      UpdateService.extractSha256ForTesting({'checksum': 'md5:0123456789'}),
      isNull,
    );
    expect(UpdateService.extractSha256ForTesting({}), isNull);
  });

  test('parses only a checksum manifest that names the exact installer', () {
    const digest =
        '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824';
    const assetName = 'time_manager_v1.96.0.apk';

    expect(
      UpdateService.parseSha256ManifestForTesting(
        '$digest  $assetName\n',
        assetName,
      ),
      digest,
    );
    expect(
      UpdateService.parseSha256ManifestForTesting(
        '$digest *$assetName\n',
        assetName,
      ),
      digest,
    );
    expect(
      UpdateService.parseSha256ManifestForTesting(
        '$digest  another.apk\n',
        assetName,
      ),
      isNull,
    );
    expect(
      UpdateService.parseSha256ManifestForTesting(
        '$digest  $assetName\n$digest  extra.apk\n',
        assetName,
      ),
      isNull,
    );
    expect(
      UpdateService.parseSha256ManifestForTesting(
        'not-a-digest  $assetName\n',
        assetName,
      ),
      isNull,
    );
  });

  test('fetches a trusted checksum sidecar with a bounded response', () async {
    const digest =
        '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824';
    const assetName = 'time_manager_v1.96.0.apk';
    final client = _FakeClient([
      _FakeResponse(
        statusCode: HttpStatus.ok,
        chunks: [utf8.encode('$digest  $assetName\n')],
      ),
    ]);

    final result = await UpdateService.fetchSha256ManifestForTesting(
      client: client,
      uri: Uri.parse(
        'https://gitee.com/${RemoteRepoConfig.giteeOwner}/time_manager_releases/attach_files/123/$assetName.sha256',
      ),
      expectedAssetName: assetName,
    );

    expect(result, digest);
    expect(client.requestCount, 1);
  });

  test('keeps prerelease identifiers when normalizing versions', () {
    expect(
      UpdateService.normalizeVersionForTesting('v1.96.0-beta.1+12'),
      '1.96.0-beta.1',
    );
  });

  test('compares beta and prerelease versions using SemVer precedence', () {
    int compare(String left, String right) =>
        UpdateService.compareVersionsForTesting(left, right);

    expect(compare('1.96.0-beta.1', '1.96.0-beta.2'), lessThan(0));
    expect(compare('1.96.0-beta.2', '1.96.0-beta.10'), lessThan(0));
    expect(compare('1.96.0-alpha', '1.96.0-beta.1'), lessThan(0));
    expect(compare('1.96.0-rc.1', '1.96.0'), lessThan(0));
    expect(compare('1.96.0', '1.96.0-beta.9'), greaterThan(0));
    expect(compare('1.96.0+1', 'v1.96.0+2'), 0);
    expect(compare('1.97.0-beta.1', '1.96.9'), greaterThan(0));
  });

  test('marks an update without a digest as manual-download only', () {
    const info = UpdateInfo(
      version: '1.96.0',
      downloadUrl:
          'https://gitee.com/example/time_manager_releases/releases/download/1.96.0/app.apk',
      releaseNotes: '',
    );
    expect(info.canAutoInstall, isFalse);
  });

  test('downloads, hashes, and writes a verified file', () async {
    final body = utf8.encode('hello');
    final digest = sha256.convert(body).toString();
    final destination = File(p.join(tempDirectory.path, 'installer.apk'));
    final client = _FakeClient([
      _FakeResponse(
        statusCode: HttpStatus.ok,
        chunks: [body.sublist(0, 2), body.sublist(2)],
        contentLength: body.length,
      ),
    ]);

    await UpdateService.downloadVerifiedFileForTesting(
      client: client,
      uri: Uri.parse(
        'https://gitee.com/${RemoteRepoConfig.giteeOwner}/time_manager_releases/attach_files/123/app.apk',
      ),
      destination: destination,
      expectedSha256: digest,
      maxBytes: 64,
    );

    expect(await destination.readAsString(), 'hello');
    expect(client.requestCount, 1);
  });

  test('deletes the temporary file when checksum verification fails', () async {
    final destination = File(p.join(tempDirectory.path, 'installer.apk'));
    final client = _FakeClient([
      _FakeResponse(
        statusCode: HttpStatus.ok,
        chunks: [utf8.encode('tampered')],
        contentLength: 8,
      ),
    ]);

    await expectLater(
      UpdateService.downloadVerifiedFileForTesting(
        client: client,
        uri: Uri.parse(
          'https://gitee.com/${RemoteRepoConfig.giteeOwner}/time_manager_releases/attach_files/123/app.apk',
        ),
        destination: destination,
        expectedSha256:
            '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824',
        maxBytes: 64,
      ),
      throwsA(isA<Exception>()),
    );
    expect(await destination.exists(), isFalse);
  });

  test('does not request or keep a file when no digest is available', () async {
    final destination = File(p.join(tempDirectory.path, 'installer.apk'));
    final client = _FakeClient(const <_FakeResponse>[]);

    await expectLater(
      UpdateService.downloadVerifiedFileForTesting(
        client: client,
        uri: Uri.parse(
          'https://gitee.com/${RemoteRepoConfig.giteeOwner}/time_manager_releases/attach_files/123/app.apk',
        ),
        destination: destination,
        expectedSha256: null,
        maxBytes: 64,
      ),
      throwsA(isA<Exception>()),
    );
    expect(client.requestCount, 0);
    expect(await destination.exists(), isFalse);
  });

  test('deletes the temporary file after an HTTP download failure', () async {
    final destination = File(p.join(tempDirectory.path, 'installer.apk'));
    await destination.writeAsString('stale installer');
    final client = _FakeClient([
      const _FakeResponse(
        statusCode: HttpStatus.serviceUnavailable,
        chunks: [
          <int>[1, 2, 3]
        ],
        contentLength: 3,
      ),
    ]);

    await expectLater(
      UpdateService.downloadVerifiedFileForTesting(
        client: client,
        uri: Uri.parse(
          'https://gitee.com/${RemoteRepoConfig.giteeOwner}/time_manager_releases/attach_files/123/app.apk',
        ),
        destination: destination,
        expectedSha256:
            '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824',
        maxBytes: 64,
      ),
      throwsA(isA<Exception>()),
    );
    expect(await destination.exists(), isFalse);
  });

  test('rejects both advertised and streamed responses over the limit',
      () async {
    final advertisedDestination =
        File(p.join(tempDirectory.path, 'advertised.apk'));
    final advertisedClient = _FakeClient([
      _FakeResponse(
        statusCode: HttpStatus.ok,
        chunks: [utf8.encode('1234')],
        contentLength: 4,
      ),
    ]);

    await expectLater(
      UpdateService.downloadVerifiedFileForTesting(
        client: advertisedClient,
        uri: Uri.parse(
          'https://gitee.com/${RemoteRepoConfig.giteeOwner}/time_manager_releases/attach_files/123/app.apk',
        ),
        destination: advertisedDestination,
        expectedSha256: sha256.convert(utf8.encode('1234')).toString(),
        maxBytes: 3,
      ),
      throwsA(isA<Exception>()),
    );
    expect(await advertisedDestination.exists(), isFalse);

    final streamedDestination =
        File(p.join(tempDirectory.path, 'streamed.apk'));
    final streamedClient = _FakeClient([
      _FakeResponse(
        statusCode: HttpStatus.ok,
        chunks: [utf8.encode('12'), utf8.encode('34')],
        contentLength: null,
      ),
    ]);

    await expectLater(
      UpdateService.downloadVerifiedFileForTesting(
        client: streamedClient,
        uri: Uri.parse(
          'https://gitee.com/${RemoteRepoConfig.giteeOwner}/time_manager_releases/attach_files/123/app.apk',
        ),
        destination: streamedDestination,
        expectedSha256: sha256.convert(utf8.encode('1234')).toString(),
        maxBytes: 3,
      ),
      throwsA(isA<Exception>()),
    );
    expect(await streamedDestination.exists(), isFalse);
  });

  test('rejects a redirect to an untrusted host before downloading', () async {
    final destination = File(p.join(tempDirectory.path, 'installer.apk'));
    final client = _FakeClient([
      const _FakeResponse(
        statusCode: HttpStatus.found,
        headers: {'location': 'https://example.com/malicious.apk'},
      ),
    ]);

    await expectLater(
      UpdateService.downloadVerifiedFileForTesting(
        client: client,
        uri: Uri.parse(
          'https://gitee.com/${RemoteRepoConfig.giteeOwner}/time_manager_releases/attach_files/123/app.apk',
        ),
        destination: destination,
        expectedSha256:
            '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824',
        maxBytes: 64,
      ),
      throwsA(isA<Exception>()),
    );
    expect(client.requestCount, 1);
    expect(await destination.exists(), isFalse);
  });

  test('follows only an allowed redirect and verifies the final response',
      () async {
    final body = utf8.encode('hello');
    final digest = sha256.convert(body).toString();
    final destination = File(p.join(tempDirectory.path, 'installer.apk'));
    final client = _FakeClient([
      const _FakeResponse(
        statusCode: HttpStatus.found,
        headers: {
          'location':
              'https://gitee.com/${RemoteRepoConfig.giteeOwner}/time_manager_releases/attach_files/123/app.apk',
        },
      ),
      _FakeResponse(
        statusCode: HttpStatus.ok,
        chunks: [body],
        contentLength: body.length,
      ),
    ]);

    await UpdateService.downloadVerifiedFileForTesting(
      client: client,
      uri: Uri.parse(
        'https://gitee.com/${RemoteRepoConfig.giteeOwner}/time_manager_releases/attach_files/123/app.apk',
      ),
      destination: destination,
      expectedSha256: digest,
      maxBytes: 64,
    );

    expect(client.requestCount, 2);
    expect(await destination.readAsString(), 'hello');
  });

  test('follows Gitee attachment CDN redirects without forwarding auth',
      () async {
    final body = utf8.encode('hello');
    final digest = sha256.convert(body).toString();
    final destination = File(p.join(tempDirectory.path, 'installer.apk'));
    final client = _FakeClient([
      const _FakeResponse(
        statusCode: HttpStatus.found,
        headers: {
          'location':
              'https://foruda.gitee.com/attach_file/123/app.apk?token=test&ts=123&attname=app.apk',
        },
      ),
      _FakeResponse(
        statusCode: HttpStatus.ok,
        chunks: [body],
        contentLength: body.length,
      ),
    ]);

    await UpdateService.downloadVerifiedFileForTesting(
      client: client,
      uri: Uri.parse(
        'https://gitee.com/${RemoteRepoConfig.giteeOwner}/time_manager_releases/attach_files/123/app.apk',
      ),
      destination: destination,
      expectedSha256: digest,
      maxBytes: 64,
    );

    expect(client.requestCount, 2);
    expect(
      client.requestHeaders[1].keys
          .any((key) => key.toLowerCase() == 'authorization'),
      isFalse,
    );
    expect(await destination.readAsString(), 'hello');
  });
}
