import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../models/google_calendar_user.dart';
import 'package:google_sign_in/google_sign_in.dart';

/// 持久化 Google 登录档案，供冷启动时配合 authorizationForScopes 恢复会话
class GoogleSessionStore {
  static const _storage = FlutterSecureStorage();
  static const _emailKey = 'google_session_email';
  static const _idKey = 'google_session_id';
  static const _nameKey = 'google_session_display_name';
  static const _photoKey = 'google_session_photo_url';

  static Future<void> save(GoogleSignInAccount account) async {
    await _storage.write(key: _emailKey, value: account.email);
    await _storage.write(key: _idKey, value: account.id);
    await _storage.write(
      key: _nameKey,
      value: account.displayName ?? '',
    );
    await _storage.write(
      key: _photoKey,
      value: account.photoUrl ?? '',
    );
  }

  static Future<GoogleCalendarUser?> load() async {
    final email = await _storage.read(key: _emailKey);
    final id = await _storage.read(key: _idKey);
    if (email == null || email.isEmpty || id == null || id.isEmpty) {
      return null;
    }
    final name = await _storage.read(key: _nameKey);
    final photo = await _storage.read(key: _photoKey);
    return GoogleCalendarUser(
      email: email,
      id: id,
      displayName: name != null && name.isNotEmpty ? name : null,
      photoUrl: photo != null && photo.isNotEmpty ? photo : null,
    );
  }

  static Future<void> clear() async {
    await _storage.delete(key: _emailKey);
    await _storage.delete(key: _idKey);
    await _storage.delete(key: _nameKey);
    await _storage.delete(key: _photoKey);
  }
}
