package org.codeberg.theoden8.webspace

import android.content.ComponentCallbacks2
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterShellArgs
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private val CHANNEL = "org.codeberg.theoden8.webspace/shortcuts"
    private val SHARE_CHANNEL = "org.codeberg.theoden8.webspace/share_intent"
    private var locationPlugin: LocationPlugin? = null
    private var cameraPermissionPlugin: CapturePermissionPlugin? = null
    private var microphonePermissionPlugin: CapturePermissionPlugin? = null
    private var surfaceDiagPlugin: SurfaceDiagPlugin? = null
    private var enginePlugins: EnginePlugins? = null
    private var screenCapturePlugin: ScreenCapturePlugin? = null
    private var passkeyPlugin: PasskeyPlugin? = null
    private var pendingShareUrl: String? = null
    private var pendingShareHtml: HtmlPayload? = null

    private data class HtmlPayload(
        val content: String,
        val title: String?,
        val sourceUri: String?,
    )

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Let the window lay out into the display cutout (notch) region on the
        // short edges. Without this, hiding the system bars in fullscreen makes
        // Android letterbox the cutout strip black instead of drawing the
        // webview beside the notch (landscape left/right). github #457
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            window.attributes = window.attributes.apply {
                layoutInDisplayCutoutMode =
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
            }
        }
    }

    override fun getFlutterShellArgs(): FlutterShellArgs =
        WorkerFlutterEngine.forThisDevice(FlutterShellArgs.fromIntent(intent))

    /**
     * An engine the notification worker started holds the app's Dart state
     * too, and two of them in one process would each write the site list and
     * drive the one proxy override. It is stopped before this activity builds
     * its own (NOTIF-016); the wake it ran ends there.
     */
    override fun provideFlutterEngine(context: Context): FlutterEngine? {
        WorkerFlutterEngine.stop(context, "the app was opened")
        return null
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        enginePlugins = EnginePlugins(this, flutterEngine, this)
        locationPlugin = LocationPlugin(this, flutterEngine)
        cameraPermissionPlugin = CapturePermissionPlugin.camera(this, flutterEngine)
        microphonePermissionPlugin = CapturePermissionPlugin.microphone(this, flutterEngine)
        surfaceDiagPlugin = SurfaceDiagPlugin(this, flutterEngine)
        screenCapturePlugin = ScreenCapturePlugin(this, flutterEngine)
        passkeyPlugin = PasskeyPlugin(this, flutterEngine)
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
                    val iconBytes = call.argument<ByteArray>("iconBytes")

                    if (siteId == null || label == null) {
                        result.error("INVALID_ARGS", "siteId and label are required", null)
                        return@setMethodCallHandler
                    }

                    pinShortcut(siteId, label, iconBytes, iconUrl, result)
                }
                "removeShortcut" -> {
                    val siteId = call.argument<String>("siteId")
                    if (siteId != null) {
                        // Remove any dynamic copy, but DO NOT disable the pinned
                        // shortcut: HS-011 keeps the launcher tile alive so a tap
                        // after the site is deleted still launches the app and
                        // re-routes via the siteId->url ledger (offer to open a
                        // domain match or create a new site). Disabling it makes
                        // the launcher refuse the tap with "shortcut isn't
                        // available", which defeats that recovery.
                        ShortcutManagerCompat.removeDynamicShortcuts(this, listOf("site_$siteId"))
                    }
                    result.success(true)
                }
                "disableShortcut" -> {
                    // Explicit user opt-in (HS-011): the app can't remove a
                    // pinned tile, but it can disable it — greyed out, launcher
                    // shows "shortcut isn't available" on tap until the user
                    // drags it off the home screen.
                    val siteId = call.argument<String>("siteId")
                    if (siteId != null) {
                        ShortcutManagerCompat.disableShortcuts(
                            this,
                            listOf("site_$siteId"),
                            "Site has been removed"
                        )
                    }
                    result.success(true)
                }
                "getDiagSeed" -> {
                    // Adb white-screen tier (INTEG-011). Debuggable builds
                    // only: MainActivity is exported, so on a release build
                    // a hostile launch intent must not be able to swap the
                    // user's site list.
                    val debuggable =
                        (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
                    result.success(if (debuggable) intent?.getStringExtra("ws_diag_seed") else null)
                }
                "getDiagRepaintSuppression" -> {
                    // Same debuggable gate as the seed: this drops repaint
                    // triggers, so on a release build it could only ever make
                    // the recurring blank screen easier to hit.
                    val debuggable =
                        (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
                    result.success(
                        if (debuggable) {
                            intent?.getStringExtra("ws_diag_suppress_repaint")
                        } else {
                            null
                        }
                    )
                }
                "getDiagReload" -> {
                    // Adb white-screen tier (INTEG-011). The refresh funnel
                    // is only reachable from the overflow menu, which adb
                    // cannot drive; same debuggable gate as the seed. Drained
                    // on read so a later resume does not reload again.
                    val debuggable =
                        (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
                    val spec =
                        if (debuggable) intent?.getStringExtra("ws_diag_reload") else null
                    intent?.removeExtra("ws_diag_reload")
                    result.success(spec)
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
                "getPinnedSiteIds" -> result.success(pinnedSiteIds(this))
                else -> result.notImplemented()
            }
        }
    }

    private fun pinShortcut(siteId: String, label: String, iconBytes: ByteArray?, iconUrl: String?, result: MethodChannel.Result) {
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

                val appIcon = IconCompat.createWithResource(this, R.mipmap.ic_launcher)
                // Dart rasterizes the favicon through the site's proxy; when that
                // fails the shortcut gets the app icon (HS-003). Never fetch the
                // page-chosen iconUrl here: this is a raw HttpURLConnection over
                // the device IP, outside the proxy (LEAK-003).
                val icon = when {
                    iconBytes != null -> {
                        val bmp = BitmapFactory.decodeByteArray(iconBytes, 0, iconBytes.size)
                        if (bmp != null) IconCompat.createWithBitmap(bmp) else appIcon
                    }
                    else -> appIcon
                }

                val shortcut = ShortcutInfoCompat.Builder(this, "site_$siteId")
                    .setShortLabel(label)
                    .setLongLabel(label)
                    .setIcon(icon)
                    .setIntent(intent)
                    .build()

                republish(shortcut)
                if (isPinnedAndEnabled(shortcut.id)) {
                    runOnUiThread { result.success("alreadyPinned") }
                    return@Thread
                }

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

    // requestPinShortcut throws when the id already exists disabled. A device
    // restore leaves exactly that behind: the old pinned tile comes back
    // disabled when Android can't vouch for this install (signature, version),
    // invisible to getShortcuts, and an imported backup brings the same siteId
    // back. Publishing the id replaces that copy with an enabled one and keeps
    // its pin (HS-015); dropping the dynamic flag right after keeps the site
    // out of the launcher's long-press menu.
    private fun republish(shortcut: ShortcutInfoCompat) {
        ShortcutManagerCompat.pushDynamicShortcut(this, shortcut)
        ShortcutManagerCompat.removeDynamicShortcuts(this, listOf(shortcut.id))
    }

    private fun isPinnedAndEnabled(id: String): Boolean =
        ShortcutManagerCompat.getShortcuts(this, ShortcutManagerCompat.FLAG_MATCH_PINNED)
            .any { it.id == id && it.isEnabled }

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
        // Prefer HTML when EXTRA_STREAM is present. The sharer's declared mime
        // can't be trusted: file managers hand .html files as text/plain or
        // application/octet-stream, and content:// URIs don't carry the file
        // name in their path, so neither the intent mime nor streamUri.path is
        // enough on its own. Resolve the provider's own type + display name and,
        // failing that, sniff the bytes. Only EXTRA_STREAM shares are file
        // imports; a copy-pasted URL rides EXTRA_TEXT and hits the URL path.
        val streamUri: Uri? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(Intent.EXTRA_STREAM)
        }
        if (streamUri != null) {
            val displayName = queryDisplayName(streamUri)
            val resolvedType = try {
                contentResolver.getType(streamUri)?.lowercase()
            } catch (e: Exception) {
                null
            }
            val htmlByMeta = mime == "text/html" || mime == "application/xhtml+xml" ||
                resolvedType == "text/html" || resolvedType == "application/xhtml+xml" ||
                isHtmlName(displayName) || isHtmlName(streamUri.path)
            val html = readStreamAsString(streamUri)
            if (html != null && html.isNotEmpty() && (htmlByMeta || looksLikeHtml(html))) {
                val title = guessTitleFrom(displayName ?: streamUri.lastPathSegment, html)
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

    private fun isHtmlName(name: String?): Boolean {
        val n = name?.lowercase() ?: return false
        return n.endsWith(".html") || n.endsWith(".htm") || n.endsWith(".xhtml")
    }

    private fun looksLikeHtml(s: String): Boolean {
        val head = s.take(1024).lowercase()
        return head.contains("<!doctype html") || head.contains("<html") ||
            head.contains("<head") || head.contains("<body")
    }

    private fun queryDisplayName(uri: Uri): String? {
        if (uri.scheme?.lowercase() != "content") return uri.lastPathSegment
        return try {
            contentResolver.query(
                uri, arrayOf(android.provider.OpenableColumns.DISPLAY_NAME), null, null, null
            )?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val idx = cursor.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
                    if (idx >= 0) cursor.getString(idx) else null
                } else {
                    null
                }
            }
        } catch (e: Exception) {
            null
        }
    }

    private fun readStreamAsString(uri: Uri): String? {
        // Only read content:// shares. MainActivity is exported, so a hostile
        // app can hand us an EXTRA_STREAM pointing at file:///data/data/<pkg>/…;
        // openInputStream would then read our OWN private files with our UID
        // and import them as a site (CWE-926). Legitimate shares always arrive
        // as content:// via the sender's FileProvider.
        if (uri.scheme?.lowercase() != "content") return null
        return try {
            contentResolver.openInputStream(uri)?.use { input ->
                input.bufferedReader(Charsets.UTF_8).readText()
            }
        } catch (e: Exception) {
            null
        }
    }

    private fun guessTitleFrom(name: String?, html: String): String? {
        // Honour an explicit <title>; fall back to the file name (without
        // extension), which is what the desktop file-import flow does.
        val titleMatch = Regex("(?is)<title[^>]*>(.*?)</title>").find(html)
        val fromTitle = titleMatch?.groupValues?.getOrNull(1)?.trim().orEmpty()
        if (fromTitle.isNotEmpty()) return fromTitle
        if (name == null) return null
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

    /**
     * DEVTOOLS-011: the system asking for memory, or saying it may reclaim
     * the process. Flutter forwards every level from RUNNING_LOW up as memory
     * pressure, UI_HIDDEN included, which arrives on every exit from the
     * screen and is not pressure at all (PAUSE-034), so that one is left out.
     */
    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        if (level == ComponentCallbacks2.TRIM_MEMORY_UI_HIDDEN) return
        BackgroundLogFile.record(this, "system trim memory: ${trimLevelName(level)}", "warning")
    }

    // Since API 34 apps are sent only UI_HIDDEN and BACKGROUND; the other
    // levels are deprecated there and still arrive on older releases.
    @Suppress("DEPRECATION")
    private fun trimLevelName(level: Int): String = when (level) {
        ComponentCallbacks2.TRIM_MEMORY_RUNNING_MODERATE -> "running moderate"
        ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW -> "running low"
        ComponentCallbacks2.TRIM_MEMORY_RUNNING_CRITICAL -> "running critical"
        ComponentCallbacks2.TRIM_MEMORY_BACKGROUND -> "background"
        ComponentCallbacks2.TRIM_MEMORY_MODERATE -> "moderate"
        ComponentCallbacks2.TRIM_MEMORY_COMPLETE -> "complete"
        else -> "level $level"
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        enginePlugins?.dispose()
        enginePlugins = null
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
        if (cameraPermissionPlugin?.onRequestPermissionsResult(requestCode, permissions, grantResults) == true) {
            return
        }
        if (microphonePermissionPlugin?.onRequestPermissionsResult(requestCode, permissions, grantResults) == true) {
            return
        }
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }
}

/** Site ids of the enabled pinned shortcuts. Needs no activity, so the
 * worker's engine answers it too (NOTIF-016). */
internal fun pinnedSiteIds(context: Context): List<String> = try {
    val pinned = ShortcutManagerCompat.getShortcuts(
        context,
        ShortcutManagerCompat.FLAG_MATCH_PINNED
    )
    // A disabled tile opens nothing, so it must not hide
    // the menu item that would bring it back (HS-015).
    pinned.filter { it.isEnabled }.mapNotNull { info ->
        info.id.takeIf { it.startsWith("site_") }?.removePrefix("site_")
    }
} catch (e: Exception) {
    emptyList()
}
