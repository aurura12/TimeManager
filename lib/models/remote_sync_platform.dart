enum RemoteSyncPlatform {
  gitee,
  github;

  String get label => switch (this) {
        RemoteSyncPlatform.gitee => 'Gitee',
        RemoteSyncPlatform.github => 'GitHub',
      };
}
