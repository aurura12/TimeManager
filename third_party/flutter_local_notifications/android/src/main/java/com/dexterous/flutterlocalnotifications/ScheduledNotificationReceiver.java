package com.dexterous.flutterlocalnotifications;

import android.app.Notification;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.util.Log;

import androidx.annotation.Keep;
import androidx.core.app.NotificationManagerCompat;

import com.dexterous.flutterlocalnotifications.models.NotificationDetails;
import com.dexterous.flutterlocalnotifications.utils.StringUtils;
import com.google.gson.Gson;
import com.google.gson.reflect.TypeToken;

import java.lang.reflect.Type;

/** Created by michaelbui on 24/3/18. */
@Keep
public class ScheduledNotificationReceiver extends BroadcastReceiver {

  private static final String TAG = "ScheduledNotifReceiver";

  @Override
  @SuppressWarnings("deprecation")
  public void onReceive(final Context context, Intent intent) {
    String notificationDetailsJson =
        intent.getStringExtra(FlutterLocalNotificationsPlugin.NOTIFICATION_DETAILS);
    if (StringUtils.isNullOrEmpty(notificationDetailsJson)) {
      // This logic is needed for apps that used the plugin prior to 0.3.4

      Notification notification;
      int notificationId = intent.getIntExtra("notification_id", 0);

      if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
        notification = intent.getParcelableExtra("notification", Notification.class);
      } else {
        notification = intent.getParcelableExtra("notification");
      }

      if (notification == null) {
        // This means the notification is corrupt
        FlutterLocalNotificationsPlugin.removeNotificationFromCache(context, notificationId);
        Log.e(TAG, "Failed to parse a notification from  Intent. ID: " + notificationId);
        return;
      }

      notification.when = System.currentTimeMillis();
      NotificationManagerCompat notificationManager = NotificationManagerCompat.from(context);
      notificationManager.notify(notificationId, notification);
      boolean repeat = intent.getBooleanExtra("repeat", false);
      if (!repeat) {
        FlutterLocalNotificationsPlugin.removeNotificationFromCache(context, notificationId);
      }
    } else {
      Gson gson = FlutterLocalNotificationsPlugin.buildGson();
      Type type = new TypeToken<NotificationDetails>() {}.getType();
      NotificationDetails notificationDetails = gson.fromJson(notificationDetailsJson, type);

      // 本地 fork 埋点：只针对写日记提醒，只记录阶段结果，不影响原有行为
      final boolean isDiaryReminder =
          DiaryReminderNativeEventStore.isDiaryReminder(notificationDetails);
      if (isDiaryReminder) {
        DiaryReminderNativeEventStore.record(
            context, DiaryReminderNativeEventStore.RECEIVER_FIRED);
      }

      try {
        FlutterLocalNotificationsPlugin.showNotification(context, notificationDetails);
        if (isDiaryReminder) {
          DiaryReminderNativeEventStore.record(
              context, DiaryReminderNativeEventStore.NOTIFY_RETURNED);
        }
      } catch (RuntimeException | Error error) {
        if (isDiaryReminder) {
          DiaryReminderNativeEventStore.record(
              context,
              DiaryReminderNativeEventStore.NOTIFY_FAILED,
              error.getClass().getSimpleName() + ": " + error.getMessage());
        }
        throw error;
      }

      // 注意：成功事件由插件内部在实际登记完成后记录。
      // 这里不能直接记成功——scheduleNextNotification 会吞掉 ExactAlarmPermissionException，
      // 也会在拿不到下次触发时间时静默返回，那样会把失败误报成成功。
      if (isDiaryReminder) {
        DiaryReminderNativeEventStore.record(
            context, DiaryReminderNativeEventStore.NEXT_SCHEDULE_ATTEMPT);
      }
      try {
        FlutterLocalNotificationsPlugin.scheduleNextNotification(context, notificationDetails);
      } catch (RuntimeException | Error error) {
        if (isDiaryReminder) {
          DiaryReminderNativeEventStore.record(
              context,
              DiaryReminderNativeEventStore.NEXT_SCHEDULE_FAILED,
              error.getClass().getSimpleName() + ": " + error.getMessage());
        }
        throw error;
      }
    }
  }
}
