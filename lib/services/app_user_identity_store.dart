import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../models/google_calendar_user.dart';

/// 持久保存「曾登录过的用户身份」，不因网络/token 失效而清除。
/// 仅在用户主动退出 Google 登录时清除。
class AppUserIdentityStore {
  static const _storage = FlutterSecureStorage();
  static const _emailKey = 'app_user_identity_email';
  static const _idKey = 'app_user_identity_id';
  static const _nameKey = 'app_user_identity_display_name';
  static const _photoKey = 'app_user_identity_photo_url';

  static Future<void> save(GoogleSignInAccount account) async {
    await saveUser(GoogleCalendarUser.fromAccount(account));
  }

  static Future<void> saveUser(GoogleCalendarUser user) async {
    await _storage.write(key: _emailKey, value: user.email);
    await _storage.write(key: _idKey, value: user.id);
    await _storage.write(
      key: _nameKey,
      value: user.displayName ?? '',
    );
    await _storage.write(
      key: _photoKey,
      value: user.photoUrl ?? '',
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
    ).withResolvedNickname();
  }

  static Future<void> clear() async {
    await _storage.delete(key: _emailKey);
    await _storage.delete(key: _idKey);
    await _storage.delete(key: _nameKey);
    await _storage.delete(key: _photoKey);
  }
}
