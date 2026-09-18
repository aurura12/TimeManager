package com.dexterous.flutterlocalnotifications;

import android.content.Context;
import android.content.SharedPreferences;
import android.util.Log;

import com.dexterous.flutterlocalnotifications.models.NotificationDetails;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.util.Collection;
import java.util.HashSet;
import java.util.Set;

/**
 * 写日记提醒的原生事件队列（本地 fork 新增）。
 *
 * <p>到点时 Dart 不运行，AppLogService 收不到任何回调，所以由原生 receiver 把触发、通知提交、
 * 下次登记和开机恢复的结果写进一个有界队列，App 启动或回到前台时再导入到「运行日志」。
 *
 * <p>只记录通知 ID 2001 / payload diary_reminder 的事件，不写通知正文或任何用户数据。
 * 队列使用独立 SharedPreferences 文件，不污染 Flutter 自己的偏好存储。
 *
 * <p>读取使用「不清空 + 按 ID 确认」语义：Dart 侧只有把日志真正持久化成功后才确认，
 * 失败的事件留在队列里等下次重试，不会因为一次写入失败就静默丢失。
 */
public final class DiaryReminderNativeEventStore {

  public static final int DIARY_NOTIFICATION_ID = 2001;
  public static final String DIARY_PAYLOAD = "diary_reminder";

  /** 打卡提醒：id 段 2200–2299，payload 形如 check_in_reminder:<goalId>。 */
  public static final int CHECK_IN_ID_MIN = 2200;
  public static final int CHECK_IN_ID_MAX = 2299;
  public static final String CHECK_IN_PAYLOAD_PREFIX = "check_in_reminder:";

  /** 事件归属的提醒类型，写进事件的 kind 字段，Dart 侧据此选文案。 */
  public static final String KIND_DIARY = "diary_reminder";
  public static final String KIND_CHECK_IN = "check_in_reminder";

  // 事件码，与 Dart 侧 DiaryReminderDiagnostics 的映射保持一致
  public static final String RECEIVER_FIRED = "receiver_fired";
  public static final String NOTIFY_RETURNED = "notify_returned";
  public static final String NOTIFY_FAILED = "notify_failed";
  public static final String NEXT_SCHEDULE_ATTEMPT = "next_schedule_attempt";
  public static final String NEXT_SCHEDULE_RETURNED = "next_schedule_returned";
  public static final String NEXT_SCHEDULE_FAILED = "next_schedule_failed";
  public static final String BOOT_RESCHEDULE_ATTEMPT = "boot_reschedule_attempt";
  public static final String BOOT_RESCHEDULE_RETURNED = "boot_reschedule_returned";
  public static final String BOOT_RESCHEDULE_FAILED = "boot_reschedule_failed";

  private static final String TAG = "DiaryReminderEvents";
  private static final String PREFS_NAME = "diary_reminder_native_events";
  private static final String KEY_EVENTS = "events";
  private static final String KEY_DROPPED = "dropped";
  private static final String KEY_SEQUENCE = "sequence";

  /** 队列上限。超出后丢弃最旧事件并累计丢弃数，避免无限增长。 */
  private static final int MAX_EVENTS = 50;

  private DiaryReminderNativeEventStore() {}

  /**
   * 该通知属于哪一类提醒；不属于任何一类时返回 null（不记事件）。
   *
   * <p>这是唯一的归属判定入口，所有埋点都走它，新增提醒类型只需在这里加一段。
   */
  public static String kindOf(NotificationDetails details) {
    if (details == null || details.id == null) {
      return null;
    }
    if (details.id == DIARY_NOTIFICATION_ID && DIARY_PAYLOAD.equals(details.payload)) {
      return KIND_DIARY;
    }
    if (details.id >= CHECK_IN_ID_MIN
        && details.id <= CHECK_IN_ID_MAX
        && details.payload != null
        && details.payload.startsWith(CHECK_IN_PAYLOAD_PREFIX)) {
      return KIND_CHECK_IN;
    }
    return null;
  }

  public static void record(Context context, String code, String kind) {
    record(context, code, kind, null);
  }

