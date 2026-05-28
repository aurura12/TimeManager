import 'package:google_sign_in/google_sign_in.dart';

/// 用于 UI 展示的 Google 账号信息（可与 [GoogleSignInAccount] 解耦）
class GoogleCalendarUser {
  final String email;
  final String id;
  final String? displayName;
  final String? photoUrl;

  const GoogleCalendarUser({
    required this.email,
    required this.id,
    this.displayName,
    this.photoUrl,
  });

  factory GoogleCalendarUser.fromAccount(GoogleSignInAccount account) {
    return GoogleCalendarUser(
      email: account.email,
      id: account.id,
      displayName: account.displayName,
      photoUrl: account.photoUrl,
    );
  }
}
