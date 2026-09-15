import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:time_manager/services/contents_api_common.dart';
import 'package:time_manager/services/diary_gitee_service.dart';
import 'package:time_manager/services/diary_github_service.dart';
import 'package:time_manager/services/gitee_contents_api.dart';
import 'package:time_manager/services/github_contents_api.dart';

ContentsApiLimits _limits({
  int maxResponseBytes = 4096,
  int maxFileBytes = 1024,
  int maxTreeEntries = 100,
  int maxDirectoryEntries = 100,
  int maxRequestsPerOperation = 20,
  int maxConcurrentRequests = 2,
  int maxTreeDepth = 8,
  int pageSize = 2,
  int maxPages = 10,
}) {
  return ContentsApiLimits(
    maxResponseBytes: maxResponseBytes,
    maxFileBytes: maxFileBytes,
    maxTreeEntries: maxTreeEntries,
    maxDirectoryEntries: maxDirectoryEntries,
    maxRequestsPerOperation: maxRequestsPerOperation,
    maxConcurrentRequests: maxConcurrentRequests,
    maxTreeDepth: maxTreeDepth,
    pageSize: pageSize,
    maxPages: maxPages,
  );
}

http.Response _json(Object body, [int statusCode = 200]) {
  return http.Response(
    jsonEncode(body),
    statusCode,
    headers: const {'content-type': 'application/json'},
  );
}

Map<String, Object> _file(String path, String sha, {int size = 12}) {
  return {
    'type': 'blob',
    'path': path,
    'sha': sha,
    'size': size,
  };
}

