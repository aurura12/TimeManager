import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../config/github_config.dart';

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
  static String get _owner => GithubConfig.owner;
  static String get _repo => GithubConfig.repo;
  static String get _token => GithubConfig.token;

  static const Duration _checkTimeout = Duration(seconds: 10);
  static const Duration _downloadConnectTimeout = Duration(seconds: 10);
  static const int _maxRetries = 1;

  /// 检查是否有新版本
  static Future<UpdateCheckResult> checkForUpdate() async {
    for (int i = 0; i <= _maxRetries; i++) {
      try {
        debugPrint('检查更新: 请求 GitHub API... (尝试 ${i + 1})');
        final response = await http.get(
          Uri.parse('https://api.github.com/repos/$_owner/$_repo/releases/latest'),
          headers: {
            'Accept': 'application/vnd.github.v3+json',
            'Authorization': 'Bearer $_token',
          },
        ).timeout(_checkTimeout);

        debugPrint('检查更新: HTTP ${response.statusCode}');
        if (response.statusCode != 200) {
          if (i < _maxRetries) {
            await Future.delayed(const Duration(seconds: 1));
            continue;
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
          debugPrint('检查更新: 未找到 APK 文件');
          return UpdateCheckResult(error: '未找到可下载的安装包');
        }
        if (tagName.isEmpty) {
          debugPrint('检查更新: tagName 为空');
          return UpdateCheckResult(error: '版本信息无效');
        }

        final currentVersion = await _getCurrentVersion();
        debugPrint('检查更新: 当前版本=$currentVersion, 最新版本=$tagName');
        final isNewer = _isNewerVersion(tagName, currentVersion);
        debugPrint('检查更新: 是否有新版本=$isNewer');

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

  /// 格式化下载速度
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

    try {
      // 显示下载进度对话框
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

      // 使用 Client 获取流式响应（带连接超时）
      final client = http.Client();
      IOSink? sink;
      try {
        final request = http.Request('GET', Uri.parse(downloadUrl));
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

        // 获取文件总大小
        final contentLength = response.contentLength ?? 0;
        debugPrint('下载: 文件大小=${contentLength ~/ 1024}KB');

        // 流式写入文件
        final tempDir = await getTemporaryDirectory();
        final apkFile = File('${tempDir.path}/time_manager_v$version.apk');
        sink = apkFile.openWrite();

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
            // 每 500ms 更新一次速度
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
        client.close();

        debugPrint('下载完成: ${apkFile.path}');

        // 更新状态为安装中
        statusNotifier.value = '正在启动安装...';
        progressNotifier.value = 1.0;

        // 等待一小段时间让用户看到"安装中"状态
        await Future.delayed(const Duration(milliseconds: 500));

        // 关闭进度对话框
        if (context.mounted) Navigator.pop(context);

        // 使用 MethodChannel 调用原生代码打开 APK
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
