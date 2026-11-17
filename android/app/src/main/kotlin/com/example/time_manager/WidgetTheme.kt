package com.example.time_manager

import org.json.JSONObject

/**
 * 小组件配色。键名与 Dart 侧 `HomeWidgetPalette.toJson()` 一一对应。
 *
 * 卡片底色与描边不在这里：它们是 `widget_background` / `widget_background_dark`
 * 两份 shape 资源，RemoteViews 没法在运行期拼「圆角 + 描边」的 drawable。
 */
internal data class WidgetTheme(
    val dark: Boolean,
    val title: Int,
    val stats: Int,
    val body: Int,
    val secondary: Int,
    val axis: Int,
    val chipBackground: Int,
    val chipText: Int,
    val actionBackground: Int,
    val actionPressed: Int,
    val actionText: Int,
    val track: Int,
    val nowLine: Int,
    val statusSuccess: Int,
    val statusError: Int,
) {
    companion object {
        private const val SCHEMA_VERSION = 1

        /** 没有任何外观数据（旧版本 App / 首次添加）时，回到改动前的浅色配色。 */
        fun defaults(dark: Boolean): WidgetTheme =
            if (dark) {
                WidgetTheme(
                    dark = true,
                    title = 0xFFE6E9E4.toInt(),
                    stats = 0xFF9CB86A.toInt(),
                    body = 0xFFDCE0DB.toInt(),
                    secondary = 0xFFA8B0AA.toInt(),
                    axis = 0xFF8A928C.toInt(),
                    chipBackground = 0xFF4A3A20.toInt(),
                    chipText = 0xFFFFB68A.toInt(),
                    actionBackground = 0xFF2E3A26.toInt(),
                    actionPressed = 0xFF3A4A30.toInt(),
                    actionText = 0xFFD6E7C2.toInt(),
                    track = 0xFF2B312D.toInt(),
                    nowLine = 0xFFFFB4AB.toInt(),
                    statusSuccess = 0xFFA8C87F.toInt(),
                    statusError = 0xFFFFB4AB.toInt(),
                )
            } else {
                WidgetTheme(
                    dark = false,
                    title = 0xFF212121.toInt(),
                    stats = 0xFF9CB86A.toInt(),
                    body = 0xFF424242.toInt(),
                    secondary = 0xFF757575.toInt(),
                    axis = 0xFF9E9E9E.toInt(),
                    chipBackground = 0xFFFFF3E0.toInt(),
                    chipText = 0xFFE65100.toInt(),
                    actionBackground = 0xFFEEF5E8.toInt(),
                    actionPressed = 0xFFDDEBCF.toInt(),
                    actionText = 0xFF42612A.toInt(),
                    track = 0xFFBDBDBD.toInt(),
                    nowLine = 0xFFFFFFFF.toInt(),
                    statusSuccess = 0xFF558B2F.toInt(),
                    statusError = 0xFFC62828.toInt(),
                )
            }

        /**
         * 解析 Dart 下发的 `widget_theme`。
         *
         * 两套配色一起下发，`sys` 为真时按系统夜色选包：App 进程不在时
         * `updatePeriodMillis` / 改尺寸 / 开机触发的重绘也能拿到正确颜色。
         * 任何异常都退回 [defaults]，宁可旧配色也不要花屏。
         */
        fun parse(raw: String?, nightMode: Boolean): WidgetTheme {
            if (raw.isNullOrBlank()) return defaults(dark = false)

            val json =
                try {
                    JSONObject(raw)
                } catch (_: Exception) {
                    return defaults(dark = false)
                }
            if (json.optInt("v", 0) != SCHEMA_VERSION) return defaults(dark = false)

            val followsSystem = json.optBoolean("sys", false)
            val dark =
                if (followsSystem) {
                    nightMode
                } else {
                    json.optString("mode", "light") == "dark"
                }
            val fallback = defaults(dark)
            val section = json.optJSONObject(if (dark) "dark" else "light") ?: return fallback

            return fallback.copy(
                title = section.colorOr("title", fallback.title),
                stats = section.colorOr("stats", fallback.stats),
                body = section.colorOr("body", fallback.body),
                secondary = section.colorOr("secondary", fallback.secondary),
                axis = section.colorOr("axis", fallback.axis),
                chipBackground = section.colorOr("chipBg", fallback.chipBackground),
                chipText = section.colorOr("chipText", fallback.chipText),
                actionBackground = section.colorOr("actionBg", fallback.actionBackground),
                actionPressed = section.colorOr("actionPressed", fallback.actionPressed),
                actionText = section.colorOr("actionText", fallback.actionText),
                track = section.colorOr("track", fallback.track),
                nowLine = section.colorOr("nowLine", fallback.nowLine),
                statusSuccess = section.colorOr("statusOk", fallback.statusSuccess),
                statusError = section.colorOr("statusError", fallback.statusError),
            )
        }

        /**
         * Dart 写的是无符号 ARGB（≤ 4294967295），org.json 会解析成 Long，
         * 这里截断回 Int 正好还原颜色。
         */
        private fun JSONObject.colorOr(key: String, fallback: Int): Int =
            optLong(key, fallback.toLong()).toInt()
    }
}
