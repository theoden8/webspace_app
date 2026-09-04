package org.codeberg.theoden8.webspace

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.TimeUnit

/**
 * Android side of NOTIF-005-A. Mirrors `BackgroundTaskPlugin.swift`:
 * the Dart side calls `scheduleRefresh` on background, and `WorkManager`
 * fires roughly every 15 minutes (system minimum), the first run one
 * interval after it is scheduled rather than at once. The worker invokes
 * `onBackgroundRefresh` over the same method channel iOS uses, the Dart
 * handler reloads notification sites, and `bgRefreshDidComplete`
 * finalises the work.
 *
 * `beginGracePeriod` / `endGracePeriod` are accepted but no-op — Android
 * has no `beginBackgroundTask`-equivalent without a foreground service,
 * and the OS already gives the process a brief grace period before
 * freezing notif webviews (which are exempt from per-instance pause via
 * `WebViewModel.pauseWebView`'s notif early-return).
 */
class BackgroundTaskAndroidPlugin(
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
                "scheduleRefresh" -> {
                    schedule()
                    result.success(null)
                }
                "cancelScheduledRefreshes" -> {
                    cancel()
                    result.success(null)
                }
                "beginGracePeriod", "endGracePeriod" -> {
                    result.success(null)
                }
                "bgRefreshDidComplete" -> {
                    val args = call.arguments as? Map<*, *>
                    val success = (args?.get("success") as? Boolean) ?: true
                    NotificationRefreshDispatcher.complete(success)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        NotificationRefreshDispatcher.bind(channel)
    }

    fun dispose() {
        NotificationRefreshDispatcher.unbind(channel)
    }

    private fun schedule() {
        val constraints = Constraints.Builder()
            .setRequiredNetworkType(NetworkType.CONNECTED)
            .build()
        val request = PeriodicWorkRequestBuilder<NotificationRefreshWorker>(
            REFRESH_INTERVAL_MINUTES, TimeUnit.MINUTES,
        )
            .setConstraints(constraints)
            // While `periodCount == 0` WorkManager reports the next run time as
            // the enqueue time itself (`WorkSpec.calculateNextRunTime`), so an
            // undelayed request fires seconds after the first notification site
            // is loaded and reloads the page the user just opened. The delay
            // makes the first period wait like every later one.
            .setInitialDelay(REFRESH_INTERVAL_MINUTES, TimeUnit.MINUTES)
            .build()
        WorkManager.getInstance(context).enqueueUniquePeriodicWork(
            UNIQUE_NAME,
            ExistingPeriodicWorkPolicy.UPDATE,
            request,
        )
        Log.i(TAG, "scheduled periodic refresh ($UNIQUE_NAME, ${REFRESH_INTERVAL_MINUTES}min)")
    }

    private fun cancel() {
        WorkManager.getInstance(context).cancelUniqueWork(UNIQUE_NAME)
        Log.i(TAG, "cancelled periodic refresh ($UNIQUE_NAME)")
    }

    companion object {
        const val CHANNEL = "org.codeberg.theoden8.webspace/background_task"
        const val UNIQUE_NAME = "webspace-notification-refresh"
        const val REFRESH_INTERVAL_MINUTES = 15L
        private const val TAG = "WebspaceBgRefresh"
    }
}

/**
 * Bridges [NotificationRefreshWorker] (which runs without an attached
 * Activity) to whichever [MethodChannel] is currently bound by the
 * plugin. All access happens on the main thread; the Worker uses
 * `Dispatchers.Main` to talk to it.
 */
internal object NotificationRefreshDispatcher {
    private val mainHandler = Handler(Looper.getMainLooper())
    private var channel: MethodChannel? = null
    private var pendingCompletion: ((Boolean) -> Unit)? = null

    fun bind(c: MethodChannel) {
        channel = c
    }

    fun unbind(c: MethodChannel) {
        if (channel === c) {
            channel = null
            // Any in-flight refresh that was awaiting Dart can no longer
            // complete — release its waiter so the worker stops blocking.
            val cb = pendingCompletion
            pendingCompletion = null
            cb?.invoke(false)
        }
    }

    /**
     * Returns false if no Flutter engine is currently reachable (the
     * activity is gone). The caller should treat the refresh as a no-op
     * and return `Result.success()` so WorkManager doesn't retry-storm.
     */
    fun dispatch(onComplete: (Boolean) -> Unit): Boolean {
        val c = channel ?: run {
            Log.w("WebspaceBgRefresh", "dispatch: no bound channel (engine gone)")
            return false
        }
        // Resolve any older pending refresh as failed before taking over.
        pendingCompletion?.invoke(false)
        pendingCompletion = onComplete
        mainHandler.post {
            Log.i("WebspaceBgRefresh", "dispatch: invoking onBackgroundRefresh in Dart")
            c.invokeMethod("onBackgroundRefresh", null)
        }
        return true
    }

    fun complete(success: Boolean) {
        val cb = pendingCompletion
        pendingCompletion = null
        cb?.invoke(success)
    }
}
