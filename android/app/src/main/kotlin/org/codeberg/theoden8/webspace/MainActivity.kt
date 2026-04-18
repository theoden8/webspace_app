package org.codeberg.theoden8.webspace

import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Build
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterShellArgs
import io.flutter.plugin.common.MethodChannel
import java.net.HttpURLConnection
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
                    val bitmap = downloadBitmap(iconUrl)
                    if (bitmap != null) {
                        IconCompat.createWithBitmap(upscaleIfTiny(bitmap))
                    } else {
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

    // Download a bitmap, following up to 3 redirects and sending a browser
    // User-Agent so sites that block default Java clients still return the
    // icon. Returns null on any failure.
    private fun downloadBitmap(url: String): Bitmap? {
        var current = url
        var redirects = 0
        while (redirects < 3) {
            try {
                val conn = URL(current).openConnection() as HttpURLConnection
                conn.instanceFollowRedirects = false
                conn.connectTimeout = 8000
                conn.readTimeout = 8000
                conn.setRequestProperty(
                    "User-Agent",
                    "Mozilla/5.0 (Android) WebSpace/1.0"
                )
                conn.setRequestProperty("Accept", "image/*,*/*;q=0.8")
                val code = conn.responseCode
                if (code in 300..399) {
                    val location = conn.getHeaderField("Location") ?: return null
                    current = URL(URL(current), location).toString()
                    conn.disconnect()
                    redirects++
                    continue
                }
                if (code != 200) {
                    conn.disconnect()
                    return null
                }
                conn.inputStream.use { stream ->
                    return BitmapFactory.decodeStream(stream)
                }
            } catch (e: Exception) {
                return null
            }
        }
        return null
    }

    // Android's launcher expects icons roughly 108dp (~162-432 px). Favicons
    // at 16-48 px get blurry when the launcher upscales them, so pre-scale
    // small icons with a better filter for a crisper look.
    private fun upscaleIfTiny(bitmap: Bitmap): Bitmap {
        val side = minOf(bitmap.width, bitmap.height)
        if (side >= 128) return bitmap
        val targetSide = 192
        val scale = targetSide.toFloat() / side
        val newW = (bitmap.width * scale).toInt().coerceAtLeast(targetSide)
        val newH = (bitmap.height * scale).toInt().coerceAtLeast(targetSide)
        return try {
            Bitmap.createScaledBitmap(bitmap, newW, newH, true)
        } catch (e: Exception) {
            bitmap
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
    }
}
