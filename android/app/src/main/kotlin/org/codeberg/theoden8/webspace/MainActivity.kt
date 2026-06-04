package org.codeberg.theoden8.webspace

import android.content.Intent
import android.graphics.BitmapFactory
import android.net.Uri
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
    private val SHARE_CHANNEL = "org.codeberg.theoden8.webspace/share_intent"
    private var webInterceptPlugin: WebInterceptPlugin? = null
    private var locationPlugin: LocationPlugin? = null
    private var webSpaceContainerPlugin: WebSpaceContainerPlugin? = null
    private var backgroundTaskPlugin: BackgroundTaskAndroidPlugin? = null
    private var proxyRelayPlugin: ProxyRelayPlugin? = null
    private var pendingShareUrl: String? = null
    private var pendingShareHtml: HtmlPayload? = null

    private data class HtmlPayload(
        val content: String,
        val title: String?,
        val sourceUri: String?,
    )

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
        locationPlugin = LocationPlugin(this, flutterEngine)
        webSpaceContainerPlugin = WebSpaceContainerPlugin(flutterEngine)
        backgroundTaskPlugin = BackgroundTaskAndroidPlugin(applicationContext, flutterEngine)
        proxyRelayPlugin = ProxyRelayPlugin(flutterEngine)
        captureSharePayload(intent)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SHARE_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "consumeLaunchUrl" -> {
                    val url = pendingShareUrl
                    pendingShareUrl = null
                    result.success(url)
                }
                "consumeLaunchHtml" -> {
                    val payload = pendingShareHtml
                    pendingShareHtml = null
                    if (payload == null) {
                        result.success(null)
                    } else {
                        result.success(mapOf(
                            "content" to payload.content,
                            "title" to payload.title,
                            "sourceUri" to payload.sourceUri,
                        ))
                    }
                }
                else -> result.notImplemented()
            }
        }
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
                    // Drain the extra after reading so it fires once per tap.
                    // didChangeAppLifecycleState(resumed) re-polls this on every
                    // foreground; without clearing, a plain background/return
                    // would re-navigate to the pinned site (issue: shortcut
                    // re-opens on resume).
                    intent?.removeExtra("siteId")
                    result.success(siteId)
                }
                "getPinnedSiteIds" -> {
                    try {
                        val pinned = ShortcutManagerCompat.getShortcuts(
                            this,
                            ShortcutManagerCompat.FLAG_MATCH_PINNED
                        )
                        val ids = pinned.mapNotNull { info ->
                            info.id.takeIf { it.startsWith("site_") }?.removePrefix("site_")
                        }
                        result.success(ids)
                    } catch (e: Exception) {
                        result.success(emptyList<String>())
                    }
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
        captureSharePayload(intent)
    }

    private fun captureSharePayload(intent: Intent?) {
        if (intent == null) return
        // LIR-004: ACTION_VIEW on webspace:// — pass the raw URI string
        // through; the Dart side runs it through parseWebspaceUri.
        if (intent.action == Intent.ACTION_VIEW) {
            val data = intent.data ?: return
            if (data.scheme?.lowercase() == "webspace") {
                pendingShareUrl = data.toString()
            }
            return
        }
        if (intent.action != Intent.ACTION_SEND) return
        val mime = intent.type?.lowercase() ?: ""
        // Prefer HTML when the sharer signals it via mime type OR ships
        // a text/html stream extra. Sharers that pass HTML as a tiny
        // EXTRA_TEXT (e.g. a copy-pasted snippet) still hit the URL path
        // first; only when EXTRA_STREAM is present do we treat the
        // payload as a file import.
        val streamUri: Uri? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(Intent.EXTRA_STREAM)
        }
        val isHtmlMime = mime == "text/html" || mime == "application/xhtml+xml"
        if (streamUri != null && (isHtmlMime || streamUri.path?.lowercase()?.endsWith(".html") == true || streamUri.path?.lowercase()?.endsWith(".htm") == true)) {
            val html = readStreamAsString(streamUri)
            if (html != null && html.isNotEmpty()) {
                val title = guessTitleFrom(streamUri, html)
                pendingShareHtml = HtmlPayload(content = html, title = title, sourceUri = streamUri.toString())
                pendingShareUrl = null
                return
            }
        }
        val url = extractShareUrl(intent)
        if (url != null) {
            pendingShareUrl = url
        }
    }

    private fun readStreamAsString(uri: Uri): String? {
        return try {
            contentResolver.openInputStream(uri)?.use { input ->
                input.bufferedReader(Charsets.UTF_8).readText()
            }
        } catch (e: Exception) {
            null
        }
    }

    private fun guessTitleFrom(uri: Uri, html: String): String? {
        // Honour an explicit <title>; fall back to the file name (without
        // extension), which is what the desktop file-import flow does.
        val titleMatch = Regex("(?is)<title[^>]*>(.*?)</title>").find(html)
        val fromTitle = titleMatch?.groupValues?.getOrNull(1)?.trim().orEmpty()
        if (fromTitle.isNotEmpty()) return fromTitle
        val name = uri.lastPathSegment ?: return null
        val dot = name.lastIndexOf('.')
        return if (dot > 0) name.substring(0, dot) else name
    }

    private fun extractShareUrl(intent: Intent?): String? {
        if (intent == null || intent.action != Intent.ACTION_SEND) return null
        val text = intent.getStringExtra(Intent.EXTRA_TEXT)?.trim() ?: return null
        if (text.isEmpty()) return null
        val direct = Uri.parse(text)
        val directScheme = direct.scheme?.lowercase()
        return if (directScheme == "http" || directScheme == "https") {
            text
        } else {
            Regex("""https?://\S+""").find(text)?.value
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        backgroundTaskPlugin?.dispose()
        backgroundTaskPlugin = null
        proxyRelayPlugin?.dispose()
        proxyRelayPlugin = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        if (locationPlugin?.onRequestPermissionsResult(requestCode, permissions, grantResults) == true) {
            return
        }
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }
}
