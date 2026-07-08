enum RemoteSyncPlatform {
  gitee,
  github;

  String get storageValue => switch (this) {
        RemoteSyncPlatform.gitee => 'gitee',
        RemoteSyncPlatform.github => 'github',
      };

  String get label => switch (this) {
        RemoteSyncPlatform.gitee => 'Gitee',
        RemoteSyncPlatform.github => 'GitHub',
      };

  static RemoteSyncPlatform fromStorageValue(String? value) {
    switch (value?.trim().toLowerCase()) {
      case 'github':
        return RemoteSyncPlatform.github;
      case 'gitee':
      default:
        return RemoteSyncPlatform.gitee;
    }
  }
}
