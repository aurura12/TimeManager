/// A user-visible snapshot of a schedule pull or overwrite operation.
class ScheduleSyncProgress {
  const ScheduleSyncProgress({
    required this.message,
    required this.completed,
    required this.total,
    this.isFinished = false,
    this.isError = false,
  });

  final String message;
  final int completed;
  final int total;
  final bool isFinished;
  final bool isError;

  double? get value {
    if (total <= 0) return null;
    return (completed / total).clamp(0.0, 1.0);
  }
}
