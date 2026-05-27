class DiaryGitHubConfig {
  // 直接把 GitHub PAT 写在这里（仅建议自用）。
  // 例如: 'github_pat_xxx'
  static const String hardcodedToken = '';

  static bool get hasHardcodedToken => hardcodedToken.trim().isNotEmpty;
}
