import 'dart:convert';

import 'package:http/http.dart' as http;

import 'contents_api_common.dart';

class _FetchedTree {
  final bool success;
  final List<ContentsTreeEntry> entries;
  final bool truncated;
  final String? error;

  const _FetchedTree({
    required this.success,
    required this.entries,
    required this.truncated,
    this.error,
  });

  factory _FetchedTree.error(String message, {bool truncated = false}) {
    return _FetchedTree(
      success: false,
      entries: const [],
      truncated: truncated,
      error: message,
    );
  }
}

class _PendingTree {
  final String prefix;
  final String sha;
  final int depth;

  const _PendingTree({
    required this.prefix,
    required this.sha,
    required this.depth,
  });
}

/// GitHub 仓库 Contents API 封装。
class GitHubContentsApi {
  static const String _baseHost = 'api.github.com';

  final String owner;
  final String repo;
  final http.Client? _client;
  final ContentsApiLimits limits;

  const GitHubContentsApi({
    required this.owner,
    required this.repo,
    http.Client? client,
    this.limits = ContentsApiLimits.defaults,
  }) : _client = client;

  Map<String, String> headers(String token) {
    return {
      'Accept': 'application/vnd.github+json',
      'Authorization': 'Bearer $token',
      'X-GitHub-Api-Version': '2022-11-28',
      'Content-Type': 'application/json',
    };
  }

  Uri contentsUri(
    String path, {
    String? token,
    String? ref,
    int? page,
    int? perPage,
    String? pageToken,
  }) {
    return Uri.https(
      _baseHost,
      '/repos/$owner/$repo/contents/$path',
      {
        if (ref != null) 'ref': ref,
        if (page != null) 'page': '$page',
        if (perPage != null) 'per_page': '$perPage',
        if (pageToken != null) 'page_token': pageToken,
      },
    );
  }

  Uri treeUri(
    String ref, {
    String? token,
    bool recursive = true,
    int? page,
    int? perPage,
    String? pageToken,
  }) {
    return Uri.https(
      _baseHost,
      '/repos/$owner/$repo/git/trees/$ref',
      {
        if (recursive) 'recursive': '1',
        if (page != null) 'page': '$page',
        if (perPage != null) 'per_page': '$perPage',
        if (pageToken != null) 'page_token': pageToken,
      },
    );
  }

  Future<http.Response> _get(Uri uri, String token) {
    return _send(method: 'GET', uri: uri, token: token);
  }

  Future<http.Response> _put(Uri uri, String token, String body) {
    return _send(method: 'PUT', uri: uri, token: token, body: body);
  }

  Future<http.Response> _send({
    required String method,
    required Uri uri,
    required String token,
    String? body,
  }) {
    final request = http.Request(method, uri)..headers.addAll(headers(token));
    if (body != null) request.body = body;
    return sendLimitedContentsRequest(
      owner: this,
      client: _client,
      request: request,
      limits: limits,
    );
  }

  /// 拉取文件内容。
  Future<
      ({
        bool success,
        bool notFound,
        String? content,
        String? sha,
        String? error
      })> pullText({
    required String token,
    required String path,
  }) async {
    try {
      final res = await requestWithRetry(() => _get(contentsUri(path), token));
      if (res.statusCode == 404) {
        return (
          success: false,
          notFound: true,
          content: null,
          sha: null,
          error: null,
        );
      }
      if (res.statusCode != 200) {
        return (
          success: false,
          notFound: false,
          content: null,
          sha: null,
          error: extractErrorMessage(res),
        );
      }

      final body = json.decode(res.body);
      if (body is! Map) {
        return (
          success: false,
          notFound: false,
          content: null,
          sha: null,
          error: '远端文件内容无效',
        );
      }
      final declaredSize = _readInt(body['size']);
      if (declaredSize != null && declaredSize > limits.maxFileBytes) {
        return (
          success: false,
          notFound: false,
          content: null,
          sha: null,
          error: '远端文件超过 ${limits.maxFileBytes} 字节上限',
        );
      }
      final rawContent = body['content']?.toString();
      final sha = body['sha']?.toString();
      if (rawContent == null || sha == null) {
        return (
          success: false,
          notFound: false,
          content: null,
          sha: null,
          error: '远端文件内容无效',
        );
      }
      final bytes = base64Decode(normalizeBase64(rawContent));
      if (bytes.length > limits.maxFileBytes) {
        return (
          success: false,
          notFound: false,
          content: null,
          sha: null,
          error: '远端文件超过 ${limits.maxFileBytes} 字节上限',
        );
      }
      final decoded = utf8.decode(bytes);
      return (
        success: true,
        notFound: false,
        content: decoded,
        sha: sha,
        error: null,
      );
    } on ContentsResponseTooLargeException catch (e) {
      return (
        success: false,
        notFound: false,
        content: null,
        sha: null,
        error: e.toString(),
      );
    } catch (e) {
      return (
        success: false,
        notFound: false,
        content: null,
        sha: null,
        error: '拉取失败: $e',
      );
    }
  }

