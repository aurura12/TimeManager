import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

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

class UpdateService {
  // TODO: 替换为你的 GitHub 仓库
  static const String _owner = 'aurura12';
  static const String _repo = 'TimeManager';

  /// 检查是否有新版本
  static Future<UpdateInfo?> checkForUpdate() async {
    try {
      final response = await http.get(
        Uri.parse('https://api.github.com/repos/$_owner/$_repo/releases/latest'),
        headers: {'Accept': 'application/vnd.github.v3+json'},
      );

      if (response.statusCode != 200) return null;

      final data = Map<String, dynamic>.from(
          Map<String, dynamic>.from(response.body as dynamic) as dynamic);
      final tagName = data['tag_name'] as String? ?? '';
      final body = data['body'] as String? ?? '';

      // 找到 APK 下载链接
      String? apkUrl;
      final assets = data['assets'] as List<dynamic>? ?? [];
      for (final asset in assets) {
        final name = asset['name'] as String? ?? '';
        if (name.endsWith('.apk')) {
          apkUrl = asset['browser_download_url'] as String?;
          break;
        }
      }

      if (apkUrl == null || tagName.isEmpty) return null;

      // 比较版本号
      final currentVersion = await _getCurrentVersion();
      if (_isNewerVersion(tagName, currentVersion)) {
        return UpdateInfo(
          version: tagName,
          downloadUrl: apkUrl,
          releaseNotes: body,
        );
      }

      return null;
    } catch (e) {
      debugPrint('检查更新失败: $e');
      return null;
    }
  }

  /// 获取当前版本号
  static Future<String> _getCurrentVersion() async {
    final packageInfo = await PackageInfo.fromPlatform();
    return packageInfo.version;
  }

  /// 比较版本号，返回 newVersion 是否比 currentVersion 更新
  static bool _isNewerVersion(String newVersion, String currentVersion) {
    // 移除可能的 v 前缀
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

  /// 下载并安装 APK
  static Future<void> downloadAndInstall(
    String downloadUrl,
    String version,
    BuildContext context,
  ) async {
    try {
      // 显示下载进度对话框
      if (context.mounted) {
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (context) => const _DownloadingDialog(),
        );
      }

      // 下载 APK
      final response = await http.get(Uri.parse(downloadUrl));

      if (response.statusCode != 200) {
        if (context.mounted) {
          Navigator.pop(context);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('下载失败')),
          );
        }
        return;
      }

      // 保存到临时目录
      final tempDir = await getTemporaryDirectory();
      final apkFile = File('${tempDir.path}/time_manager_v$version.apk');
      await apkFile.writeAsBytes(response.bodyBytes);

      // 关闭进度对话框
      if (context.mounted) Navigator.pop(context);

      // 打开 APK 安装
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
    } catch (e) {
      debugPrint('下载安装失败: $e');
      if (context.mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('下载失败: $e')),
        );
      }
    }
  }
}

class _DownloadingDialog extends StatelessWidget {
  const _DownloadingDialog();

  @override
  Widget build(BuildContext context) {
    return const AlertDialog(
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text('正在下载更新...'),
        ],
      ),
    );
  }
}
