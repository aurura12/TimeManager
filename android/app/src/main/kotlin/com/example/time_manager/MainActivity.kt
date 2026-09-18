package com.example.time_manager

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.util.Log
import androidx.core.content.FileProvider
import com.dexterous.flutterlocalnotifications.DiaryReminderNativeEventStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.example.time_manager/install_apk"
    private val REMINDER_EVENTS_CHANNEL =
        "com.example.time_manager/diary_reminder_events"
    private val TAG = "MainActivity"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        Log.d(TAG, "configureFlutterEngine: 注册 MethodChannel")

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                Log.d(TAG, "收到调用: ${call.method}")
                if (call.method == "installApk") {
                    val path = call.argument<String>("path")
                    Log.d(TAG, "installApk: path=$path")
                    if (path != null) {
                        try {
                            installApk(path)
                            Log.d(TAG, "installApk: 成功")
                            result.success(true)
                        } catch (e: Exception) {
                            Log.e(TAG, "installApk: 失败", e)
                            result.error("INSTALL_FAILED", e.message, null)
                        }
                    } else {
                        result.error("INVALID_PATH", "Path is null", null)
                    }
                } else {
                    result.notImplemented()
                }
            }

        // 写日记提醒：到点时 Dart 不运行，触发过程由原生 receiver 写进队列，这里只读不给。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, REMINDER_EVENTS_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "readPending" -> {
                        try {
                            result.success(DiaryReminderNativeEventStore.readPending(this))
                        } catch (e: Exception) {
                            Log.e(TAG, "读取提醒事件失败", e)
                            result.error("READ_FAILED", e.message, null)
                        }
                    }
                    "ack" -> {
                        try {
                            val ids = call.argument<List<String>>("ids") ?: emptyList()
                            DiaryReminderNativeEventStore.ack(this, ids)
                            result.success(null)
                        } catch (e: Exception) {
                            Log.e(TAG, "确认提醒事件失败", e)
                            result.error("ACK_FAILED", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun installApk(path: String) {
        val file = File(path)
        Log.d(TAG, "installApk: 文件存在=${file.exists()}, 大小=${file.length()}")

        val uri: Uri = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            FileProvider.getUriForFile(
                this,
                "${packageName}.fileprovider",
                file
            )
        } else {
            Uri.fromFile(file)
        }
        Log.d(TAG, "installApk: uri=$uri")

        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            flags = Intent.FLAG_ACTIVITY_NEW_TASK
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        Log.d(TAG, "installApk: 启动安装界面")
        startActivity(intent)
    }
}
