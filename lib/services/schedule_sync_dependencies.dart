import 'diary_local_store.dart';
import 'schedule_gitee_service.dart';

typedef ScheduleTokenLoader = Future<String?> Function();
typedef SchedulePathLoader = Future<ScheduleGiteeListWithShaResult> Function({
  required String token,
  required String userCode,
});
typedef ScheduleDayLoader = Future<ScheduleGiteePullResult> Function({
  required String token,
  required String dateKey,
  required String userCode,
});

class ScheduleSyncDependencies {
  const ScheduleSyncDependencies({
    required this.loadToken,
    required this.listPaths,
    required this.pullDay,
  });

  final ScheduleTokenLoader loadToken;
  final SchedulePathLoader listPaths;
  final ScheduleDayLoader pullDay;

  factory ScheduleSyncDependencies.production() {
    return ScheduleSyncDependencies(
      loadToken: DiaryLocalStore.loadToken,
      listPaths: ScheduleGiteeService.listSchedulePathsWithSha,
      pullDay: ScheduleGiteeService.pullSchedule,
    );
  }
}
