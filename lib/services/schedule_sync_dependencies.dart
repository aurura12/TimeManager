import 'diary_local_store.dart';
import '../models/calendar_block.dart';
import '../models/time_slot.dart';
import 'google_calendar_service.dart';
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
typedef ScheduleDayPusher = Future<ScheduleGiteePushResult> Function({
  required String token,
  required String dateKey,
  required String userCode,
  required String content,
  required String commitMessage,
});
typedef ScheduleGoogleDayPusher = Future<bool> Function(
  List<TimeSlot> slots,
  DateTime date,
);
typedef ScheduleGoogleDayLoader = Future<List<CalendarBlock>?> Function(
  DateTime date,
);

class ScheduleSyncDependencies {
  const ScheduleSyncDependencies({
    required this.loadToken,
    required this.listPaths,
    required this.pullDay,
    this.pushDay,
    this.pushGoogleDay,
    this.pullGoogleDay,
  });

  final ScheduleTokenLoader loadToken;
  final SchedulePathLoader listPaths;
  final ScheduleDayLoader pullDay;
  final ScheduleDayPusher? pushDay;
  final ScheduleGoogleDayPusher? pushGoogleDay;
  final ScheduleGoogleDayLoader? pullGoogleDay;

  factory ScheduleSyncDependencies.production() {
    return ScheduleSyncDependencies(
      loadToken: DiaryLocalStore.loadToken,
      listPaths: ScheduleGiteeService.listSchedulePathsWithSha,
      pullDay: ScheduleGiteeService.pullSchedule,
      pushDay: ScheduleGiteeService.pushSchedule,
      pushGoogleDay: GoogleCalendarService.syncSlotsToGoogle,
      pullGoogleDay: GoogleCalendarService.fetchExternalEvents,
    );
  }
}
