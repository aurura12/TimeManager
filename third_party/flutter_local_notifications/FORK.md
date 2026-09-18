# flutter_local_notifications（本地 fork）

上游：pub.dev 的 `flutter_local_notifications` **22.3.1**（含 LICENSE，未修改）。
放在这里是为了给「写日记提醒」的原生触发过程埋点，见 `写日记提醒实施方案.md`。

## 为什么需要 fork

到点时 Dart 不运行，`AppLogService` 收不到任何回调，App 无法知道原生接收器跑到哪一步。
要观测这一步只能改插件源码，所以整体 vendor 进来（pub 不支持部分覆盖）。

## 相对上游的改动

只动 `android/` 下的 3 个 Java 文件，Dart 侧（`lib/`）与其它平台代码与上游完全一致。

| 文件 | 改动 |
| --- | --- |
| `DiaryReminderNativeEventStore.java` | **新增**。有界事件队列（最多 50 条，溢出丢最旧并累计丢弃数），独立 SharedPreferences 文件，同步 `commit()` 并检查返回值。只记录通知 ID 2001 / payload `diary_reminder`。 |
| `ScheduledNotificationReceiver.java` | 埋 `receiver_fired`、`notify_returned`/`notify_failed`、`next_schedule_attempt`。 |
| `FlutterLocalNotificationsPlugin.java` | 埋 `next_schedule_returned`/`next_schedule_failed` 与 `boot_reschedule_*`。成功事件刻意记在**内部真正登记完成处**：`scheduleNextNotification` 会吞掉 `ExactAlarmPermissionException`，`zonedScheduleNextNotificationMatchingDateComponents` 在拿不到下次触发时间时会静默 return（这会让「每天重复」永久断链），在外层记成功会把这两种失败误报成成功。 |

对应 Dart 侧：`lib/services/diary_reminder_diagnostics.dart`（读取并导入运行日志）与
`MainActivity.kt` 的 `com.example.time_manager/diary_reminder_events` 通道。

## 读队列的语义

`readPending` **不清空**队列，`ack(ids)` 只移除已被确认持久化的事件。
所以 Dart 侧日志写入失败时事件会留在队列里等下次重试，不会因为一次写入失败就丢掉。

## 升级上游时的做法

1. 重新从 pub 缓存拷一份新版本，仍然排除 `example/` 与插件自带 `test/`
2. 按上表重新施加同样的改动（改动点都有 `本地 fork 埋点` 注释，便于定位）
3. 用 `diff -u` 对比确认改动只有这几处
4. 跑 `flutter analyze`、`flutter test`，并在真机上验证「重启后仍会响」与「到点日志齐全」
