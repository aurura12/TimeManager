import '../models/remote_sync_platform.dart';

/// 当前仅使用 Gitee 同步。GitHub 代码保留以备后续启用，但固定返回 Gitee。
class RemoteSyncSettings {
  static Future<RemoteSyncPlatform> loadPlatform() async {
    return RemoteSyncPlatform.gitee;
  }
}
