package org.codeberg.theoden8.webspace

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

/**
 * Foreground service backing NOTIF-005-A. Holds the app process alive
 * across backgrounding so notification sites' WebViews keep executing
 * their page JS — without this, Android eventually freezes the renderer
 * once the activity is no longer visible and timer-driven polling stops.
 *
 * The service does NOT itself poll: it just calls `startForeground(...)`
 * with a persistent notification, then waits to be stopped. The webviews
 * continue running on the main process because the foreground service
 * keeps that process from being killed for OOM or app standby reasons.
 *
 * Lifecycle is driven from Dart by [WebSpaceBackgroundPollPlugin] /
 * [AndroidForegroundService]:
 *   - START with extra `count` -> upgrade-or-start the persistent
 *     notification text "WebSpace is checking N sites for updates".
 *   - STOP -> [stopForeground] + [stopSelf].
 */
class BackgroundPollService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action ?: ACTION_START
        when (action) {
            ACTION_START -> {
                val count = intent?.getIntExtra(EXTRA_COUNT, 1) ?: 1
                ensureChannel()
                val notification = buildNotification(count)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                    startForeground(
                        NOTIFICATION_ID,
                        notification,
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
                    )
                } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    startForeground(
                        NOTIFICATION_ID,
                        notification,
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
                    )
                } else {
                    startForeground(NOTIFICATION_ID, notification)
                }
            }
            ACTION_STOP -> {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    stopForeground(STOP_FOREGROUND_REMOVE)
                } else {
                    @Suppress("DEPRECATION")
                    stopForeground(true)
                }
                stopSelf()
            }
        }
        // START_NOT_STICKY: if the OS kills us on memory pressure, don't
        // let it restart us with a null Intent — Dart will re-issue the
        // start command on the next lifecycle event when appropriate.
        return START_NOT_STICKY
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val mgr = getSystemService(NotificationManager::class.java) ?: return
        if (mgr.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Background polling",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Persistent notification while WebSpace is keeping notification sites alive in the background."
            setShowBadge(false)
        }
        mgr.createNotificationChannel(channel)
    }

    private fun buildNotification(count: Int): Notification {
        val tapIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingFlags =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            } else {
                PendingIntent.FLAG_UPDATE_CURRENT
            }
        val contentPi = PendingIntent.getActivity(this, 0, tapIntent, pendingFlags)
        val text = if (count == 1) {
            "WebSpace is checking 1 site for updates"
        } else {
            "WebSpace is checking $count sites for updates"
        }
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("WebSpace")
            .setContentText(text)
            .setOngoing(true)
            .setSilent(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setContentIntent(contentPi)
            .build()
    }

    companion object {
        const val ACTION_START = "org.codeberg.theoden8.webspace.background_poll.START"
        const val ACTION_STOP = "org.codeberg.theoden8.webspace.background_poll.STOP"
        const val EXTRA_COUNT = "count"
        private const val CHANNEL_ID = "webspace_background_poll"
        private const val NOTIFICATION_ID = 0xB6D11
    }
}
