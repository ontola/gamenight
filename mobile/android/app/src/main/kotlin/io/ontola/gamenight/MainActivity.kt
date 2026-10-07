package io.ontola.gamenight

import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.net.HttpURLConnection
import java.net.URL

/// Lets GameNight act as the store for games' own phone apps: it downloads
/// the APK from the GameNight computer and installs it through Android's
/// PackageInstaller. Android asks once to allow installs from GameNight and
/// confirms each first install; updates of apps GameNight installed itself
/// go through without asking on Android 12 and newer.
class MainActivity : FlutterActivity() {
    private val main = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "gamenight/apps")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "installed" -> result.success(versionOf(call.argument<String>("package")!!))
                    "open" -> {
                        val intent = packageManager.getLaunchIntentForPackage(call.argument<String>("package")!!)
                        if (intent == null) {
                            result.success(false)
                        } else {
                            startActivity(intent)
                            result.success(true)
                        }
                    }
                    "canInstall" -> result.success(
                        Build.VERSION.SDK_INT < Build.VERSION_CODES.O || packageManager.canRequestPackageInstalls()
                    )
                    "allowInstalls" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startActivity(
                                Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName"))
                            )
                        }
                        result.success(null)
                    }
                    "install" -> {
                        val url = call.argument<String>("url")!!
                        val pkg = call.argument<String>("package")!!
                        Thread {
                            try {
                                install(url, pkg)
                                main.post { result.success(null) }
                            } catch (e: Exception) {
                                main.post { result.error("install", e.message ?: e.toString(), null) }
                            }
                        }.start()
                    }
                    "view" -> {
                        startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(call.argument<String>("url")!!)))
                        result.success(null)
                    }
                    "status" -> result.success(InstallReceiver.status[call.argument<String>("package")!!])
                    else -> result.notImplemented()
                }
            }
    }

    private fun versionOf(pkg: String): String? = try {
        packageManager.getPackageInfo(pkg, 0).versionName ?: ""
    } catch (e: PackageManager.NameNotFoundException) {
        null
    }

    private fun install(url: String, pkg: String) {
        InstallReceiver.status.remove(pkg)
        val installer = packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
        params.setAppPackageName(pkg)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            params.setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
        }
        val id = installer.createSession(params)
        val session = installer.openSession(id)
        try {
            val conn = URL(url).openConnection() as HttpURLConnection
            conn.connectTimeout = 10_000
            conn.readTimeout = 30_000
            if (conn.responseCode != 200) throw Exception("download failed: HTTP ${conn.responseCode}")
            val size = conn.contentLengthLong
            conn.inputStream.use { input ->
                session.openWrite("game.apk", 0, size).use { out ->
                    input.copyTo(out)
                    session.fsync(out)
                }
            }
            val callback = Intent(this, InstallReceiver::class.java).putExtra("package", pkg)
            var flags = PendingIntent.FLAG_UPDATE_CURRENT
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) flags = flags or PendingIntent.FLAG_MUTABLE
            session.commit(PendingIntent.getBroadcast(this, id, callback, flags).intentSender)
            session.close()
        } catch (e: Exception) {
            session.abandon()
            throw e
        }
    }
}
