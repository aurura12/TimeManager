---
name: flutter-notification-debug
description: Debug Flutter local notification issues on Android, especially MIUI/background delivery failures
---

# Flutter Notification Debugging (Android / MIUI)

This project uses `flutter_local_notifications` + `android_alarm_manager_plus` for scheduled notifications. MIUI (Xiaomi) and other Chinese Android ROMs aggressively kill background alarms.

## Symptom: Notification registered but never appears

### Diagnosis checklist

1. **Check logs** — filter for the notification tag:
   ```
   I/flutter: 写日记提醒到点触发
   I/DailyReviewNotify: Notification posted
   ```
   - If `到点触发` appears but no notification on screen → background delivery issue
   - If `到点触发` never appears → alarm not firing

2. **Check notification channel** — channel must exist and be enabled:
   ```
   I/DailyReviewNotify: Channel[diary_reminder] importance=4, notificationsEnabled=true
   ```

3. **Check MIUI battery settings** — user must set app to "无限制" (unrestricted) in battery optimization

4. **Check notification permission** — Android 13+ needs `POST_NOTIFICATIONS` permission in `AndroidManifest.xml`

### Common root causes

| Cause | Fix |
|-------|-----|
| `setCategoryExpandState` missing `notifyListeners()` | Add `notifyListeners()` call |
| Alarm not re-registered after app restart | Re-register alarms in `didChangeAppLifecycleState` when app resumes |
| `FlutterLocalNotificationsPlugin` not registered on background engine | Use `DailyReviewNativePlugin` to register plugins on alarm engine |
| MIUI kills background alarms | Use `flutter_background_service` instead of `android_alarm_manager_plus`, or set battery to unrestricted |
| Exact alarm降级为inexact | Check `AndroidManifest.xml` for `SCHEDULE_EXACT_ALARM` permission |

### Key files

- `lib/services/daily_review_notification_service.dart` — daily review alarm scheduling
- `lib/services/diary_notification_service.dart` — diary reminder alarm scheduling
- `android/app/src/main/kotlin/.../DailyReviewNativePlugin.kt` — native notification + plugin registration
- `android/app/src/main/kotlin/.../AlarmPluginRegistrar.kt` — registers Flutter plugins on background engine
- `lib/services/daily_review_native.dart` — Dart-side native channel bridge
- `android/app/src/main/AndroidManifest.xml` — notification permissions

### Fallback strategies (in order of preference)

1. Fix alarm registration and battery settings (zero-dependency)
2. Use `flutter_background_service` for persistent foreground service
3. Use third-party push service (Firebase FCM / JPush) as last resort
