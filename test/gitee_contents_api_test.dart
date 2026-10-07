import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:time_manager/services/gitee_contents_api.dart';

void main() {
  const apiOwner = 'owner';
  const apiRepo = 'repo';
  const token = 'token';

  test('expectedSha 使用 PUT 并返回服务端新 SHA', () async {
    http.Request? captured;
    final client = MockClient((request) async {
      captured = request;
      return http.Response(
        jsonEncode({
          'content': {'sha': 'new-sha'},
        }),
        200,
      );
    });
    addTearDown(client.close);

    final api = GiteeContentsApi(
      owner: apiOwner,
      repo: apiRepo,
      client: client,
    );
    final result = await api.pushText(
      token: token,
      path: 'diary/G.md',
      content: 'content',
      commitMessage: 'update',
      expectedSha: 'old-sha',
    );

    expect(result.success, isTrue);
    expect(result.created, isFalse);
    expect(result.sha, 'new-sha');
    expect(result.conflict, isFalse);
    expect(captured, isNotNull);
    expect(captured!.method, 'PUT');
    final payload = jsonDecode(captured!.body) as Map<String, dynamic>;
    expect(payload['sha'], 'old-sha');
  });

  test('expectNotFound 先确认不存在，再使用 POST 创建', () async {
    final methods = <String>[];
    final client = MockClient((request) async {
      methods.add(request.method);
      if (request.method == 'GET') return http.Response('', 404);
      return http.Response(
        jsonEncode({
          'content': {'sha': 'created-sha'},
        }),
        201,
      );
    });
    addTearDown(client.close);

    final api = GiteeContentsApi(
      owner: apiOwner,
      repo: apiRepo,
      client: client,
    );
    final result = await api.pushText(
      token: token,
      path: 'diary/G.md',
      content: 'content',
      commitMessage: 'create',
      expectNotFound: true,
    );

    expect(result.success, isTrue);
    expect(result.created, isTrue);
    expect(result.sha, 'created-sha');
    expect(methods, ['GET', 'POST']);
  });

  test('服务端版本冲突会被标记为 conflict', () async {
    var attempts = 0;
    final client = MockClient((_) async {
      attempts++;
      return http.Response(jsonEncode({'message': 'sha mismatch'}), 409);
    });
    addTearDown(client.close);

    final api = GiteeContentsApi(
      owner: apiOwner,
      repo: apiRepo,
      client: client,
    );
    final result = await api.pushText(
      token: token,
      path: 'diary/G.md',
      content: 'content',
      commitMessage: 'update',
      expectedSha: 'old-sha',
    );

    expect(result.success, isFalse);
    expect(result.conflict, isTrue);
    expect(result.error, 'sha mismatch');
    expect(attempts, 1, reason: '版本冲突必须重新拉取合并，不能直接重试旧 SHA');
  });

  test('安卓连接中断后重试 PUT，保留原内容与版本校验', () async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      if (requests.length < 3) {
        // IOClient 将 HttpException 包装为普通 ClientException，
        // 不再具有 SocketException / IOException 类型。
        throw http.ClientException(
          'Software caused connection abort',
          request.url,
        );
      }
      return http.Response(
        jsonEncode({
          'content': {'sha': 'new-sha'}
        }),
        200,
      );
    });
    addTearDown(client.close);

    final api = GiteeContentsApi(
      owner: apiOwner,
      repo: apiRepo,
      client: client,
    );
    final result = await api.pushText(
      token: token,
      path: 'schedule/j/2026-10-07.json',
      content: '{"slots":[{"i":60,"l":"工作"}]}',
      commitMessage: 'update schedule',
      expectedSha: 'old-sha',
    );

    expect(result.success, isTrue);
    expect(result.sha, 'new-sha');
    expect(requests, hasLength(3));
    expect(requests.map((request) => request.method), everyElement('PUT'));
    expect(requests.map((request) => request.url),
        everyElement(requests.first.url));
    expect(requests.map((request) => request.body),
        everyElement(requests.first.body));
    final payload = jsonDecode(requests.last.body) as Map<String, dynamic>;
    expect(payload['sha'], 'old-sha');
    expect(
      utf8.decode(base64Decode(payload['content'] as String)),
      '{"slots":[{"i":60,"l":"工作"}]}',
    );
  });

  test('连接中断后重试 POST 创建日程', () async {
    final methods = <String>[];
    var postAttempts = 0;
    final client = MockClient((request) async {
      methods.add(request.method);
      if (request.method == 'GET') return http.Response('', 404);
      if (++postAttempts == 1) {
        throw http.ClientException(
            'Software caused connection abort', request.url);
      }
      return http.Response(
        jsonEncode({
          'content': {'sha': 'created-sha'}
        }),
        201,
      );
    });
    addTearDown(client.close);

    final api = GiteeContentsApi(
      owner: apiOwner,
      repo: apiRepo,
      client: client,
    );
    final result = await api.pushText(
      token: token,
      path: 'schedule/j/2026-10-07.json',
      content: '{"slots":[]}',
      commitMessage: 'create schedule',
      expectNotFound: true,
    );

    expect(result.success, isTrue);
    expect(result.created, isTrue);
    expect(result.sha, 'created-sha');
    expect(methods, ['GET', 'POST', 'POST']);
  });

  test('拉取响应中途断开时重新拉取完整正文', () async {
    var attempts = 0;
    Stream<List<int>> interruptedResponse(Uri uri) async* {
      yield utf8.encode('{"content":');
      throw http.ClientException('Software caused connection abort', uri);
    }

    final content = '{"slots":[]}';
    final client = MockClient.streaming((request, body) async {
      await body.drain<void>();
      attempts++;
      return http.StreamedResponse(
        attempts == 1
            ? interruptedResponse(request.url)
            : Stream.value(utf8.encode(jsonEncode({
                'content': base64Encode(utf8.encode(content)),
                'sha': 'remote-sha',
              }))),
        200,
        request: request,
      );
    });
    addTearDown(client.close);

    final api = GiteeContentsApi(
      owner: apiOwner,
      repo: apiRepo,
      client: client,
    );
    final result = await api.pullText(
      token: token,
      path: 'schedule/j/2026-10-07.json',
    );

    expect(result.success, isTrue);
    expect(result.content, content);
    expect(result.sha, 'remote-sha');
    expect(attempts, 2);
  });

  test('持续连接中断最多请求三次后返回失败', () async {
    var attempts = 0;
    final client = MockClient((request) async {
      attempts++;
      throw http.ClientException(
          'Software caused connection abort', request.url);
    });
    addTearDown(client.close);

    final api = GiteeContentsApi(
      owner: apiOwner,
      repo: apiRepo,
      client: client,
    );
    final result = await api.pushText(
      token: token,
      path: 'schedule/j/2026-10-07.json',
      content: '{"slots":[]}',
      commitMessage: 'update schedule',
      expectedSha: 'old-sha',
    );

    expect(result.success, isFalse);
    expect(result.error, contains('Software caused connection abort'));
    expect(attempts, 3);
  });

  for (final statusCode in [401, 403]) {
    test('权限错误 $statusCode 不重试', () async {
      var attempts = 0;
      final client = MockClient((_) async {
        attempts++;
        return http.Response(
            jsonEncode({'message': 'permission denied'}), statusCode);
      });
      addTearDown(client.close);

      final api = GiteeContentsApi(
        owner: apiOwner,
        repo: apiRepo,
        client: client,
      );
      final result = await api.pushText(
        token: token,
        path: 'schedule/j/2026-10-07.json',
        content: '{"slots":[]}',
        commitMessage: 'update schedule',
        expectedSha: 'old-sha',
      );

      expect(result.success, isFalse);
      expect(result.error, 'permission denied');
      expect(attempts, 1);
    });
  }

  test('响应丢失后遇到 SHA 冲突时停止重试，不覆盖远端新版本', () async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      if (requests.length == 1) {
        // 服务端可能已写入，但响应在返回途中丢失。
        throw http.ClientException(
            'Software caused connection abort', request.url);
      }
      return http.Response(jsonEncode({'message': 'sha mismatch'}), 409);
    });
    addTearDown(client.close);

    final api = GiteeContentsApi(
      owner: apiOwner,
      repo: apiRepo,
      client: client,
    );
    final result = await api.pushText(
      token: token,
      path: 'schedule/j/2026-10-07.json',
      content: '{"slots":[]}',
      commitMessage: 'update schedule',
      expectedSha: 'old-sha',
    );

    expect(result.success, isFalse);
    expect(result.conflict, isTrue);
    expect(requests, hasLength(2));
    for (final request in requests) {
      expect(request.method, 'PUT');
      expect(jsonDecode(request.body)['sha'], 'old-sha');
    }
  });

  test('主动取消的请求不自动重试', () async {
    var attempts = 0;
    final client = MockClient((request) async {
      attempts++;
      throw http.RequestAbortedException(request.url);
    });
    addTearDown(client.close);

    final api = GiteeContentsApi(
      owner: apiOwner,
      repo: apiRepo,
      client: client,
    );
    final result = await api.pullText(
      token: token,
      path: 'schedule/j/2026-10-07.json',
    );

    expect(result.success, isFalse);
    expect(attempts, 1);
  });
}
