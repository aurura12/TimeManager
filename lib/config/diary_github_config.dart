class DiaryGitHubConfig {
  // 通过 --dart-define=DIARY_GITHUB_PAT=github_pat_xxx 注入，避免明文入库。
  static const String envToken = String.fromEnvironment('DIARY_GITHUB_PAT');

  static bool get hasEnvToken => envToken.trim().isNotEmpty;
}
