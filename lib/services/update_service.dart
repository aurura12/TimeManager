import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/diary_gitee_config.dart';
import '../config/remote_repo_config.dart';

class UpdateInfo {
  final String version;
  final String downloadUrl;
  final String releaseNotes;

  const UpdateInfo({
    required this.version,
    required this.downloadUrl,
    required this.releaseNotes,
  });
}

class UpdateCheckResult {
  final UpdateInfo? info;
  final String? error;

  const UpdateCheckResult({this.info, this.error});

  bool get hasUpdate => info != null;
  bool get hasError => error != null;
}

class UpdateService {
  static String get _owner => RemoteRepoConfig.giteeOwner;
  static String get _repo => 'time_manager_releases'; // 公开仓库，专用发布 APK
  static String get _token => DiaryGiteeConfig.hardcodedToken;

  static const Duration _checkTimeout = Duration(seconds: 10);
  static const Duration _downloadConnectTimeout = Duration(seconds: 20);
  static const int _maxRetries = 1;

  static Map<String, String> get _headers => {
        'Accept': 'application/json',
        'Authorization': 'token $_token',
      };

  static Map<String, String> get _downloadHeaders => {
        'Accept': 'application/octet-stream',
        'Authorization': 'token $_token',
      };

  static bool _isRedirectStatus(int statusCode) {
    return statusCode == HttpStatus.movedPermanently ||
        statusCode == HttpStatus.found ||
        statusCode == HttpStatus.seeOther ||
        statusCode == HttpStatus.temporaryRedirect ||
        statusCode == HttpStatus.permanentRedirect;
  }

  static Uri _resolveRedirectUri(Uri baseUri, String location) {
    final redirectUri = Uri.parse(location);
    if (redirectUri.hasScheme) return redirectUri;
    return baseUri.resolveUri(redirectUri);
  }

  static Future<http.StreamedResponse> _sendGetFollowingRedirects(
    http.Client client,
    Uri uri, {
    required Map<String, String> headers,
    int maxRedirects = 5,
  }) async {
    var currentUri = uri;

    for (var redirectCount = 0; redirectCount <= maxRedirects; redirectCount++) {
      final request = http.Request('GET', currentUri)
        ..followRedirects = false
        ..headers.addAll(headers);
      final response = await client.send(request);

      if (!_isRedirectStatus(response.statusCode)) {
        return response;
      }

      final location = response.headers['location'];
      // 消费响应体再继续，避免 HTTP 连接复用导致请求污染
      await response.stream.drain<void>();
      if (location == null || location.isEmpty) {
        return response;
      }

      currentUri = _resolveRedirectUri(currentUri, location);
    }

    throw StateError('重定向次数过多');
  }

