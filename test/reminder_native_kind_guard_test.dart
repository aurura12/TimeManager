import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:time_manager/services/time_block_reminder_service.dart';
import 'package:time_manager/utils/time_block_reminder_plan.dart';

/// 源码守卫：Dart 常量、原生归属判定与 drawable 图标必须同时存在且一致。
///
/// 这三者漏改任意一处都是「编译能过、运行时静默失效」——
/// 原生不记事件（排查时看不到日志）或通知找不到图标（投递失败）。
void main() {
  final javaFile = File(
    'third_party/flutter_local_notifications/android/src/main/java/'
    'com/dexterous/flutterlocalnotifications/DiaryReminderNativeEventStore.java',
  );

  test('原生 kindOf 的时间块常量与 Dart 保持逐字一致', () {
    final java = javaFile.readAsStringSync();
    expect(java, contains('TIME_BLOCK_ID_MIN = $timeBlockReminderIdBase'));
    expect(java, contains('TIME_BLOCK_ID_MAX = $timeBlockReminderIdMax'));
    expect(java, contains('TIME_BLOCK_PAYLOAD_PREFIX = "time_block_reminder:"'));
    expect(java, contains('KIND_TIME_BLOCK = "time_block_reminder"'));
    expect(java, contains('details.payload.startsWith(TIME_BLOCK_PAYLOAD_PREFIX)'));
    expect(TimeBlockReminderService.notificationIdMin, timeBlockReminderIdBase);
    expect(TimeBlockReminderService.notificationIdMax, timeBlockReminderIdMax);
  });

  test('三类提醒的 id 段互不相交', () {
    const diaryIds = <int>[2001, 2002];
    const checkInMin = 2200;
    const checkInMax = 2299;
    for (final id in diaryIds) {
      expect(id < checkInMin || id > checkInMax, isTrue);
      expect(id < timeBlockReminderIdBase, isTrue);
    }
    expect(checkInMax < timeBlockReminderIdBase, isTrue);
    expect(TimeBlockReminderService.testNotificationId, 2399);
    expect(TimeBlockReminderService.testNotificationId < timeBlockReminderIdBase, isTrue);
  });

  test('通知小图标存在', () {
    final icon = File(
      'android/app/src/main/res/drawable/'
      '${TimeBlockReminderService.smallIcon}.xml',
    );
    expect(icon.existsSync(), isTrue);
    expect(TimeBlockReminderService.smallIcon, 'ic_stat_time_block_reminder');
  });
}