  /// 推送文件内容。GitHub 用 PUT 即可创建和更新。
  Future<({bool success, bool created, String? error})> pushText({
    required String token,
    required String path,
    required String content,
    required String commitMessage,
  }) async {
    try {
      final bytes = utf8.encode(content);
      if (bytes.length > limits.maxFileBytes) {
        return (
          success: false,
          created: false,
          error: '待推送文件超过 ${limits.maxFileBytes} 字节上限',
        );
      }

      String? sha;
      final current = await pullText(token: token, path: path);
      if (current.success) {
        sha = current.sha;
      } else if (!current.notFound) {
        return (
          success: false,
          created: false,
          error: current.error ?? '读取远端文件失败',
        );
      }

      final payload = <String, dynamic>{
        'message': commitMessage,
        'content': base64Encode(bytes),
      };
      if (sha != null) payload['sha'] = sha;

      final res = await requestWithRetry(
        () => _put(contentsUri(path), token, json.encode(payload)),
      );
      if (res.statusCode == 200 || res.statusCode == 201) {
        return (success: true, created: res.statusCode == 201, error: null);
      }
      return (
        success: false,
        created: false,
        error: extractErrorMessage(res),
      );
    } on ContentsResponseTooLargeException catch (e) {
      return (success: false, created: false, error: e.toString());
    } catch (e) {
      return (success: false, created: false, error: '推送失败: $e');
    }
  }

  /// 读取完整 Git tree。
  ///
  /// GitHub 的递归 tree 接口没有 nextPageToken，超过平台阈值时只返回
  /// `truncated: true`。此时改用非递归 tree 按目录 SHA 展开，任何上限或
  /// 请求失败都会返回失败状态，绝不把部分目录当成完整目录。
  Future<ContentsTreeResult> listTree({
    required String token,
    String ref = 'HEAD',
  }) async {
    final budget = ContentsRequestBudget(limits.maxRequestsPerOperation);
    try {
      final first = await _fetchTree(
        token: token,
        ref: ref,
        recursive: true,
        budget: budget,
      );
      if (!first.success) {
        return ContentsTreeResult.error(
          first.error ?? '读取远端目录失败',
          truncated: first.truncated,
        );
      }
      if (!first.truncated) return ContentsTreeResult.success(first.entries);

      return await _walkTree(token: token, rootRef: ref, budget: budget);
    } catch (e) {
      return ContentsTreeResult.error('读取远端目录失败: $e');
    }
  }

  Future<ContentsTreeResult> _walkTree({
    required String token,
    required String rootRef,
    required ContentsRequestBudget budget,
  }) async {
    final pending = <_PendingTree>[
      _PendingTree(prefix: '', sha: rootRef, depth: 0),
    ];
    final entries = <ContentsTreeEntry>[];

    while (pending.isNotEmpty) {
      final batchSize = pending.length < limits.maxConcurrentRequests
          ? pending.length
          : limits.maxConcurrentRequests;
      final batch = pending.sublist(0, batchSize);
      pending.removeRange(0, batchSize);
      final pages = await Future.wait(
        batch.map(
          (node) => _fetchTree(
            token: token,
            ref: node.sha,
            recursive: false,
            budget: budget,
          ),
        ),
      );

      for (var i = 0; i < pages.length; i++) {
        final page = pages[i];
        final node = batch[i];
        if (!page.success) {
          return ContentsTreeResult.error(
            page.error ?? '读取远端目录失败',
            truncated: page.truncated,
          );
        }
        if (page.truncated) {
          return ContentsTreeResult.error(
            '远端目录仍被截断，无法完整读取',
            truncated: true,
          );
        }
        if (entries.length + page.entries.length > limits.maxTreeEntries) {
          return ContentsTreeResult.error(
            '远端目录文件数超过 ${limits.maxTreeEntries} 项上限',
            truncated: true,
          );
        }

        for (final entry in page.entries) {
          final fullPath = _joinPath(node.prefix, entry.path);
          final normalized = ContentsTreeEntry(
            type: entry.type,
            path: fullPath,
            sha: entry.sha,
            size: entry.size,
          );
          if (entry.type == 'tree') {
            if (node.depth >= limits.maxTreeDepth) {
              return ContentsTreeResult.error(
                '远端目录层级超过 ${limits.maxTreeDepth} 层上限',
                truncated: true,
              );
            }
            pending.add(
              _PendingTree(
                prefix: fullPath,
                sha: entry.sha,
                depth: node.depth + 1,
              ),
            );
          }
          entries.add(normalized);
        }
      }
    }
    return ContentsTreeResult.success(entries);
  }

