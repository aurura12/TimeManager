/// 本 App 仅有的两个 Google 账号及昵称
class KnownGoogleUsers {
  KnownGoogleUsers._();

  static const Map<String, String> nicknamesByEmail = {
    'zjq031115a@gmail.com': '乖乖',
    '1746528702@qq.com': '晶晶',
  };

  static String normalizeEmail(String email) => email.trim().toLowerCase();

  /// 已知账号返回昵称（乖乖/晶晶），未知账号返回 null
  static String? nicknameFor(String email) {
    return nicknamesByEmail[normalizeEmail(email)];
  }

  static bool isKnownEmail(String email) {
    return nicknamesByEmail.containsKey(normalizeEmail(email));
  }

  /// UI 展示名：优先昵称，其次 Google 原名，最后邮箱
  static String displayLabel({
    required String email,
    String? googleDisplayName,
  }) {
    return nicknameFor(email) ??
        (googleDisplayName?.trim().isNotEmpty == true
            ? googleDisplayName!.trim()
            : email);
  }
}
