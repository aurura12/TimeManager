package com.example.time_manager

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetProvider

class TimeManagerWidgetProvider : HomeWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences,
    ) {
        val date = widgetData.getString("widget_date", null) ?: "时间块"
        val stats = widgetData.getString("widget_stats", null) ?: "0 个事件 · 0 分钟"
        val topCategories =
            widgetData.getString("widget_top_categories", null) ?: "今日暂无分类统计"
        val current = widgetData.getString("widget_current", null) ?: "当前：—"
        val next = widgetData.getString("widget_next", null) ?: "接下来：—"
        val hourColors = widgetData.getString("widget_hour_colors", null) ?: ""
        val isToday = widgetData.getBoolean("widget_is_today", false)
        val nowMinutes = widgetData.getInt("widget_now_minutes", -1)
        val dayStartMinutes = widgetData.getInt("widget_day_start_minutes", 7 * 60)
        val daySpanMinutes = widgetData.getInt("widget_day_span_minutes", 17 * 60)
        val pendingSync = widgetData.getBoolean("widget_pending_sync", false)

        val timelineBitmap =
            buildTimelineBitmap(
                hourColors,
                isToday,
                nowMinutes,
                dayStartMinutes,
                daySpanMinutes,
                TIMELINE_WIDTH,
                TIMELINE_HEIGHT,
            )

        appWidgetIds.forEach { widgetId ->
            val views =
                RemoteViews(context.packageName, R.layout.time_manager_widget).apply {
                    setTextViewText(R.id.widget_date, date)
                    setTextViewText(R.id.widget_stats, stats)
                    setTextViewText(R.id.widget_top_categories, topCategories)
                    setTextViewText(R.id.widget_current, current)
                    setTextViewText(R.id.widget_next, next)
                    setImageViewBitmap(R.id.widget_timeline, timelineBitmap)

                    setViewVisibility(
                        R.id.widget_pending_sync,
                        if (pendingSync) View.VISIBLE else View.GONE,
                    )

                    val pendingIntent =
                        HomeWidgetLaunchIntent.getActivity(context, MainActivity::class.java)
                    setOnClickPendingIntent(R.id.widget_container, pendingIntent)
                }
            appWidgetManager.updateAppWidget(widgetId, views)
        }
    }

    companion object {
        private const val TIMELINE_WIDTH = 850
        private const val TIMELINE_HEIGHT = 48
        private const val EMPTY_COLOR = 0xFFBDBDBD.toInt()
        private const val NOW_LINE_COLOR = 0xFFFFFFFF.toInt()

        fun buildTimelineBitmap(
            hourColorsCsv: String,
            isToday: Boolean,
            nowMinutes: Int,
            dayStartMinutes: Int,
            daySpanMinutes: Int,
            width: Int,
            height: Int,
        ): Bitmap {
            val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bitmap)
            val paint = Paint(Paint.ANTI_ALIAS_FLAG)
            val colors = hourColorsCsv.split(',')
            val hourCount = colors.size.coerceAtLeast(1)
            val cellWidth = width / hourCount.toFloat()

            for (h in 0 until hourCount) {
                paint.color = parseHourColor(colors.getOrNull(h))
                canvas.drawRect(h * cellWidth, 0f, (h + 1) * cellWidth, height.toFloat(), paint)
            }

            if (isToday && nowMinutes >= 0 && daySpanMinutes > 0) {
                val endMinutes = dayStartMinutes + daySpanMinutes
                if (nowMinutes in dayStartMinutes..endMinutes) {
                    val x = ((nowMinutes - dayStartMinutes).toFloat() / daySpanMinutes) * width
                    paint.color = NOW_LINE_COLOR
                    paint.strokeWidth = 3f
                    canvas.drawLine(x, 0f, x, height.toFloat(), paint)
                }
            }

            return bitmap
        }

        private fun parseHourColor(token: String?): Int {
            if (token.isNullOrBlank() || token == "0") return EMPTY_COLOR
            return try {
                token.trim().toLong(16).toInt()
            } catch (_: Exception) {
                EMPTY_COLOR
            }
        }
    }
}