  Future<_FetchedTree> _fetchTree({
    required String token,
    required String ref,
    required bool recursive,
    required ContentsRequestBudget budget,
  }) async {
    if (!budget.take()) {
      return _FetchedTree.error(
        '读取远端目录请求数超过 ${limits.maxRequestsPerOperation} 次上限',
        truncated: true,
      );
    }
    try {
      final res = await requestWithRetry(
        () => _get(treeUri(ref, recursive: recursive), token),
      );
      if (res.statusCode != 200) {
        return _FetchedTree.error(extractErrorMessage(res));
      }
      final body = json.decode(res.body);
      if (body is! Map || body['tree'] is! List) {
        return _FetchedTree.error('远端目录结构无效');
      }
      final rawEntries = body['tree'] as List;
      if (rawEntries.length > limits.maxTreeEntries) {
        return _FetchedTree.error(
          '远端目录文件数超过 ${limits.maxTreeEntries} 项上限',
          truncated: true,
        );
      }
      final entries = <ContentsTreeEntry>[];
      for (final raw in rawEntries) {
        if (raw is! Map) return _FetchedTree.error('远端目录项无效');
        final rawType = raw['type']?.toString();
        if (rawType != 'blob' && rawType != 'tree') continue;
        final type = rawType!;
        final path = raw['path']?.toString();
        final sha = raw['sha']?.toString();
        if (path == null || path.isEmpty || sha == null || sha.isEmpty) {
          return _FetchedTree.error('远端目录项缺少 path 或 sha');
        }
        final size = _readInt(raw['size']);
        if (type == 'blob' && size != null && size > limits.maxFileBytes) {
          return _FetchedTree.error(
            '远端文件超过 ${limits.maxFileBytes} 字节上限',
            truncated: true,
          );
        }
        entries.add(
          ContentsTreeEntry(type: type, path: path, sha: sha, size: size),
        );
      }
      return _FetchedTree(
        success: true,
        entries: entries,
        truncated: body['truncated'] == true,
      );
    } on ContentsResponseTooLargeException catch (e) {
      return _FetchedTree.error(e.toString(), truncated: true);
    } catch (e) {
      return _FetchedTree.error('读取远端目录失败: $e');
    }
  }

