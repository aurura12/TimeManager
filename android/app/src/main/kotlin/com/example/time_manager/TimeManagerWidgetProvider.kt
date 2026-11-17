package com.example.time_manager

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.content.res.ColorStateList
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.net.Uri
import android.os.Build
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
        val theme =
            WidgetTheme.parse(
                widgetData.getString("widget_theme", null),
                isNightMode(context),
            )
        val actionStatus = widgetData.getString("widget_action_status", "")?.trim().orEmpty()
        val actionStatusAt = widgetData.getLong("widget_action_status_at", 0L)
        val actionStatusError = widgetData.getBoolean("widget_action_status_error", false)
        val actionStatusAge = System.currentTimeMillis() - actionStatusAt
        val showActionStatus =
            actionStatus.isNotEmpty() &&
                actionStatusAt > 0L &&
                actionStatusAge in 0..ACTION_STATUS_TTL_MS

        appWidgetIds.forEach { widgetId ->
            val widgetOptions = appWidgetManager.getAppWidgetOptions(widgetId)
            val compact = isCompactWidget(widgetOptions)
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
                    theme.track,
                    theme.nowLine,
                )

            val views =
                RemoteViews(context.packageName, R.layout.time_manager_widget).apply {
                    setTextViewText(R.id.widget_date, date)
                    setTextViewText(R.id.widget_stats, stats)
                    setTextViewText(R.id.widget_top_categories, topCategories)
                    setTextViewText(R.id.widget_current, current)
                    setTextViewText(R.id.widget_next, next)
                    setImageViewBitmap(R.id.widget_timeline, timelineBitmap)

                    // 2 行左右的小尺寸只保留日期、时间轴和快捷入口，避免
                    // 统计/辅助文案把三个可点击入口挤出可视区域。
                    setViewVisibility(
                        R.id.widget_stats,
                        if (compact) View.GONE else View.VISIBLE,
                    )
                    setViewVisibility(
                        R.id.widget_timeline_labels,
                        if (compact) View.GONE else View.VISIBLE,
                    )
                    setViewVisibility(
                        R.id.widget_current_next,
                        if (compact) View.GONE else View.VISIBLE,
                    )
                    setViewVisibility(
                        R.id.widget_top_categories,
                        if (compact) View.GONE else View.VISIBLE,
                    )

                    setViewVisibility(
                        R.id.widget_pending_sync,
                        if (pendingSync) View.VISIBLE else View.GONE,
                    )

                    setTextViewText(R.id.widget_action_status, actionStatus)
                    setViewVisibility(
                        R.id.widget_action_status,
                        if (showActionStatus && !compact) View.VISIBLE else View.GONE,
                    )

                    // 原有整块点击也明确进入“今日记录”，不再无参数地落到首页。
                    setOnClickPendingIntent(
                        R.id.widget_container,
                        actionPendingIntent(context, ACTION_TODAY_RECORDS),
                    )
                    setOnClickPendingIntent(
                        R.id.widget_action_today,
                        actionPendingIntent(context, ACTION_TODAY_RECORDS),
                    )
                    setOnClickPendingIntent(
                        R.id.widget_action_search,
                        actionPendingIntent(context, ACTION_SEARCH),
                    )
                    setOnClickPendingIntent(
                        R.id.widget_action_sync,
                        actionPendingIntent(context, ACTION_SYNC_CENTER),
                    )
                }
            applyTheme(views, theme, actionStatusError)
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
        private const val ACTION_URI_SCHEME = "time-manager"
        private const val ACTION_URI_HOST = "widget"
        private const val ACTION_TODAY_RECORDS = "today_records"
        private const val ACTION_SEARCH = "search"
        private const val ACTION_SYNC_CENTER = "sync_center"
        private const val COMPACT_HEIGHT_THRESHOLD_DP = 180
        private const val ACTION_STATUS_TTL_MS = 10 * 60 * 1000L
        private const val TEXT_MIN_PADDING_PX = 10f
        private const val WIDGET_HORIZONTAL_PADDING_DP = 20f

        private fun actionPendingIntent(
            context: Context,
            action: String,
        ) = HomeWidgetLaunchIntent.getActivity(
            context,
            MainActivity::class.java,
            Uri.Builder()
                .scheme(ACTION_URI_SCHEME)
                .authority(ACTION_URI_HOST)
                .appendQueryParameter("action", action)
                .build(),
        )

        /** 把配色套到 RemoteViews 上：卡片底/描边换资源，其余直接设颜色。 */
        private fun applyTheme(
            views: RemoteViews,
            theme: WidgetTheme,
            statusIsError: Boolean,
        ) {
            views.setInt(
                R.id.widget_container,
                "setBackgroundResource",
                if (theme.dark) R.drawable.widget_background_dark else R.drawable.widget_background,
            )

            views.setTextColor(R.id.widget_date, theme.title)
            views.setTextColor(R.id.widget_stats, theme.stats)
            views.setTextColor(R.id.widget_current, theme.body)
            views.setTextColor(R.id.widget_next, theme.secondary)
            views.setTextColor(R.id.widget_top_categories, theme.secondary)
            views.setTextColor(R.id.widget_axis_start, theme.axis)
            views.setTextColor(R.id.widget_axis_12, theme.axis)
            views.setTextColor(R.id.widget_axis_18, theme.axis)
            views.setTextColor(R.id.widget_axis_end, theme.axis)
            views.setTextColor(
                R.id.widget_action_status,
                if (statusIsError) theme.statusError else theme.statusSuccess,
            )

            // 徽章本来就是方角纯色，直接换底色即可。
            views.setInt(R.id.widget_pending_sync, "setBackgroundColor", theme.chipBackground)
            views.setTextColor(R.id.widget_pending_sync, theme.chipText)

            val actionIds =
                intArrayOf(
                    R.id.widget_action_search,
                    R.id.widget_action_sync,
                    R.id.widget_action_today,
                )
            val tint = actionTint(theme)
            for (id in actionIds) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    // 平铺 tint 保留 8dp 圆角与按压态，颜色跟着主题色走。
                    views.setColorStateList(id, "setBackgroundTintList", tint)
                } else {
                    // API 31 以下没法设置 ColorStateList：退回静态 selector，
                    // 浅/深对得上，但不跟随自定义主题色。
                    views.setInt(
                        id,
                        "setBackgroundResource",
                        if (theme.dark) {
                            R.drawable.widget_action_background_dark
                        } else {
                            R.drawable.widget_action_background
                        },
                    )
                }
                views.setTextColor(id, theme.actionText)
            }
        }

        private fun actionTint(theme: WidgetTheme) =
            ColorStateList(
                arrayOf(intArrayOf(android.R.attr.state_pressed), intArrayOf()),
                intArrayOf(theme.actionPressed, theme.actionBackground),
            )

        private fun isNightMode(context: Context): Boolean {
            val uiMode = context.resources.configuration.uiMode
            return (uiMode and Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES
        }

        /** 分段色块上的文字：白/黑取对比度更高的一方（同 AppSemanticColors.onColor）。 */
        private fun readableTextOn(background: Int): Int {
            val luminance = Color.luminance(background)
            val onWhite = 1.05 / (luminance + 0.05)
            val onBlack = (luminance + 0.05) / 0.05
            return if (onWhite >= onBlack) Color.WHITE else Color.BLACK
        }

        private fun isCompactWidget(options: Bundle): Boolean {
            val heightDp = options.getInt(
                AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT,
                options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, 110),
            )
            return heightDp < COMPACT_HEIGHT_THRESHOLD_DP
        }

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
            trackColor: Int,
            nowLineColor: Int,
        ): Bitmap {
            val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bitmap)
            val rectPaint = Paint(Paint.ANTI_ALIAS_FLAG)
            val dayEndMinutes = dayStartMinutes + daySpanMinutes

            rectPaint.color = trackColor
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

                // 分段色板里有浅金、浅青，固定白字只有 2:1 左右；按底色取白/黑。
                textPaint.color = readableTextOn(segment.color)
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
                    rectPaint.color = nowLineColor
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
