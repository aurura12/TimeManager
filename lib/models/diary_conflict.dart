import 'diary_kind.dart';

/// 一条「远端已更新 + 本地还有未上传修改」的冲突记录。
///
/// 只存在内存里：重启后冲突会由下一次拉取 / 推送重新发现，不做持久化，
/// 避免留下过期数据。这里只保留「哪篇有冲突」，正文和版本号在打开冲突页
/// 时重新读取，保证对比的是远端当前版本。
class DiaryConflictEntry {
  const DiaryConflictEntry({
    required this.kind,
    required this.date,
    required this.remotePath,
  });

  final DiaryKind kind;
  final DateTime date;
  final String remotePath;
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
