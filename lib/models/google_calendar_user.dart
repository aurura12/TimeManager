import 'package:google_sign_in/google_sign_in.dart';

import 'known_google_users.dart';

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

  /// 乖乖 / 晶晶（已知账号）或 displayName / email
  String get label => KnownGoogleUsers.displayLabel(
        email: email,
        googleDisplayName: displayName,
      );

  String get nickname => label;

  factory GoogleCalendarUser.fromAccount(GoogleSignInAccount account) {
    return GoogleCalendarUser(
      email: account.email,
      id: account.id,
      displayName: account.displayName,
      photoUrl: account.photoUrl,
    ).withResolvedNickname();
  }

  /// 已知账号用固定昵称覆盖 Google 原名
  GoogleCalendarUser withResolvedNickname() {
    final nick = KnownGoogleUsers.nicknameFor(email);
    if (nick == null) return this;
    return GoogleCalendarUser(
      email: email,
      id: id,
      displayName: nick,
      photoUrl: photoUrl,
    );
  }

  GoogleCalendarUser copyWith({
    String? email,
    String? id,
    String? displayName,
    String? photoUrl,
  }) {
    return GoogleCalendarUser(
      email: email ?? this.email,
      id: id ?? this.id,
      displayName: displayName ?? this.displayName,
      photoUrl: photoUrl ?? this.photoUrl,
    ).withResolvedNickname();
  }
}