  /// 分页读取一个 Contents 目录。
  Future<ContentsDirectoryResult> listDirectory({
    required String token,
    String path = '',
    String? ref,
  }) async {
    final budget = ContentsRequestBudget(limits.maxRequestsPerOperation);
    final entries = <ContentsTreeEntry>[];
    final seenUris = <String>{};
    var page = 1;
    Uri? nextUri;

    try {
      while (true) {
        if (page > limits.maxPages) {
          return ContentsDirectoryResult.error(
            '远端目录分页超过 ${limits.maxPages} 页上限',
            truncated: true,
          );
        }
        final uri = nextUri ??
            contentsUri(
              path,
              ref: ref,
              page: page,
              perPage: limits.pageSize,
            );
        if (!seenUris.add(uri.toString())) {
          return ContentsDirectoryResult.error(
            '远端目录分页标记重复，已停止读取',
            truncated: true,
          );
        }
        if (!budget.take()) {
          return ContentsDirectoryResult.error(
            '读取远端目录请求数超过 ${limits.maxRequestsPerOperation} 次上限',
            truncated: true,
          );
        }
        final res = await requestWithRetry(() => _get(uri, token));
        if (res.statusCode != 200) {
          return ContentsDirectoryResult.error(extractErrorMessage(res));
        }
        final decoded = json.decode(res.body);
        final rawEntries = _directoryItems(decoded);
        if (rawEntries == null) {
          return ContentsDirectoryResult.error('远端目录结构无效');
        }
        if (entries.length + rawEntries.length > limits.maxDirectoryEntries) {
          return ContentsDirectoryResult.error(
            '远端目录文件数超过 ${limits.maxDirectoryEntries} 项上限',
            truncated: true,
          );
        }
        for (final raw in rawEntries) {
          final entry = _parseDirectoryEntry(raw);
          if (entry == null) {
            return ContentsDirectoryResult.error('远端目录项无效');
          }
          if (entry.type == 'blob' &&
              entry.size != null &&
              entry.size! > limits.maxFileBytes) {
            return ContentsDirectoryResult.error(
              '远端文件超过 ${limits.maxFileBytes} 字节上限',
              truncated: true,
            );
          }
          entries.add(entry);
        }

        final candidate = _nextPageUri(
          decoded,
          res.headers,
          current: uri,
          page: page,
          itemCount: rawEntries.length,
          pageSize: limits.pageSize,
        );
        if (candidate == null) break;
        nextUri = candidate;
        page++;
      }
      return ContentsDirectoryResult.success(entries);
    } on ContentsResponseTooLargeException catch (e) {
      return ContentsDirectoryResult.error(e.toString(), truncated: true);
    } catch (e) {
      return ContentsDirectoryResult.error('读取远端目录失败: $e');
    }
  }
}

String _joinPath(String prefix, String path) {
  if (prefix.isEmpty) return path;
  if (path.isEmpty) return prefix;
  return '$prefix/$path';
}

int? _readInt(Object? value) {
  if (value is int) return value;
  return int.tryParse(value?.toString() ?? '');
}

List? _directoryItems(Object? decoded) {
  if (decoded is List) return decoded;
  if (decoded is! Map) return null;
  final items = decoded['items'] ??
      decoded['tree'] ??
      decoded['data'] ??
      decoded['contents'];
  return items is List ? items : null;
}

ContentsTreeEntry? _parseDirectoryEntry(Object? raw) {
  if (raw is! Map) return null;
  final rawType = raw['type']?.toString();
  final type = rawType == 'file' || rawType == 'blob'
      ? 'blob'
      : rawType == 'dir' || rawType == 'directory' || rawType == 'tree'
          ? 'tree'
          : null;
  if (type == null) return null;
  final path = raw['path']?.toString() ?? raw['name']?.toString();
  final sha = raw['sha']?.toString();
  if (path == null || path.isEmpty || sha == null || sha.isEmpty) return null;
  return ContentsTreeEntry(
    type: type,
    path: path,
    sha: sha,
    size: _readInt(raw['size']),
  );
}

Uri? _nextPageUri(
  Object? decoded,
  Map<String, String> headers, {
  required Uri current,
  required int page,
  required int itemCount,
  required int pageSize,
}) {
  final link = headers.entries
      .where((entry) => entry.key.toLowerCase() == 'link')
      .map((entry) => entry.value)
      .firstWhere(
        (value) => value.contains('rel="next"') || value.contains("rel='next'"),
        orElse: () => '',
      );
  if (link.isNotEmpty) {
    final match = RegExp(r'<([^>]+)>\s*;\s*rel="next"').firstMatch(link);
    if (match != null) return Uri.tryParse(match.group(1)!);
  }

  if (decoded is Map) {
    final rawToken = decoded['nextPageToken'] ??
        decoded['next_page_token'] ??
        decoded['nextToken'] ??
        decoded['next_page'];
    if (rawToken != null && rawToken.toString().isNotEmpty) {
      final token = rawToken.toString();
      if (token.startsWith('http://') || token.startsWith('https://')) {
        return Uri.tryParse(token);
      }
      return current.replace(
        queryParameters: {
          ...current.queryParameters,
          'page_token': token,
        },
      );
    }
    final hasMore = decoded['hasMore'] == true || decoded['has_more'] == true;
    if (hasMore) {
      return current.replace(
        queryParameters: {
          ...current.queryParameters,
          'page': '${page + 1}',
        },
      );
    }
  }

  if (decoded is List && itemCount > 0 && itemCount == pageSize) {
    return current.replace(
      queryParameters: {
        ...current.queryParameters,
        'page': '${page + 1}',
      },
    );
  }
  return null;
}
