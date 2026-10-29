package org.codeberg.theoden8.webspace

import android.app.Activity
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * A share of the device screen with one page (SHARE-018). Android WebView
 * has no display capture, so the app runs one: Android's own capture prompt
 * for every share, a `mediaProjection` foreground service that holds it
 * ([ScreenShareService]), and frames the page pulls one at a time over the
 * Dart bridge.
 *
 * Every field here and in [ScreenShareSession] is read and written on the
 * main thread only: the method channel, the activity result, the service's
 * lifecycle and the projection callback all run there, and the capture
 * thread hands each encoded frame over with a post (BUG-007: none-shared).
 *
 * The share is the process's, while each Flutter engine (a second activity
 * a share sheet opens has its own) runs its own Dart side: so a share
 * belongs to the plugin that started it, and only that plugin reads its
 * frames, stops it, and hears that it ended.
 */
class ScreenSharePlugin(
    private val activity: Activity,
    flutterEngine: FlutterEngine,
) : MethodChannel.MethodCallHandler {
    companion object {
        private const val CHANNEL = "org.codeberg.theoden8.webspace/screen_share"
        private const val REQUEST_CODE = 0x5C5
    }

    private val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> start(call, result)
            "frame" -> ScreenShareSession.frame(
                this,
                call.argument<Number>("after")?.toInt() ?: 0,
                result,
            )
            "stop" -> {
                // A start still waiting on Android's prompt is left to it:
                // Dart stops a share whose yes came too late, and stopping
                // the service between the yes and its start would crash.
                if (ScreenShareSession.liveOwner === this) ScreenShareService.end()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    /** The share's end, told to the Dart side that started it. */
    internal fun ended() {
        channel.invokeMethod("ended", null)
    }

    /**
     * This plugin's engine is going: nothing would end its share or answer
     * its start (SHARE-017).
     */
    fun dispose() {
        channel.setMethodCallHandler(null)
        val pending = ScreenShareSession.pendingStart
        if (pending?.owner === this) {
            // Before the yes the start is dropped; after it the service is
            // already on its way, and ends as soon as it is up.
            if (ScreenShareSession.consent == null) {
                ScreenShareSession.pendingStart = null
            } else {
                pending.abandoned = true
            }
        }
        if (ScreenShareSession.liveOwner === this) ScreenShareService.end()
    }

    /** Asks Android for the screen; the answer arrives in [onActivityResult]. */
    private fun start(call: MethodCall, result: MethodChannel.Result) {
        // A share is the user's act, so the app is in front: a prompt raised
        // from the background lands over another app, or, where Android
        // blocks it, never answers.
        val resumed = (activity as? LifecycleOwner)?.lifecycle?.currentState
            ?.isAtLeast(Lifecycle.State.RESUMED) == true
        if (ScreenShareSession.pendingStart != null || !resumed) {
            result.success(null)
            return
        }
        val request = ShareRequest(
            maxWidth = call.argument<Int>("maxWidth") ?: 0,
            maxHeight = call.argument<Int>("maxHeight") ?: 0,
            maxLongSide = call.argument<Int>("maxLongSide") ?: 1280,
            fps = (call.argument<Int>("fps") ?: 10).coerceIn(1, 30),
            title = call.argument<String>("title").orEmpty(),
            text = call.argument<String>("text").orEmpty(),
            stop = call.argument<String>("stop").orEmpty(),
        )
        val manager = activity.getSystemService(MediaProjectionManager::class.java)
        if (manager == null) {
            result.success(null)
            return
        }
        ScreenShareService.end()
        ScreenShareSession.pendingStart = PendingStart(request, result, owner = this)
        activity.startActivityForResult(manager.createScreenCaptureIntent(), REQUEST_CODE)
    }

    /**
     * Android's capture prompt answered. A yes starts the foreground service,
     * which Android 14 requires to be running before the projection is taken;
     * the service answers the start once the virtual display exists.
     */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_CODE) return false
        val pending = ScreenShareSession.pendingStart
        if (pending == null || pending.owner !== this) return true
        if (resultCode != Activity.RESULT_OK || data == null) {
            ScreenShareSession.pendingStart = null
            pending.result.success(null)
            return true
        }
        ScreenShareSession.consent = Consent(resultCode, data)
        ContextCompat.startForegroundService(
            activity,
            Intent(activity, ScreenShareService::class.java)
                .setAction(ScreenShareService.ACTION_START),
        )
        return true
    }
}

