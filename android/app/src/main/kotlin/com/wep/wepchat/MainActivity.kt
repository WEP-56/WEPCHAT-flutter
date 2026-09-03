package com.wep.wepchat

import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import androidx.core.content.FileProvider
import java.io.File
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "com.wep.wepchat/platform"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                if (call.method != "openDirectory") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }

                val path = call.argument<String>("path")
                if (path.isNullOrBlank()) {
                    result.error("INVALID_PATH", "目录路径为空", null)
                    return@setMethodCallHandler
                }

                val directory = File(path)
                if (!directory.isDirectory) {
                    result.success(false)
                    return@setMethodCallHandler
                }

                val authority = "${applicationContext.packageName}.fileprovider"
                val uri = try {
                    FileProvider.getUriForFile(this, authority, directory)
                } catch (error: IllegalArgumentException) {
                    result.error("URI_ERROR", "目录不在可共享的存储范围内", null)
                    return@setMethodCallHandler
                }

                val opened = tryOpenDirectory(uri, "resource/folder") ||
                    tryOpenDirectory(uri, "vnd.android.document/directory")
                result.success(opened)
            }
    }

    private fun tryOpenDirectory(uri: Uri, mimeType: String): Boolean {
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, mimeType)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        return try {
            startActivity(intent)
            true
        } catch (_: ActivityNotFoundException) {
            false
        }
    }
}
