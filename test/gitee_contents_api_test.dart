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
    final client = MockClient((_) async {
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
  });
}