/** What the page asked of the surface, and the notification's words. */
internal data class ShareRequest(
    val maxWidth: Int,
    val maxHeight: Int,
    val maxLongSide: Int,
    val fps: Int,
    val title: String,
    val text: String,
    val stop: String,
)

internal class PendingStart(
    val request: ShareRequest,
    val result: MethodChannel.Result,
    val owner: ScreenSharePlugin,
) {
    /** Its engine went after the user's yes: the service ends once up. */
    var abandoned = false
}

internal class Consent(val resultCode: Int, val data: Intent)

/** One encoded frame of a share. Never changed once made. */
internal class ShareFrame(val share: Any, val seq: Int, val jpeg: ByteArray)

/**
 * The share's state between the plugin and the service. Main thread only
 * (see [ScreenSharePlugin]).
 */
internal object ScreenShareSession {
    private const val PULL_WAIT_MS = 1500L

    private val main = Handler(Looper.getMainLooper())

    /** A start waiting on Android's prompt or on the service. */
    var pendingStart: PendingStart? = null

    /** The prompt's yes, taken once by the service. */
    var consent: Consent? = null

    /** The running share, by identity: a frame of an ended one is dropped. */
    var live: Any? = null
        private set

    /** The plugin that started [live]: the only one that reads or stops it. */
    var liveOwner: ScreenSharePlugin? = null
        private set

    private var latest: ShareFrame? = null
    private var waiting: Waiting? = null

    private class Waiting(val after: Int, val result: MethodChannel.Result, val timeout: Runnable)

    fun began(share: Any, owner: ScreenSharePlugin) {
        live = share
        liveOwner = owner
        latest = null
    }

    /** A frame from the capture thread, posted here. */
    fun offer(frame: ShareFrame) {
        if (frame.share !== live) return
        latest = frame
        val w = waiting ?: return
        if (frame.seq > w.after) answer(w) { frame.toReply() }
    }

    /**
     * The newest frame after [after], or the same seq once [PULL_WAIT_MS]
     * passes with none. A pull waits rather than returns at once, so a page
     * whose screen is still costs a round trip a second and a half, not a
     * busy loop over the bridge.
     */
    fun frame(caller: ScreenSharePlugin, after: Int, result: MethodChannel.Result) {
        if (live == null || liveOwner !== caller) {
            result.success(ENDED)
            return
        }
        waiting?.let { w -> answer(w) { mapOf("seq" to w.after) } }
        val now = latest
        if (now != null && now.seq > after) {
            result.success(now.toReply())
            return
        }
        lateinit var w: Waiting
        val timeout = Runnable { if (waiting === w) answer(w) { mapOf("seq" to after) } }
        w = Waiting(after, result, timeout)
        waiting = w
        main.postDelayed(timeout, PULL_WAIT_MS)
    }

    fun ended(share: Any) {
        if (live !== share) return
        val owner = liveOwner
        live = null
        liveOwner = null
        latest = null
        waiting?.let { w -> answer(w) { ENDED } }
        owner?.ended()
    }

    private fun answer(w: Waiting, reply: () -> Any) {
        waiting = null
        main.removeCallbacks(w.timeout)
        w.result.success(reply())
    }

    private fun ShareFrame.toReply() = mapOf("seq" to seq, "jpeg" to jpeg)

    private val ENDED = mapOf("ended" to true)
}
