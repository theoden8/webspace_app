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
import android.graphics.PixelFormat
import android.graphics.drawable.Icon
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.Image
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import android.util.DisplayMetrics
import android.view.WindowManager
import androidx.core.app.ServiceCompat
import java.io.ByteArrayOutputStream
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Holds a share of the screen while it runs (SHARE-018). Android allows a
 * `MediaProjection` only inside a foreground service of type
 * `mediaProjection`, which also puts the share in front of the user as an
 * ongoing notification with a Stop button, beside Android's own cast
 * indicator.
 *
 * It runs only between the user's yes to Android's prompt and the share's
 * end, and holds nothing else up: it is not a way to keep a page resident
 * (NOTIF-015).
 */
class ScreenShareService : Service() {
    private var share: Share? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> begin()
            else -> end()
        }
        return START_NOT_STICKY
    }

    private fun begin() {
        val pending = ScreenShareSession.pendingStart
        val consent = ScreenShareSession.consent
        ScreenShareSession.pendingStart = null
        ScreenShareSession.consent = null
        if (pending == null || consent == null) {
            pending?.result?.success(null)
            end()
            return
        }
        if (pending.abandoned) {
            // Entered first: a service started with startForegroundService
            // that stops before it is in the foreground crashes the app.
            enterForeground(pending.request)
            end()
            return
        }
        val request = pending.request
        var projection: MediaProjection? = null
        try {
            enterForeground(request)
            val manager = getSystemService(MediaProjectionManager::class.java)
            projection = manager.getMediaProjection(consent.resultCode, consent.data)
            if (projection == null) {
                pending.result.success(null)
                end()
                return
            }
            val started = Share(this, projection, request)
            share = started
            ScreenShareSession.began(started, owner = pending.owner)
            pending.result.success(mapOf("width" to started.width, "height" to started.height))
        } catch (e: SecurityException) {
            projection?.stop()
            pending.result.error("SECURITY", e.message, null)
            end()
        } catch (e: IllegalStateException) {
            projection?.stop()
            pending.result.error("STATE", e.message, null)
            end()
        }
    }

    private fun enterForeground(request: ShareRequest) {
        val notification = buildNotification(request)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ServiceCompat.startForeground(
                this,
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION,
            )
        } else {
            ServiceCompat.startForeground(this, NOTIFICATION_ID, notification, 0)
        }
    }

    private fun buildNotification(request: ShareRequest): Notification {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val mgr = getSystemService(NotificationManager::class.java)
            if (mgr.getNotificationChannel(CHANNEL_ID) == null) {
                mgr.createNotificationChannel(
                    NotificationChannel(
                        CHANNEL_ID,
                        request.title.ifEmpty { "Screen sharing" },
                        NotificationManager.IMPORTANCE_LOW,
                    ),
                )
            }
        }
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val stop = PendingIntent.getService(
            this,
            1,
            Intent(this, ScreenShareService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(request.title)
            .setContentText(request.text)
            .setContentIntent(open)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .addAction(
                Notification.Action.Builder(
                    Icon.createWithResource(this, android.R.drawable.ic_menu_close_clear_cancel),
                    request.stop,
                    stop,
                ).build(),
            )
            .build()
    }

    /** Ends the share, if one runs, and the service with it. Idempotent. */
    private fun end() {
        val ending = share
        share = null
        ending?.release()
        if (ending != null) ScreenShareSession.ended(ending)
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    /**
     * The user swiped the app away: the page reading the share is gone. A
     * service not yet in the foreground is left to [begin], which ends it.
     */
    override fun onTaskRemoved(rootIntent: Intent?) {
        if (share != null) end()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        end()
        if (instance === this) instance = null
        super.onDestroy()
    }

    /**
     * One projection, its virtual display and the thread that encodes its
     * frames. Ends with the projection, whoever stops it: the app, the
     * notification's Stop, or Android's own cast controls.
     */
    private class Share(
        private val service: ScreenShareService,
        private val projection: MediaProjection,
        request: ShareRequest,
    ) {
        val width: Int
        val height: Int
        private val thread = HandlerThread("screen-share").apply { start() }
        private val reader: ImageReader
        private val display: VirtualDisplay
        private val encoder: Encoder

        init {
            val screen = screenSize(service)
            val size = fit(screen.first, screen.second, request)
            width = size.first
            height = size.second
            // Android 14 refuses a virtual display before a callback is
            // registered; the callback is also how a stop from Android's
            // own controls reaches the app.
            projection.registerCallback(
                object : MediaProjection.Callback() {
                    override fun onStop() = end(service)
                },
                Handler(Looper.getMainLooper()),
            )
            reader = ImageReader.newInstance(width, height, PixelFormat.RGBA_8888, 3)
            encoder = Encoder(this, Handler(thread.looper), width, height, request.fps)
            reader.setOnImageAvailableListener(encoder, Handler(thread.looper))
            display = try {
                projection.createVirtualDisplay(
                    "webspace-screen-share",
                    width,
                    height,
                    service.resources.displayMetrics.densityDpi,
                    DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
                    reader.surface,
                    null,
                    null,
                )
            } catch (e: SecurityException) {
                null
            } catch (e: IllegalStateException) {
                null
            } ?: run {
                reader.close()
                thread.quitSafely()
                throw IllegalStateException("Android gave the share no display")
            }
        }

        fun release() {
            display.release()
            reader.setOnImageAvailableListener(null, null)
            // Closed on the capture thread, behind an encode already running
            // there, so no image is read after its reader freed it; an
            // encode scheduled for later is dropped by the quit.
            Handler(thread.looper).post {
                encoder.drop()
                reader.close()
            }
            thread.quitSafely()
            projection.stop()
        }

        private fun end(service: ScreenShareService) {
            if (service.share === this) service.end()
        }
    }

    /**
     * Turns the newest image into a JPEG at most [fps] times a second, on the
     * capture thread, and posts it to the main thread. An image that arrives
     * sooner waits for its turn rather than being dropped, so the last change
     * on a screen that then goes still is still sent.
     */
    private class Encoder(
        private val share: Any,
        private val handler: Handler,
        private val width: Int,
        private val height: Int,
        fps: Int,
    ) : ImageReader.OnImageAvailableListener, Runnable {
        private val interval = 1000L / fps
        private val main = Handler(Looper.getMainLooper())
        private var held: Image? = null
        private var scheduled = false
        private var lastAt = 0L
        private var seq = 0

        override fun onImageAvailable(reader: ImageReader) {
            val image = try {
                reader.acquireLatestImage()
            } catch (e: IllegalStateException) {
                null
            } ?: return
            held?.close()
            held = image
            if (scheduled) return
            scheduled = true
            handler.postAtTime(this, max(SystemClock.uptimeMillis(), lastAt + interval))
        }

        fun drop() {
            held?.close()
            held = null
        }

        override fun run() {
            scheduled = false
            val image = held ?: return
            held = null
            lastAt = SystemClock.uptimeMillis()
            val jpeg = try {
                encode(image)
            } catch (e: IllegalStateException) {
                null
            } finally {
                image.close()
            }
            if (jpeg == null) return
            val frame = ShareFrame(share, ++seq, jpeg)
            main.post { ScreenShareSession.offer(frame) }
        }

        private fun encode(image: Image): ByteArray {
            val plane = image.planes[0]
            val rowWidth = plane.rowStride / plane.pixelStride
            val padded = Bitmap.createBitmap(rowWidth, height, Bitmap.Config.ARGB_8888)
            padded.copyPixelsFromBuffer(plane.buffer)
            val bitmap = if (rowWidth == width) padded else Bitmap.createBitmap(padded, 0, 0, width, height)
            val out = ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.JPEG, JPEG_QUALITY, out)
            if (bitmap !== padded) bitmap.recycle()
            padded.recycle()
            return out.toByteArray()
        }
    }

    companion object {
        const val ACTION_START = "org.codeberg.theoden8.webspace.SCREEN_SHARE_START"
        const val ACTION_STOP = "org.codeberg.theoden8.webspace.SCREEN_SHARE_STOP"
        private const val CHANNEL_ID = "webspace_screen_share"
        private const val NOTIFICATION_ID = 0x5C5A
        private const val JPEG_QUALITY = 60

        private var instance: ScreenShareService? = null

        /** Ends a running share. Main thread, like every caller here. */
        fun end() {
            instance?.end()
        }

        /** The screen's full size in pixels, system bars included. */
        private fun screenSize(context: Context): Pair<Int, Int> {
            val wm = context.getSystemService(WindowManager::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                val bounds = wm.maximumWindowMetrics.bounds
                return Pair(bounds.width(), bounds.height())
            }
            val metrics = DisplayMetrics()
            @Suppress("DEPRECATION")
            wm.defaultDisplay.getRealMetrics(metrics)
            return Pair(metrics.widthPixels, metrics.heightPixels)
        }

        /**
         * The screen scaled down, never up, to fit the page's caps and the
         * app's own long-side cap, in even pixels for the video encoder the
         * page feeds it to.
         */
        internal fun fit(screenWidth: Int, screenHeight: Int, request: ShareRequest): Pair<Int, Int> {
            var scale = 1.0
            val longSide = max(screenWidth, screenHeight)
            if (request.maxLongSide in 1 until longSide) {
                scale = min(scale, request.maxLongSide.toDouble() / longSide)
            }
            if (request.maxWidth in 1 until screenWidth) {
                scale = min(scale, request.maxWidth.toDouble() / screenWidth)
            }
            if (request.maxHeight in 1 until screenHeight) {
                scale = min(scale, request.maxHeight.toDouble() / screenHeight)
            }
            fun even(v: Double) = max(2, (v.roundToInt() / 2) * 2)
            return Pair(even(screenWidth * scale), even(screenHeight * scale))
        }
    }
}
