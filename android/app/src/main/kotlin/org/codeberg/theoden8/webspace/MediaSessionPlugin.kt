package org.codeberg.theoden8.webspace

import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * BGAUDIO-006 Android bridge. Dart calls `start`/`update` with the current
 * media metadata + play state to raise/refresh the foreground media
 * notification, and `stop` to tear it down. Transport controls travel the
 * other way as `onTransport` invocations (see [MediaTransportDispatcher]),
 * which the Dart side turns into JS `play()`/`pause()` on the owning webview.
 *
 * iOS has no analogue: there the `.playback` AVAudioSession + the system's
 * own Now Playing UI cover this, driven by the page's own MediaSession.
 */
class MediaSessionPlugin(
    private val context: Context,
    flutterEngine: FlutterEngine,
) {
    private val channel = MethodChannel(
        flutterEngine.dartExecutor.binaryMessenger,
        CHANNEL,
    )

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "start", "update" -> {
                    MediaPlaybackService.startOrUpdate(context, readInfo(call.arguments))
                    result.success(null)
                }
                "stop" -> {
                    MediaPlaybackService.stop(context)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        MediaTransportDispatcher.bind(channel)
    }

    fun dispose() {
        MediaTransportDispatcher.unbind(channel)
    }

    private fun readInfo(args: Any?): MediaPlaybackService.MediaInfo {
        val map = args as? Map<*, *> ?: emptyMap<String, Any?>()
        return MediaPlaybackService.MediaInfo(
            title = (map["title"] as? String).orEmpty(),
            artist = (map["artist"] as? String).orEmpty(),
            album = (map["album"] as? String).orEmpty(),
            playing = (map["playing"] as? Boolean) ?: false,
            artwork = map["artwork"] as? ByteArray,
        )
    }

    companion object {
        const val CHANNEL = "org.codeberg.theoden8.webspace/media_session"
    }
}
