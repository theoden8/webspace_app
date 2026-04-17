package org.codeberg.theoden8.webspace

import android.content.Intent
import android.graphics.BitmapFactory
import android.os.Build
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterShellArgs
import io.flutter.plugin.common.MethodChannel
import java.net.URL

class MainActivity: FlutterActivity() {
    private val CHANNEL = "org.codeberg.theoden8.webspace/shortcuts"
    private var webInterceptPlugin: WebInterceptPlugin? = null

    override fun getFlutterShellArgs(): FlutterShellArgs {
        val args = FlutterShellArgs.fromIntent(intent)
        // Disable Impeller on x86/x86_64 (Waydroid, emulators) where Vulkan
        // swapchain creation crashes. Falls back to Skia + OpenGL ES which
        // is still hardware-accelerated.
        if (Build.SUPPORTED_ABIS.any { it == "x86_64" || it == "x86" }) {
            args.remove(FlutterShellArgs.ARG_ENABLE_IMPELLER)
            args.add(FlutterShellArgs.ARG_DISABLE_IMPELLER)
        }
        return args
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        webInterceptPlugin = WebInterceptPlugin(this, flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "pinShortcut" -> {
                    val siteId = call.argument<String>("siteId")
                    val label = call.argument<String>("label")
                    val iconUrl = call.argument<String>("iconUrl")

                    if (siteId == null || label == null) {
                        result.error("INVALID_ARGS", "siteId and label are required", null)
                        return@setMethodCallHandler
                    }

                    pinShortcut(siteId, label, iconUrl, result)
                }
                "removeShortcut" -> {
                    val siteId = call.argument<String>("siteId")
                    if (siteId != null) {
                        ShortcutManagerCompat.removeDynamicShortcuts(this, listOf("site_$siteId"))
                        // Also disable the pinned shortcut so it shows as unavailable
                        ShortcutManagerCompat.disableShortcuts(this, listOf("site_$siteId"), "Site has been removed")
                    }
                    result.success(true)
                }
                "getLaunchSiteId" -> {
                    val siteId = intent?.getStringExtra("siteId")
                    result.success(siteId)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun pinShortcut(siteId: String, label: String, iconUrl: String?, result: MethodChannel.Result) {
        if (!ShortcutManagerCompat.isRequestPinShortcutSupported(this)) {
            result.error("NOT_SUPPORTED", "Pinned shortcuts not supported on this device", null)
            return
        }

        Thread {
            try {
                val intent = Intent(this, MainActivity::class.java).apply {
                    action = Intent.ACTION_VIEW
                    putExtra("siteId", siteId)
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                }

                val icon = if (iconUrl != null) {
                    try {
                        val stream = URL(iconUrl).openStream()
                        val bitmap = BitmapFactory.decodeStream(stream)
                        stream.close()
                        if (bitmap != null) IconCompat.createWithBitmap(bitmap) else IconCompat.createWithResource(this, R.mipmap.ic_launcher)
                    } catch (e: Exception) {
                        IconCompat.createWithResource(this, R.mipmap.ic_launcher)
                    }
                } else {
                    IconCompat.createWithResource(this, R.mipmap.ic_launcher)
                }

                val shortcut = ShortcutInfoCompat.Builder(this, "site_$siteId")
                    .setShortLabel(label)
                    .setLongLabel(label)
                    .setIcon(icon)
                    .setIntent(intent)
                    .build()

                val success = ShortcutManagerCompat.requestPinShortcut(this, shortcut, null)
                runOnUiThread {
                    if (success) {
                        result.success(true)
                    } else {
                        result.error("FAILED", "Failed to request pinned shortcut", null)
                    }
                }
            } catch (e: Exception) {
                runOnUiThread {
                    result.error("ERROR", e.message, null)
                }
            }
        }.start()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
    }
}
