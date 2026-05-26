package com.example.time_manager

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.os.Bundle
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetProvider
import org.json.JSONArray

class TimeManagerWidgetProvider : HomeWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences,
    ) {
        updateAllWidgets(context, appWidgetManager, appWidgetIds, widgetData)
    }

    override fun onAppWidgetOptionsChanged(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int,
        newOptions: Bundle,
    ) {
        val widgetData = es.antonborri.home_widget.HomeWidgetPlugin.getData(context)
        updateAllWidgets(context, appWidgetManager, intArrayOf(appWidgetId), widgetData)
    }

    private fun updateAllWidgets(
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
        val timelineBlocks = widgetData.getString("widget_timeline_blocks", null) ?: "[]"
        val isToday = widgetData.getBoolean("widget_is_today", false)
        val nowMinutes = widgetData.getInt("widget_now_minutes", -1)
        val dayStartMinutes = widgetData.getInt("widget_day_start_minutes", 7 * 60)
        val daySpanMinutes = widgetData.getInt("widget_day_span_minutes", 17 * 60)
        val pendingSync = widgetData.getBoolean("widget_pending_sync", false)

        appWidgetIds.forEach { widgetId ->
            val (bitmapWidth, bitmapHeight) =
                resolveTimelineBitmapSize(context, appWidgetManager, widgetId)

            val timelineBitmap =
                buildTimelineBitmap(
                    timelineBlocks,
                    isToday,
                    nowMinutes,
                    dayStartMinutes,
                    daySpanMinutes,
                    bitmapWidth,
                    bitmapHeight,
                )

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

    private data class TimelineSegment(
        val startMin: Int,
        val endMin: Int,
        val label: String,
        val color: Int,
    )

    companion object {
        private const val EMPTY_COLOR = 0xFFBDBDBD.toInt()
        private const val NOW_LINE_COLOR = 0xFFFFFFFF.toInt()
        private const val TEXT_MIN_PADDING_PX = 10f
        private const val WIDGET_HORIZONTAL_PADDING_DP = 20f

        /** 按小组件实际宽度与 dimen 高度生成位图，避免 ImageView 拉伸导致文字变形 */
        fun resolveTimelineBitmapSize(
            context: Context,
            appWidgetManager: AppWidgetManager,
            appWidgetId: Int,
        ): Pair<Int, Int> {
            val density = context.resources.displayMetrics.density
            val options = appWidgetManager.getAppWidgetOptions(appWidgetId)
            val widgetWidthDp =
                options.getInt(
                    AppWidgetManager.OPTION_APPWIDGET_MAX_WIDTH,
                    options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 250),
                )
            val widthPx =
                ((widgetWidthDp - WIDGET_HORIZONTAL_PADDING_DP) * density)
                    .toInt()
                    .coerceAtLeast(100)
            val heightPx =
                context.resources.getDimensionPixelSize(R.dimen.widget_timeline_height)
            return widthPx to heightPx
        }

        fun buildTimelineBitmap(
            blocksJson: String,
            isToday: Boolean,
            nowMinutes: Int,
            dayStartMinutes: Int,
            daySpanMinutes: Int,
            width: Int,
            height: Int,
        ): Bitmap {
            val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bitmap)
            val rectPaint = Paint(Paint.ANTI_ALIAS_FLAG)
            val dayEndMinutes = dayStartMinutes + daySpanMinutes

            rectPaint.color = EMPTY_COLOR
            canvas.drawRect(0f, 0f, width.toFloat(), height.toFloat(), rectPaint)

            val textSize = (height * 0.42f).coerceIn(16f, 26f)
            val textPaint =
                Paint(Paint.ANTI_ALIAS_FLAG).apply {
                    color = Color.WHITE
                    this.textSize = textSize
                    textAlign = Paint.Align.CENTER
                    isFakeBoldText = true
                }

            val segments = parseTimelineSegments(blocksJson)
            for (segment in segments) {
                val clipStart = maxOf(segment.startMin, dayStartMinutes)
                val clipEnd = minOf(segment.endMin, dayEndMinutes)
                if (clipEnd <= clipStart) continue

                val left =
                    ((clipStart - dayStartMinutes).toFloat() / daySpanMinutes) * width
                val right =
                    ((clipEnd - dayStartMinutes).toFloat() / daySpanMinutes) * width
                if (right - left < 1f) continue

                rectPaint.color = segment.color
                canvas.drawRect(left, 0f, right, height.toFloat(), rectPaint)

                val label = segment.label
                val textWidth = textPaint.measureText(label)
                if (textWidth + TEXT_MIN_PADDING_PX <= right - left) {
                    val centerX = (left + right) / 2f
                    val centerY = height / 2f - (textPaint.descent() + textPaint.ascent()) / 2f
                    canvas.drawText(label, centerX, centerY, textPaint)
                }
            }

            if (isToday && nowMinutes >= 0 && daySpanMinutes > 0) {
                if (nowMinutes in dayStartMinutes..dayEndMinutes) {
                    val x =
                        ((nowMinutes - dayStartMinutes).toFloat() / daySpanMinutes) * width
                    rectPaint.color = NOW_LINE_COLOR
                    rectPaint.strokeWidth = 3f
                    canvas.drawLine(x, 0f, x, height.toFloat(), rectPaint)
                }
            }

            return bitmap
        }

        private fun parseTimelineSegments(json: String): List<TimelineSegment> {
            return try {
                val array = JSONArray(json)
                buildList {
                    for (i in 0 until array.length()) {
                        val obj = array.getJSONObject(i)
                        add(
                            TimelineSegment(
                                startMin = obj.getInt("s"),
                                endMin = obj.getInt("e"),
                                label = obj.getString("l"),
                                color = obj.getInt("c"),
                            ),
                        )
                    }
                }
            } catch (_: Exception) {
                emptyList()
            }
        }
    }
}
