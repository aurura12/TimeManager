package com.example.time_manager

import android.util.Log
import io.flutter.embedding.engine.FlutterEngine

object AlarmPluginRegistrar {
    private const val TAG = "AlarmPluginRegistrar"
    private var registered = false

    fun registerIfNeeded() {
        if (registered) return

        try {
            val alarmServiceClass =
                Class.forName("dev.fluttercommunity.plus.androidalarmmanager.AlarmService")
            val executorField =
                alarmServiceClass.getDeclaredField("flutterBackgroundExecutor")
            executorField.isAccessible = true
            val executor = executorField.get(null) ?: return

            val engineField =
                executor.javaClass.getDeclaredField("backgroundFlutterEngine")
            engineField.isAccessible = true
            val engine = engineField.get(executor) as? FlutterEngine ?: return

            engine.plugins.add(DailyReviewNativePlugin())
            registered = true
            Log.i(TAG, "DailyReviewNativePlugin registered on alarm engine")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to register alarm background plugins", e)
        }
    }
}
