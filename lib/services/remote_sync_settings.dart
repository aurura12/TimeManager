import 'package:shared_preferences/shared_preferences.dart';

import '../models/remote_sync_platform.dart';

class RemoteSyncSettings {
  static const String _platformKey = 'remote_sync_platform';
  static const String _googleCalendarEnabledKey =
      'google_calendar_sync_enabled';

  static RemoteSyncPlatform _cachedPlatform = RemoteSyncPlatform.gitee;
  static bool _platformLoaded = false;

  static bool _cachedGoogleCalendarEnabled = true;
  static bool _googleCalendarLoaded = false;

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

  static Future<bool> isGoogleCalendarEnabled() async {
    if (_googleCalendarLoaded) return _cachedGoogleCalendarEnabled;
    final prefs = await SharedPreferences.getInstance();
    _cachedGoogleCalendarEnabled =
        prefs.getBool(_googleCalendarEnabledKey) ?? true;
    _googleCalendarLoaded = true;
    return _cachedGoogleCalendarEnabled;
  }

  static Future<void> setGoogleCalendarEnabled(bool enabled) async {
    _cachedGoogleCalendarEnabled = enabled;
    _googleCalendarLoaded = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_googleCalendarEnabledKey, enabled);
  }
}