void main() {
  test('GitHub tree 被截断时按子树 SHA 完整展开，日记服务不丢文件', () async {
    final requested = <Uri>[];
    final client = MockClient((request) async {
      requested.add(request.url);
      final path = request.url.path;
      final recursive = request.url.queryParameters['recursive'] == '1';
      if (path.endsWith('/git/trees/HEAD') && recursive) {
        return _json({'tree': const [], 'truncated': true});
      }
      if (path.endsWith('/git/trees/HEAD')) {
        return _json({
          'tree': [
            {'type': 'tree', 'path': 'diary', 'sha': 'diary-sha'},
          ],
          'truncated': false,
        });
      }
      if (path.endsWith('/git/trees/diary-sha')) {
        return _json({
          'tree': [
            _file('G2026年9月15日.md', 'g-sha'),
            _file('J2026年9月15日.md', 'j-sha'),
          ],
          'truncated': false,
        });
      }
      return _json({'message': 'unexpected'}, 500);
    });
    addTearDown(client.close);

    final api = GitHubContentsApi(
      owner: 'owner',
      repo: 'repo',
      client: client,
      limits: _limits(),
    );
    final result = await DiaryGitHubService.listDiaryPathsWithSha(
      token: 'token',
      api: api,
    );

    expect(result.success, isTrue);
    expect(result.truncated, isFalse);
    expect(result.pathShaMap, {
      'diary/G2026年9月15日.md': 'g-sha',
      'diary/J2026年9月15日.md': 'j-sha',
    });
    expect(requested, hasLength(3));
  });

  test('Gitee Contents 目录按 nextPageToken 读取多页', () async {
    final requested = <Uri>[];
    final client = MockClient((request) async {
      requested.add(request.url);
      if (request.url.queryParameters['page_token'] == 'page-2') {
        return _json({
          'items': [_file('J2026年9月16日.md', 'j-sha')],
        });
      }
      return _json({
        'items': [_file('G2026年9月16日.md', 'g-sha')],
        'nextPageToken': 'page-2',
      });
    });
    addTearDown(client.close);

    final api = GiteeContentsApi(
      owner: 'owner',
      repo: 'repo',
      client: client,
      limits: _limits(pageSize: 1),
    );
    final result = await api.listDirectory(token: 'token', path: 'diary');

    expect(result.success, isTrue);
    expect(result.entries.map((entry) => entry.path), [
      'G2026年9月16日.md',
      'J2026年9月16日.md',
    ]);
    expect(requested, hasLength(2));
    expect(requested.last.queryParameters['page_token'], 'page-2');
  });

  test('重复分页 token 返回可见失败，不把部分目录当成成功', () async {
    final client = MockClient((_) async {
      return _json({
        'items': [_file('G2026年9月17日.md', 'g-sha')],
        'nextPageToken': 'repeat',
      });
    });
    addTearDown(client.close);

    final api = GitHubContentsApi(
      owner: 'owner',
      repo: 'repo',
      client: client,
      limits: _limits(pageSize: 1),
    );
    final result = await api.listDirectory(token: 'token', path: 'diary');

    expect(result.success, isFalse);
    expect(result.truncated, isTrue);
    expect(result.entries, isEmpty);
    expect(result.error, contains('分页标记重复'));
  });

  test('响应体超过上限时 GitHub 文件读取失败', () async {
    final client = MockClient((_) async {
      return _json({
        'sha': 'sha',
        'content': base64Encode(utf8.encode('这是一段超过响应上限的正文')),
      });
    });
    addTearDown(client.close);

    final api = GitHubContentsApi(
      owner: 'owner',
      repo: 'repo',
      client: client,
      limits: _limits(maxResponseBytes: 24),
    );
    final result = await api.pullText(token: 'token', path: 'diary/G.md');

    expect(result.success, isFalse);
    expect(result.error, contains('响应超过'));
  });

  test('单文件大小超过上限时 Gitee 文件读取失败', () async {
    final client = MockClient((_) async {
      return _json({
        'sha': 'sha',
        'size': 5,
        'content': base64Encode(utf8.encode('small')),
      });
    });
    addTearDown(client.close);

    final api = GiteeContentsApi(
      owner: 'owner',
      repo: 'repo',
      client: client,
      limits: _limits(maxFileBytes: 4),
    );
    final result = await api.pullText(token: 'token', path: 'diary/G.md');

    expect(result.success, isFalse);
    expect(result.error, contains('字节上限'));
  });

  test('目录文件数超过上限时 GitHub 日记列表失败并标记截断', () async {
    final client = MockClient((_) async {
      return _json({
        'tree': [
          _file('G2026年9月18日.md', 'one'),
          _file('J2026年9月18日.md', 'two'),
        ],
        'truncated': false,
      });
    });
    addTearDown(client.close);

    final api = GitHubContentsApi(
      owner: 'owner',
      repo: 'repo',
      client: client,
      limits: _limits(maxTreeEntries: 1),
    );
    final result = await DiaryGitHubService.listDiaryPathsWithSha(
      token: 'token',
      api: api,
    );

    expect(result.success, isFalse);
    expect(result.truncated, isTrue);
    expect(result.pathShaMap, isEmpty);
    expect(result.error, contains('文件数超过'));
  });

  test('远端 HTTP 失败会传递到 Gitee 日记列表状态', () async {
    final client = MockClient((_) async {
      return _json({'message': 'service unavailable'}, 503);
    });
    addTearDown(client.close);

    final api = GiteeContentsApi(
      owner: 'owner',
      repo: 'repo',
      client: client,
      limits: _limits(),
    );
    final result = await DiaryGiteeService.listDiaryPathsWithSha(
      token: 'token',
      api: api,
    );

    expect(result.success, isFalse);
    expect(result.truncated, isFalse);
    expect(result.error, 'service unavailable');
  });

  test('同一个 Contents API 实例限制并发请求数', () async {
    var active = 0;
    var maxActive = 0;
    final client = MockClient((_) async {
      active++;
      if (active > maxActive) maxActive = active;
      await Future<void>.delayed(const Duration(milliseconds: 2));
      active--;
      return _json({
        'sha': 'sha',
        'content': base64Encode(utf8.encode('ok')),
      });
    });
    addTearDown(client.close);

    final api = GitHubContentsApi(
      owner: 'owner',
      repo: 'repo',
      client: client,
      limits: _limits(maxConcurrentRequests: 2),
    );
    final results = await Future.wait(
      List.generate(
        8,
        (index) => api.pullText(
          token: 'token',
          path: 'diary/$index.md',
        ),
      ),
    );

    expect(results.every((result) => result.success), isTrue);
    expect(maxActive, lessThanOrEqualTo(2));
  });
}
