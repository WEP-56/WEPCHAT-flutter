package com.wep.wepchat

import android.content.ActivityNotFoundException
import android.content.pm.PackageManager
import android.content.Intent
import android.net.Uri
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.FileProvider
import java.io.File
import android.content.ContentValues
import android.provider.MediaStore
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "com.wep.wepchat/platform"
    private val downloadChannelName = "com.wep.wepchat/downloads"
    private val downloadNotificationChannel = "wepchat_downloads"
    private var pendingNotification: PendingNotification? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                if (call.method == "openFile") {
                    val path = call.argument<String>("path")
                    if (path.isNullOrBlank()) {
                        result.error("INVALID_PATH", "文件路径为空", null)
                        return@setMethodCallHandler
                    }
                    result.success(openFile(path, call.argument<String>("mimeType")))
                    return@setMethodCallHandler
                }
                if (call.method == "shareFile") {
                    val path = call.argument<String>("path")
                    if (path.isNullOrBlank()) {
                        result.error("INVALID_PATH", "文件路径为空", null)
                        return@setMethodCallHandler
                    }
                    result.success(shareFile(path, call.argument<String>("mimeType")))
                    return@setMethodCallHandler
                }
                if (call.method == "saveFile") {
                    val path = call.argument<String>("path")
                    if (path.isNullOrBlank()) { result.error("INVALID_PATH", "文件路径为空", null); return@setMethodCallHandler }
                    result.success(saveFile(path, call.argument<String>("mimeType"))); return@setMethodCallHandler
                }
                if (call.method == "openExternalUrl") {
                    val value = call.argument<String>("url")
                    if (value.isNullOrBlank()) {
                        result.error("INVALID_URL", "外部链接为空", null)
                    } else {
                        result.success(openExternalUrl(value))
                    }
                    return@setMethodCallHandler
                }
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

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, downloadChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "requestPermission" -> {
                        val pending = PendingNotification(
                            call.argument<Int>("id") ?: 0,
                            call.argument<String>("title") ?: "WePChat 下载",
                            call.argument<String>("body") ?: "",
                            call.argument<Boolean>("done") == true,
                        )
                        result.success(requestNotificationPermission(pending))
                    }
                    "notify" -> {
                        showDownloadNotification(
                            call.argument<Int>("id") ?: 0,
                            call.argument<String>("title") ?: "WePChat 下载",
                            call.argument<String>("body") ?: "",
                            call.argument<Boolean>("done") == true,
                        )
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun openFile(path: String, mimeType: String?): Boolean {
        val file = File(path)
        if (!file.isFile) return false
        val authority = "${applicationContext.packageName}.fileprovider"
        val uri = try {
            FileProvider.getUriForFile(this, authority, file)
        } catch (_: IllegalArgumentException) {
            return false
        }
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, mimeType ?: contentResolver.getType(uri) ?: "application/octet-stream")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        return try {
            startActivity(intent)
            true
        } catch (_: ActivityNotFoundException) {
            false
        }
    }

    private fun shareFile(path: String, mimeType: String?): Boolean {
        val file = File(path)
        if (!file.isFile) return false
        val authority = "${applicationContext.packageName}.fileprovider"
        val uri = try { FileProvider.getUriForFile(this, authority, file) } catch (_: IllegalArgumentException) { return false }
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = mimeType ?: contentResolver.getType(uri) ?: "application/octet-stream"
            putExtra(Intent.EXTRA_STREAM, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        return try { startActivity(Intent.createChooser(intent, "分享文件")); true } catch (_: ActivityNotFoundException) { false }
    }

    private fun saveFile(path: String, mimeType: String?): Boolean {
        val source = File(path); if (!source.isFile || Build.VERSION.SDK_INT < 29) return false
        val image = mimeType?.startsWith("image/") == true
        val values = ContentValues().apply { put(MediaStore.MediaColumns.DISPLAY_NAME, source.name); put(MediaStore.MediaColumns.MIME_TYPE, mimeType ?: "application/octet-stream"); put(MediaStore.MediaColumns.RELATIVE_PATH, if (image) "Pictures/WePChat" else "Download/WePChat"); put(MediaStore.MediaColumns.IS_PENDING, 1) }
        val collection = if (image) MediaStore.Images.Media.EXTERNAL_CONTENT_URI else MediaStore.Downloads.EXTERNAL_CONTENT_URI
        val uri = contentResolver.insert(collection, values) ?: return false
        return try { source.inputStream().use { input -> contentResolver.openOutputStream(uri)!!.use { output -> input.copyTo(output) } }; values.clear(); values.put(MediaStore.MediaColumns.IS_PENDING, 0); contentResolver.update(uri, values, null, null); true } catch (_: Exception) { contentResolver.delete(uri, null, null); false }
    }

    private fun openExternalUrl(rawUrl: String): Boolean {
        val intent = try {
            if (rawUrl.startsWith("intent://", ignoreCase = true)) {
                Intent.parseUri(rawUrl, Intent.URI_INTENT_SCHEME)
            } else {
                Intent(Intent.ACTION_VIEW, Uri.parse(rawUrl))
            }
        } catch (_: Exception) {
            return false
        }
        intent.addCategory(Intent.CATEGORY_BROWSABLE)
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return try {
            startActivity(intent)
            true
        } catch (_: ActivityNotFoundException) {
            val fallback = intent.getStringExtra("browser_fallback_url")
            if (!fallback.isNullOrBlank() && fallback != rawUrl) {
                try {
                    startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(fallback)).apply {
                        addCategory(Intent.CATEGORY_BROWSABLE)
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    })
                    true
                } catch (_: ActivityNotFoundException) {
                    false
                }
            } else {
                false
            }
        }
    }

    private fun requestNotificationPermission(pending: PendingNotification): Boolean {
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission("android.permission.POST_NOTIFICATIONS") != PackageManager.PERMISSION_GRANTED
        ) {
            pendingNotification = pending
            requestPermissions(arrayOf("android.permission.POST_NOTIFICATIONS"), 4101)
            return false
        }
        return true
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != 4101 || grantResults.firstOrNull() != PackageManager.PERMISSION_GRANTED) {
            pendingNotification = null
            return
        }
        pendingNotification?.let {
            showDownloadNotification(it.id, it.title, it.body, it.done)
            pendingNotification = null
        }
    }

    private fun showDownloadNotification(id: Int, title: String, body: String, done: Boolean) {
        if (Build.VERSION.SDK_INT >= 26) {
            val manager = getSystemService(android.app.NotificationManager::class.java)
            manager.createNotificationChannel(
                android.app.NotificationChannel(
                    downloadNotificationChannel,
                    "下载",
                    android.app.NotificationManager.IMPORTANCE_LOW,
                ),
            )
        }
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission("android.permission.POST_NOTIFICATIONS") != PackageManager.PERMISSION_GRANTED
        ) return
        val notification = NotificationCompat.Builder(this, downloadNotificationChannel)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle(title)
            .setContentText(body)
            .setOngoing(!done)
            .setAutoCancel(done)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .build()
        NotificationManagerCompat.from(this).notify(id, notification)
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

private data class PendingNotification(val id: Int, val title: String, val body: String, val done: Boolean)
