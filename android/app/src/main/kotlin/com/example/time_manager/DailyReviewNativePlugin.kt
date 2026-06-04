package com.example.time_manager

import android.content.Context
import android.content.Intent
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class DailyReviewNativePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var appContext: Context

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "com.example.time_manager/daily_review")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "showNotification" -> {
                val title = call.argument<String>("title")
                val body = call.argument<String>("body")
                val dateKey = call.argument<String>("dateKey")
                if (title.isNullOrBlank() || body.isNullOrBlank() || dateKey.isNullOrBlank()) {
                    result.error("invalid_args", "title/body/dateKey required", null)
                    return
                }
                val shown = DailyReviewNotificationHelper.show(
                    appContext,
                    title,
                    body,
                    dateKey,
                )
                result.success(shown)
            }
            "showDiaryNotification" -> {
                val title = call.argument<String>("title")
                val body = call.argument<String>("body")
                if (title.isNullOrBlank() || body.isNullOrBlank()) {
                    result.error("invalid_args", "title/body required", null)
                    return
                }
                val shown = DailyReviewNotificationHelper.showDiary(
                    appContext,
                    title,
                    body,
                )
                result.success(shown)
            }
            "registerAlarmPlugins" -> {
                AlarmPluginRegistrar.registerIfNeeded()
                result.success(true)
            }
            "consumeLaunchReviewDate" -> {
                val date = MainActivity.consumePendingReviewDate()
                result.success(date)
            }
            "consumeLaunchDiaryReminder" -> {
                val value = MainActivity.consumePendingDiaryReminder()
                result.success(value)
            }
            else -> result.notImplemented()
        }
    }
}
