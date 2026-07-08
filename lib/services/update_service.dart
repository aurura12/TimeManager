import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../config/remote_repo_config.dart';
import '../config/diary_gitee_config.dart';

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
  static String get _repo => RemoteRepoConfig.giteeRepo;
  static String get _token => DiaryGiteeConfig.hardcodedToken;

  static const Duration _checkTimeout = Duration(seconds: 10);
  static const Duration _downloadConnectTimeout = Duration(seconds: 10);
  static const int _maxRetries = 1;

  static Map<String, String> get _headers => {
    'Accept': 'application/json',
    'Authorization': 'token $_token',
  };

  /// 检查 Gitee 是否发布了新版本
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
            return UpdateCheckResult(error: '暂无发布版本');
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
            apkUrl = asset['browser_download_url'] as String?;
            break;
          }
        }

        if (apkUrl == null) {
          return UpdateCheckResult(error: '未找到可下载的安装包');
        }
        if (tagName.isEmpty) {
          return UpdateCheckResult(error: '版本信息无效');
        }

        // 私有仓库下载需要 Authorization header 认证

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

        return UpdateCheckResult();
      } on TimeoutException catch (e) {
        debugPrint('检查更新超时: $e');
        if (i < _maxRetries) {
          await Future.delayed(const Duration(seconds: 1));
          continue;
        }
        return UpdateCheckResult(error: '网络超时，请检查网络连接后重试');
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
    return UpdateCheckResult(error: '检查更新失败');
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

  /// 下载并安装 APK（带进度显示）
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

      // Gitee 下载先经过两次同域重定向（auth 保留），
      // 最后跨域到 foruda.gitee.com（auth 丢失但 URL 中已有下载 token）
      final client = http.Client();
      try {
        final request = http.Request('GET', Uri.parse(downloadUrl));
        request.headers.addAll(_headers);
        final response = await client.send(request).timeout(
          _downloadConnectTimeout,
          onTimeout: () {
            client.close();
            throw TimeoutException('连接超时');
          },
        );

        if (response.statusCode != 200) {
          client.close();
          if (context.mounted) {
            Navigator.pop(context);
            _showDownloadFailedDialog(context, downloadUrl);
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
              statusNotifier.value = '下载中  $speedStr';
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
          } else {
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('无法打开安装程序')),
              );
            }
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
        _showDownloadFailedDialog(context, downloadUrl);
      }
    } catch (e) {
      debugPrint('下载安装失败: $e');
      if (context.mounted) {
        Navigator.pop(context);
        _showDownloadFailedDialog(context, downloadUrl);
      }
    } finally {
      progressNotifier.dispose();
      statusNotifier.dispose();
    }
  }

  static void _showDownloadFailedDialog(BuildContext context, String downloadUrl) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('下载失败'),
        content: const Text('下载速度过慢或网络连接失败，你可以尝试手动下载安装包。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(context);
              final uri = Uri.parse(downloadUrl);
              if (await canLaunchUrl(uri)) {
                await launchUrl(uri, mode: LaunchMode.externalApplication);
              }
            },
            child: const Text('浏览器下载'),
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
