package com.example.time_manager

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    companion object {
        private var pendingReviewDate: String? = null
        private var pendingDiaryReminder: String? = null

        fun consumePendingReviewDate(): String? {
            val date = pendingReviewDate
            pendingReviewDate = null
            return date
        }

        fun consumePendingDiaryReminder(): String? {
            val value = pendingDiaryReminder
            pendingDiaryReminder = null
            return value
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(DailyReviewNativePlugin())
    }

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        captureExtras(intent)
        super.onCreate(savedInstanceState)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        captureExtras(intent)
    }

    private fun captureExtras(intent: Intent?) {
        val date = intent?.getStringExtra(DailyReviewNotificationHelper.EXTRA_REVIEW_DATE)
        if (!date.isNullOrBlank()) {
            pendingReviewDate = date
        }
        val diary = intent?.getStringExtra(DailyReviewNotificationHelper.EXTRA_DIARY_REMINDER)
        if (!diary.isNullOrBlank()) {
            pendingDiaryReminder = diary
        }
    }
}