  /**
   * 记录一条事件。使用同步提交并检查返回值：提交失败时写 Logcat 作为兜底，
   * 因为此时 Dart 侧还读不到数据。
   */
  public static synchronized void record(
      Context context, String code, String kind, String detail) {
    if (context == null || code == null || kind == null) {
      return;
    }
    try {
      Context appContext = context.getApplicationContext();
      SharedPreferences prefs =
          appContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE);

      long sequence = prefs.getLong(KEY_SEQUENCE, 0L) + 1L;
      int dropped = prefs.getInt(KEY_DROPPED, 0);

      JSONArray events = parseEvents(prefs.getString(KEY_EVENTS, null));

      JSONObject event = new JSONObject();
      event.put("id", "dr-" + sequence);
      event.put("at", System.currentTimeMillis());
      event.put("code", code);
      event.put("kind", kind);
      if (detail != null && !detail.isEmpty()) {
        event.put("detail", detail);
      }
      events.put(event);

      while (events.length() > MAX_EVENTS) {
        events.remove(0);
        dropped++;
      }

      boolean committed =
          prefs
              .edit()
              .putString(KEY_EVENTS, events.toString())
              .putLong(KEY_SEQUENCE, sequence)
              .putInt(KEY_DROPPED, dropped)
              .commit();
      if (!committed) {
        Log.e(TAG, "事件队列提交失败，事件可能丢失: " + code);
      }
    } catch (Throwable error) {
      // 埋点绝不能影响通知本身的投递
      Log.e(TAG, "写入原生事件失败: " + code, error);
    }
  }

  /**
   * 读取待导入事件，<b>不清空队列</b>。
   *
   * @return {"dropped":N,"events":[{"id","at","code","detail"}...]} 的 JSON 字符串
   */
  public static synchronized String readPending(Context context) {
    JSONObject result = new JSONObject();
    try {
      Context appContext = context.getApplicationContext();
      SharedPreferences prefs =
          appContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE);

      result.put("events", parseEvents(prefs.getString(KEY_EVENTS, null)));
      result.put("dropped", prefs.getInt(KEY_DROPPED, 0));
    } catch (Throwable error) {
      Log.e(TAG, "读取原生事件失败", error);
      try {
        result.put("events", new JSONArray());
        result.put("dropped", 0);
      } catch (JSONException ignored) {
        // 不会发生：放入的是空数组
      }
    }
    return result.toString();
  }

  /**
   * 确认已成功持久化的事件，把它们从队列移除。传空集合时只把丢弃计数归零。
   *
   * <p>只在 Dart 侧确认日志写入成功后调用，所以失败的事件会留在队列里等下次重试。
   */
  public static synchronized void ack(Context context, Collection<String> confirmedIds) {
    if (context == null) {
      return;
    }
    try {
      Context appContext = context.getApplicationContext();
      SharedPreferences prefs =
          appContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE);

      JSONArray events = parseEvents(prefs.getString(KEY_EVENTS, null));
      JSONArray remaining = new JSONArray();
      Set<String> confirmed =
          confirmedIds == null ? new HashSet<>() : new HashSet<>(confirmedIds);

      for (int i = 0; i < events.length(); i++) {
        JSONObject item = events.optJSONObject(i);
        if (item == null) {
          continue;
        }
        if (!confirmed.contains(item.optString("id"))) {
          remaining.put(item);
        }
      }

      boolean committed =
          prefs
              .edit()
              .putString(KEY_EVENTS, remaining.toString())
              // 丢弃计数随本次确认一起归零，避免每次导入重复告警
              .putInt(KEY_DROPPED, 0)
              .commit();
      if (!committed) {
        Log.e(TAG, "确认原生事件失败，可能重复导入");
      }
    } catch (Throwable error) {
      Log.e(TAG, "确认原生事件时出错", error);
    }
  }

  private static JSONArray parseEvents(String raw) {
    if (raw == null || raw.trim().isEmpty()) {
      return new JSONArray();
    }
    try {
      return new JSONArray(raw);
    } catch (JSONException error) {
      Log.e(TAG, "原生事件队列解析失败，按空队列处理", error);
      return new JSONArray();
    }
  }
}
