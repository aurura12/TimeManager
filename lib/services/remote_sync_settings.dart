import 'package:shared_preferences/shared_preferences.dart';

import '../models/remote_sync_platform.dart';

class RemoteSyncSettings {
  static const String _platformKey = 'remote_sync_platform';

  static RemoteSyncPlatform _cachedPlatform = RemoteSyncPlatform.gitee;
  static bool _platformLoaded = false;

  static Future<RemoteSyncPlatform> loadPlatform() async {
    if (_platformLoaded) return _cachedPlatform;
    final prefs = await SharedPreferences.getInstance();
    _cachedPlatform =
        RemoteSyncPlatform.fromStorageValue(prefs.getString(_platformKey));
    _platformLoaded = true;
    return _cachedPlatform;
  }

  static Future<void> savePlatform(RemoteSyncPlatform platform) async {
    _cachedPlatform = platform;
    _platformLoaded = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_platformKey, platform.storageValue);
  }
}