  /// Check whether Gitee has published a newer release.
  static Future<UpdateCheckResult> checkForUpdate() async {
    for (int i = 0; i <= _maxRetries; i++) {
      try {
        debugPrint('检查更新: 请求 Gitee API... (尝试 ${i + 1})');
        final response = await http.get(
          Uri.parse('https://gitee.com/api/v5/repos/$_owner/$_repo/releases/latest'),
          headers: _headers,
        ).timeout(_checkTimeout);

        debugPrint('检查更新: HTTP ${response.statusCode}');
        if (response.statusCode != 200) {
          if (i < _maxRetries) {
            await Future.delayed(const Duration(seconds: 1));
            continue;
          }
          if (response.statusCode == 404) {
            return const UpdateCheckResult(error: '暂无发布版本');
          }
          if (response.statusCode == 401 || response.statusCode == 403) {
            return const UpdateCheckResult(error: '更新接口认证失败，请检查 Gitee Token 和仓库权限');
          }
          return UpdateCheckResult(error: '服务器返回错误 (${response.statusCode})');
        }

        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final tagName = data['tag_name'] as String? ?? '';
        final body = data['body'] as String? ?? '';
        debugPrint('检查更新: 最新版本 tag=$tagName');

        String? apkUrl;
        final assets = data['assets'] as List<dynamic>? ?? [];
        debugPrint('检查更新: assets 数量=${assets.length}');
        for (final asset in assets) {
          final name = asset['name'] as String? ?? '';
          debugPrint('检查更新: asset=$name');
          if (name.endsWith('.apk')) {
            apkUrl = (asset['url'] as String?)?.trim();
            apkUrl ??= (asset['browser_download_url'] as String?)?.trim();
            break;
          }
        }

        if (apkUrl == null || apkUrl.isEmpty) {
          return const UpdateCheckResult(error: '未找到可下载的安装包');
        }
        if (tagName.isEmpty) {
          return const UpdateCheckResult(error: '版本信息无效');
        }

        final currentVersion = await _getCurrentVersion();
        debugPrint('检查更新: 当前版本=$currentVersion, 最新版本=$tagName');
        final isNewer = _isNewerVersion(tagName, currentVersion);

        if (isNewer) {
          return UpdateCheckResult(
            info: UpdateInfo(
              version: tagName,
              downloadUrl: apkUrl,
              releaseNotes: body,
            ),
          );
        }

        return const UpdateCheckResult();
      } on TimeoutException catch (e) {
        debugPrint('检查更新超时: $e');
        if (i < _maxRetries) {
          await Future.delayed(const Duration(seconds: 1));
          continue;
        }
        return const UpdateCheckResult(error: '网络超时，请检查网络连接后重试');
      } catch (e, st) {
        debugPrint('检查更新失败: $e');
        debugPrint('堆栈: $st');
        if (i < _maxRetries) {
          await Future.delayed(const Duration(seconds: 1));
          continue;
        }
        return UpdateCheckResult(error: '检查更新失败: $e');
      }
    }

    return const UpdateCheckResult(error: '检查更新失败');
  }

  static Future<String> _getCurrentVersion() async {
    final packageInfo = await PackageInfo.fromPlatform();
    return packageInfo.version;
  }

  static bool _isNewerVersion(String newVersion, String currentVersion) {
    final newV = newVersion.replaceFirst(RegExp(r'^v'), '');
    final currentV = currentVersion.replaceFirst(RegExp(r'^v'), '');

    final newParts = newV.split('.');
    final currentParts = currentV.split('.');

    for (int i = 0; i < newParts.length; i++) {
      if (i >= currentParts.length) return true;
      final newNum = int.tryParse(newParts[i]) ?? 0;
      final currentNum = int.tryParse(currentParts[i]) ?? 0;
      if (newNum > currentNum) return true;
      if (newNum < currentNum) return false;
    }
    return false;
  }

  static String _formatSpeed(int bytesPerSecond) {
    if (bytesPerSecond < 1024) {
      return '$bytesPerSecond B/s';
    } else if (bytesPerSecond < 1024 * 1024) {
      return '${(bytesPerSecond / 1024).toStringAsFixed(1)} KB/s';
    } else {
      return '${(bytesPerSecond / 1024 / 1024).toStringAsFixed(1)} MB/s';
    }
  }

