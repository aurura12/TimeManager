import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:time_manager/services/gitee_contents_api.dart';
import 'package:time_manager/services/wake_up_sync_dependencies.dart';

void main() {
  test('起床文件按身份分片，读取和写入复用内容 API 的 SHA 校验', () async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      if (request.method == 'GET') {
        return http.Response(
            jsonEncode({
              'sha': 'old-sha',
              'content': base64Encode(utf8.encode('{"version":2}')),
              'encoding': 'base64',
            }),
            200);
      }
      return http.Response(
          jsonEncode({
            'content': {'sha': 'new-sha'}
          }),
          200);
    });
    addTearDown(client.close);
    final service = WakeUpGiteeService(
        api: GiteeContentsApi(owner: 'owner', repo: 'repo', client: client));
    expect(WakeUpGiteeService.pathFor('g'), 'wake_up/g.json');
    expect(WakeUpGiteeService.pathFor('j'), 'wake_up/j.json');
    final pull = await service.pull(token: 'test-token', userCode: 'j');
    expect(pull.success, isTrue);
    expect(pull.sha, 'old-sha');
    final push = await service.push(
        token: 'test-token',
        userCode: 'j',
        content: '{"version":2}',
        commitMessage: 'wake_up(j): sync',
        expectedSha: pull.sha);
    expect(push.success, isTrue);
    expect(requests.map((r) => r.method), ['GET', 'PUT']);
    expect(
        requests.every((r) => r.url.path.endsWith('/contents/wake_up/j.json')),
        isTrue);
    expect(jsonDecode(requests.last.body)['sha'], 'old-sha');
  });

  test('创建前发现另一端已上传，标为冲突并拒绝覆盖', () async {
    final methods = <String>[];
    final client = MockClient((request) async {
      methods.add(request.method);
      return http.Response(
          jsonEncode({
            'sha': 'new-sha',
            'content': base64Encode(utf8.encode('{}')),
            'encoding': 'base64',
          }),
          200);
    });
    addTearDown(client.close);
    final service = WakeUpGiteeService(
        api: GiteeContentsApi(owner: 'owner', repo: 'repo', client: client));
    final result = await service.push(
        token: 'test-token',
        userCode: 'g',
        content: '{}',
        commitMessage: 'wake_up(g): sync',
        expectNotFound: true);
    expect(result.success, isFalse);
    expect(result.conflict, isTrue);
    expect(methods, ['GET']);
  });
}
