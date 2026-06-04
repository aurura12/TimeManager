package com.example.time_manager

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat

object DailyReviewNotificationHelper {
    private const val TAG = "DailyReviewNotify"
    const val EXTRA_REVIEW_DATE = "daily_review_date"
    const val EXTRA_DIARY_REMINDER = "diary_reminder"
    const val ACTION_DIARY_TAP = "com.example.time_manager.DIARY_TAP"
    const val ACTION_REVIEW_TAP = "com.example.time_manager.REVIEW_TAP"

    private const val REVIEW_CHANNEL_ID = "daily_review_v2"
    private const val REVIEW_CHANNEL_NAME = "每日复盘"
    private const val REVIEW_NOTIFICATION_ID = 1001

    private const val DIARY_CHANNEL_ID = "diary_reminder"
    private const val DIARY_CHANNEL_NAME = "写日记提醒"
    private const val DIARY_NOTIFICATION_ID = 1002

    fun show(
        context: Context,
        title: String,
        body: String,
        dateKey: String,
    ): Boolean {
        return postNotification(
            context, REVIEW_CHANNEL_ID, REVIEW_CHANNEL_NAME, "每日复盘提醒",
            REVIEW_NOTIFICATION_ID, title, body,
            ACTION_REVIEW_TAP, EXTRA_REVIEW_DATE, dateKey,
        )
    }

    fun showDiary(
        context: Context,
        title: String,
        body: String,
    ): Boolean {
        return postNotification(
            context, DIARY_CHANNEL_ID, DIARY_CHANNEL_NAME, "写日记提醒",
            DIARY_NOTIFICATION_ID, title, body,
            ACTION_DIARY_TAP, EXTRA_DIARY_REMINDER, "diary_reminder",
        )
    }

    private fun postNotification(
        context: Context,
        channelId: String, channelName: String, description: String,
        notificationId: Int,
        title: String, body: String,
        tapAction: String, extraKey: String, extraValue: String,
    ): Boolean {
        val appContext = context.applicationContext

        ensureChannel(appContext, channelId, channelName, description)

        val nm = appContext.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val ch = nm.getNotificationChannel(channelId)
        val compat = NotificationManagerCompat.from(appContext)
        Log.i(TAG, "Channel[$channelId] importance=${ch?.importance}, " +
                "enabled=${compat.areNotificationsEnabled()}")

        // 使用 Broadcast PendingIntent 代替 Activity PendingIntent
        // MIUI 对 Activity PendingIntent 的后台限制更严格
        val tapIntent = Intent(tapAction).apply {
            setPackage(appContext.packageName)
            putExtra(extraKey, extraValue)
        }
        val pendingIntent = PendingIntent.getBroadcast(
            appContext,
            notificationId,
            tapIntent,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M)
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            else PendingIntent.FLAG_UPDATE_CURRENT,
        )

        val notification = NotificationCompat.Builder(appContext, channelId)
            .setSmallIcon(R.mipmap.launcher_icon)
            .setContentTitle(title)
            .setContentText(body)
            .setContentIntent(pendingIntent)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setDefaults(NotificationCompat.DEFAULT_ALL)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setShowWhen(true)
            .build()

        try {
            compat.notify(notificationId, notification)
            Log.i(TAG, "Notification[$notificationId] compat.notify done: $title")

            // 确认通知是否真的被接受了
            val active = nm.activeNotifications
            Log.i(TAG, "Active notifications after post: ${active.size}")
            for (an in active) {
                Log.i(TAG, "  active: id=${an.id} pkg=${an.packageName}")
            }
            return true
        } catch (e: SecurityException) {
            Log.e(TAG, "SecurityException: ${e.message}")
            return false
        }
    }

    private fun ensureChannel(
        context: Context,
        channelId: String, channelName: String, description: String,
    ) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return

        val manager =
            context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val existing = manager.getNotificationChannel(channelId)
        if (existing != null && existing.importance == NotificationManager.IMPORTANCE_HIGH) {
            return
        }

        if (existing != null) {
            Log.i(TAG, "Deleting channel $channelId (was importance=${existing.importance})")
            manager.deleteNotificationChannel(channelId)
        }

        val channel = NotificationChannel(
            channelId,
            channelName,
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            this.description = description
            enableVibration(true)
            enableLights(true)
        }
        manager.createNotificationChannel(channel)
        Log.i(TAG, "Channel $channelId created with IMPORTANCE_HIGH")
    }
}

/**
 * 接收通知点击事件，转为打开对应页面
 * 在 AndroidManifest.xml 中注册
 */
class DiaryTapReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val launchIntent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra(DailyReviewNotificationHelper.EXTRA_DIARY_REMINDER, "diary_reminder")
        }
        context.startActivity(launchIntent)
    }
}

class ReviewTapReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val dateKey = intent.getStringExtra(DailyReviewNotificationHelper.EXTRA_REVIEW_DATE)
        val launchIntent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra(DailyReviewNotificationHelper.EXTRA_REVIEW_DATE, dateKey)
        }
        context.startActivity(launchIntent)
    }
}
