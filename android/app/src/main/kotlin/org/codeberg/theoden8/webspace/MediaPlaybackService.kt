package org.codeberg.theoden8.webspace

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.drawable.Icon
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat

/**
 * BGAUDIO-006: foreground media-playback service for sites with "Background
 * audio" enabled. It owns a [MediaSession] and a `MediaStyle` notification
 * with play/pause; transport actions (notification buttons, lockscreen,
 * Bluetooth/headset media keys) are forwarded to Dart via
 * [MediaTransportDispatcher], which runs the corresponding JS on the owning
 * webview. Dart drives the notification's title/artist/artwork/state through
 * [startOrUpdate]; the service holds no player of its own.
 *
 * Control flow avoids marshalling metadata (incl. artwork bytes) through
 * Intent extras: the Intent is only a trigger, and [pendingInfo] / the
 * live [instance] carry the payload. START/UPDATE come in while the app is
 * still foreground (the user starts playback on-screen), so
 * `startForegroundService` is always allowed; STOP/UPDATE after that reuse
 * the live instance.
 */
class MediaPlaybackService : Service() {
    data class MediaInfo(
        val title: String,
        val artist: String,
        val album: String,
        val playing: Boolean,
        val artwork: ByteArray?,
    )

    private var session: MediaSession? = null
    private var startedForeground = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        ensureChannel(this)
        val s = MediaSession(this, "WebspaceMedia")
        s.setCallback(object : MediaSession.Callback() {
            override fun onPlay() = MediaTransportDispatcher.dispatch("play")
            override fun onPause() = MediaTransportDispatcher.dispatch("pause")
            override fun onStop() = MediaTransportDispatcher.dispatch("stop")
        })
        session = s
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_TRANSPORT -> {
                intent.getStringExtra(EXTRA_TRANSPORT)?.let {
                    MediaTransportDispatcher.dispatch(it)
                }
            }
            ACTION_STOP -> stopPlayback()
            else -> {
                // ACTION_START / ACTION_UPDATE, or a system restart.
                val info = pendingInfo
                if (info != null) {
                    pendingInfo = null
                    render(info)
                } else if (!startedForeground) {
                    // Restarted by the system with no payload and never shown —
                    // nothing to play; don't leave a dangling FGS.
                    stopPlayback()
                }
            }
        }
        return START_NOT_STICKY
    }

    private fun render(info: MediaInfo) {
        val s = session ?: return
        val bitmap: Bitmap? = info.artwork?.let {
            try {
                BitmapFactory.decodeByteArray(it, 0, it.size)
            } catch (e: Exception) {
                null
            }
        }
        s.setMetadata(
            MediaMetadata.Builder()
                .putString(MediaMetadata.METADATA_KEY_TITLE, info.title)
                .putString(MediaMetadata.METADATA_KEY_ARTIST, info.artist)
                .putString(MediaMetadata.METADATA_KEY_ALBUM, info.album)
                .apply {
                    if (bitmap != null) {
                        putBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART, bitmap)
                    }
                }
                .build()
        )
        s.setPlaybackState(
            PlaybackState.Builder()
                .setActions(
                    PlaybackState.ACTION_PLAY or
                        PlaybackState.ACTION_PAUSE or
                        PlaybackState.ACTION_PLAY_PAUSE or
                        PlaybackState.ACTION_STOP
                )
                .setState(
                    if (info.playing) PlaybackState.STATE_PLAYING
                    else PlaybackState.STATE_PAUSED,
                    PlaybackState.PLAYBACK_POSITION_UNKNOWN,
                    1.0f,
                )
                .build()
        )
        s.setActive(true)

        val notification = buildNotification(info, s, bitmap)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ServiceCompat.startForeground(
                this,
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK,
            )
        } else {
            ServiceCompat.startForeground(this, NOTIFICATION_ID, notification, 0)
        }
        startedForeground = true
    }

    private fun buildNotification(
        info: MediaInfo,
        s: MediaSession,
        bitmap: Bitmap?,
    ): Notification {
        val contentIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val playPauseAction = if (info.playing) {
            action(android.R.drawable.ic_media_pause, "Pause", "pause")
        } else {
            action(android.R.drawable.ic_media_play, "Play", "play")
        }
        builder
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(info.title.ifEmpty { "Playing audio" })
            .setContentText(info.artist)
            .setContentIntent(contentIntent)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setOngoing(info.playing)
            .setOnlyAlertOnce(true)
            .addAction(playPauseAction)
        if (bitmap != null) builder.setLargeIcon(bitmap)
        builder.setStyle(
            Notification.MediaStyle()
                .setMediaSession(s.sessionToken)
                .setShowActionsInCompactView(0)
        )
        return builder.build()
    }

    private fun action(icon: Int, title: String, transport: String): Notification.Action {
        val intent = Intent(this, MediaPlaybackService::class.java).apply {
            action = ACTION_TRANSPORT
            putExtra(EXTRA_TRANSPORT, transport)
        }
        val pi = PendingIntent.getService(
            this,
            transport.hashCode(),
            intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return Notification.Action.Builder(
            Icon.createWithResource(this, icon), title, pi,
        ).build()
    }

    private fun stopPlayback() {
        session?.setActive(false)
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        startedForeground = false
        stopSelf()
    }

    override fun onDestroy() {
        session?.release()
        session = null
        if (instance === this) instance = null
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL_ID = "webspace_media_playback"
        private const val NOTIFICATION_ID = 0xB6A0
        private const val ACTION_STOP = "org.codeberg.theoden8.webspace.MEDIA_STOP"
        private const val ACTION_TRANSPORT =
            "org.codeberg.theoden8.webspace.MEDIA_TRANSPORT"
        private const val EXTRA_TRANSPORT = "transport"

        private val mainHandler = Handler(Looper.getMainLooper())

        @Volatile
        private var instance: MediaPlaybackService? = null

        @Volatile
        private var pendingInfo: MediaInfo? = null

        /** Start the service (if needed) or update the live notification. */
        fun startOrUpdate(context: Context, info: MediaInfo) {
            mainHandler.post {
                val live = instance
                if (live != null) {
                    live.render(info)
                } else {
                    pendingInfo = info
                    ContextCompat.startForegroundService(
                        context,
                        Intent(context, MediaPlaybackService::class.java),
                    )
                }
            }
        }

        fun stop(context: Context) {
            mainHandler.post { instance?.stopPlayback() }
        }

        private fun ensureChannel(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val mgr = context.getSystemService(NotificationManager::class.java)
                ?: return
            if (mgr.getNotificationChannel(CHANNEL_ID) != null) return
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Background audio",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Media controls for sites playing audio in the background"
                setShowBadge(false)
            }
            mgr.createNotificationChannel(channel)
        }
    }
}

/**
 * Bridges [MediaPlaybackService]'s transport callbacks (which fire without an
 * attached Activity guaranteed) to whichever `MethodChannel` the
 * [MediaSessionPlugin] currently has bound. Same shape as
 * [NotificationRefreshDispatcher]. Main-thread only.
 */
internal object MediaTransportDispatcher {
    private val mainHandler = Handler(Looper.getMainLooper())
    private var channel: io.flutter.plugin.common.MethodChannel? = null

    fun bind(c: io.flutter.plugin.common.MethodChannel) {
        channel = c
    }

    fun unbind(c: io.flutter.plugin.common.MethodChannel) {
        if (channel === c) channel = null
    }

    fun dispatch(action: String) {
        val c = channel ?: return
        mainHandler.post { c.invokeMethod("onTransport", mapOf("action" to action)) }
    }
}