  /// Download the APK and install it.
  static Future<void> downloadAndInstall(
    String downloadUrl,
    String version,
    BuildContext context,
  ) async {
    final progressNotifier = ValueNotifier<double>(0);
    final statusNotifier = ValueNotifier<String>('准备下载...');
    IOSink? sink;

    try {
      if (context.mounted) {
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (context) => _DownloadingDialog(
            progressNotifier: progressNotifier,
            statusNotifier: statusNotifier,
          ),
        );
      }

      final tempDir = await getTemporaryDirectory();
      final apkFile = File('${tempDir.path}/time_manager_v$version.apk');
      sink = apkFile.openWrite();

      final client = http.Client();
      try {
        final response = await _sendGetFollowingRedirects(
          client,
          Uri.parse(downloadUrl),
          headers: _downloadHeaders,
        ).timeout(
          _downloadConnectTimeout,
          onTimeout: () {
            client.close();
            throw TimeoutException('连接超时');
          },
        );

        if (response.statusCode != 200) {
          final responseBody = await response.stream.bytesToString();
          client.close();
          debugPrint('下载失败: HTTP ${response.statusCode}, body=$responseBody');
          if (context.mounted) {
            Navigator.pop(context);
            _showDownloadFailedDialog(context, version, response.statusCode);
          }
          return;
        }

        final contentLength = response.contentLength ?? 0;
        debugPrint('下载: 文件大小=${contentLength ~/ 1024}KB');

        int received = 0;
        final startTime = DateTime.now();
        int lastReceived = 0;
        DateTime lastTime = startTime;

        await for (final chunk in response.stream) {
          sink.add(chunk);
          received += chunk.length;

          final now = DateTime.now();
          final elapsed = now.difference(lastTime).inMilliseconds;
          if (elapsed >= 500) {
            final speed = (received - lastReceived) * 1000 ~/ elapsed;
            final speedStr = _formatSpeed(speed);

            if (contentLength > 0) {
              final progress = received / contentLength;
              progressNotifier.value = progress;
              statusNotifier.value = '下载中 $speedStr';
            } else {
              statusNotifier.value = '下载中 ${received ~/ 1024}KB  $speedStr';
            }

            lastReceived = received;
            lastTime = now;
          }
        }

        await sink.close();
        sink = null;

        debugPrint('下载完成: ${apkFile.path}');

        statusNotifier.value = '正在启动安装...';
        progressNotifier.value = 1.0;

        await Future.delayed(const Duration(milliseconds: 500));

        if (context.mounted) Navigator.pop(context);

        final channel = MethodChannel('com.example.time_manager/install_apk');
        try {
          debugPrint('尝试通过 MethodChannel 安装 APK...');
          await channel.invokeMethod('installApk', {'path': apkFile.path});
          debugPrint('MethodChannel 安装成功');
        } catch (e) {
          debugPrint('MethodChannel 失败: $e，降级到 url_launcher');
          final uri = Uri.file(apkFile.path);
          if (await canLaunchUrl(uri)) {
            await launchUrl(uri, mode: LaunchMode.externalApplication);
          } else if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('无法打开安装程序')),
            );
          }
        }
      } finally {
        await sink?.close();
        client.close();
      }
    } on TimeoutException catch (e) {
      debugPrint('下载超时: $e');
      if (context.mounted) {
        Navigator.pop(context);
        _showDownloadFailedDialog(context, version, null);
      }
    } catch (e) {
      debugPrint('下载安装失败: $e');
      if (context.mounted) {
        Navigator.pop(context);
        _showDownloadFailedDialog(context, version, null);
      }
    } finally {
      progressNotifier.dispose();
      statusNotifier.dispose();
    }
  }

  static void _showDownloadFailedDialog(
    BuildContext context,
    String version,
    int? statusCode,
  ) {
    final releasePageUrl = Uri.https(
      'gitee.com',
      '/${_owner}/$_repo/releases/tag/$version',
    ).toString();

    final message = statusCode == 401 || statusCode == 403
        ? '下载被拒绝，通常是私有仓库权限不足，或者 release 资产需要登录后访问。'
        : '下载失败，你可以先打开发布页手动下载，或稍后重试。';

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('下载失败'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(context);
              final uri = Uri.parse(releasePageUrl);
              if (await canLaunchUrl(uri)) {
                await launchUrl(uri, mode: LaunchMode.externalApplication);
              }
            },
            child: const Text('打开发布页'),
          ),
        ],
      ),
    );
  }
}

class _DownloadingDialog extends StatelessWidget {
  final ValueNotifier<double> progressNotifier;
  final ValueNotifier<String> statusNotifier;

  const _DownloadingDialog({
    required this.progressNotifier,
    required this.statusNotifier,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ValueListenableBuilder<double>(
            valueListenable: progressNotifier,
            builder: (context, progress, child) {
              return CircularProgressIndicator(
                value: progress > 0 ? progress : null,
                strokeWidth: 3,
              );
            },
          ),
          const SizedBox(height: 16),
          ValueListenableBuilder<String>(
            valueListenable: statusNotifier,
            builder: (context, status, child) {
              return Text(
                status,
                style: const TextStyle(fontSize: 14),
              );
            },
          ),
          const SizedBox(height: 8),
          ValueListenableBuilder<double>(
            valueListenable: progressNotifier,
            builder: (context, progress, child) {
              if (progress <= 0) return const SizedBox.shrink();
              return Text(
                '${(progress * 100).toStringAsFixed(1)}%',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}
