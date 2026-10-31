import 'diary_kind.dart';

/// 一次日记冲突的快照：本地草稿 + 远端当前版本。
///
/// 只存在内存里：重启后冲突会由下一次拉取 / 推送重新发现，不做持久化，
/// 避免留下过期数据。
class DiaryConflictEntry {
  const DiaryConflictEntry({
    required this.kind,
    required this.date,
    required this.remotePath,
    required this.remoteSha,
    required this.remoteBody,
    required this.localBody,
  });

  final DiaryKind kind;
  final DateTime date;
  final String remotePath;

  /// 打开冲突页时远端的版本号，用于提交前再次校验。
  final String remoteSha;

  /// 远端正文（已去掉 front matter）。
  final String remoteBody;

  /// 本地正文，取自编辑器。
  final String localBody;
}

/// 用户在冲突页做出的选择。
sealed class DiaryConflictDecision {
  const DiaryConflictDecision();
}

/// 保留本机内容，覆盖远端。
final class DiaryKeepLocal extends DiaryConflictDecision {
  const DiaryKeepLocal();
}

/// 放弃本机修改，采用远端内容。
final class DiaryUseRemote extends DiaryConflictDecision {
  const DiaryUseRemote();
}

/// 使用合并后的正文（已经过用户确认或编辑）。
final class DiaryUseMerged extends DiaryConflictDecision {
  const DiaryUseMerged(this.body);

  final String body;
}
