package org.codeberg.theoden8.webspace

import android.content.Context
import android.util.Log
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

/**
 * NOTIF-005-A: opportunistic refresh worker. Dispatched roughly every
 * 15 min by [BackgroundTaskAndroidPlugin]'s `PeriodicWorkRequest`. It hands
 * control to the Dart `onBackgroundRefresh` handler, which checks every
 * notification site (NOTIF-016). When no Flutter engine is reachable,
 * because Android reclaimed the process or the activity was closed, it
 * starts one ([WorkerFlutterEngine]) for the wake and destroys it after.
 */
class NotificationRefreshWorker(
    appContext: Context,
    params: WorkerParameters,
) : CoroutineWorker(appContext, params) {

    override suspend fun doWork(): Result = withContext(Dispatchers.Main) {
        Log.i(TAG, "NotificationRefreshWorker fired")
        BackgroundLogFile.record(
            applicationContext,
            "refresh worker fired (attempt ${runAttemptCount + 1})",
        )
        val deferred = CompletableDeferred<Boolean>()
        val onComplete = { success: Boolean ->
            if (!deferred.isCompleted) deferred.complete(success)
        }
        var startedEngine = false
        if (!NotificationRefreshDispatcher.dispatch(onComplete)) {
            Log.i(TAG, "Flutter engine unreachable; starting one for the wake")
            BackgroundLogFile.record(
                applicationContext,
                "no Flutter engine in this process; starting one for the wake",
            )
            WorkerFlutterEngine.start(applicationContext)
            startedEngine = true
            // The engine's BackgroundTaskAndroidPlugin binds the dispatcher
            // as it is built; the wake then waits for Dart to be ready.
            if (!NotificationRefreshDispatcher.dispatch(onComplete)) {
                WorkerFlutterEngine.stop(applicationContext, "its refresh channel did not bind")
                return@withContext Result.success()
            }
        }
        // A started engine runs the app's startup before the wake; the
        // ceiling stops a stuck channel from pinning the worker until
        // WorkManager's own ~10min timeout.
        val timeoutMs = if (startedEngine) COLD_REFRESH_TIMEOUT_MS else REFRESH_TIMEOUT_MS
        val started = System.currentTimeMillis()
        try {
            val result = try {
                withTimeoutOrNull(timeoutMs) { deferred.await() }
            } catch (e: CancellationException) {
                BackgroundLogFile.record(
                    applicationContext,
                    "refresh worker stopped before Dart finished (stopReason $stopReason)",
                    "warning",
                )
                throw e
            }
            val elapsed = System.currentTimeMillis() - started
            if (result == null) {
                Log.w(TAG, "Dart did not report completion within ${timeoutMs}ms")
                BackgroundLogFile.record(
                    applicationContext,
                    "Dart did not report completion within ${timeoutMs}ms",
                    "warning",
                )
            } else {
                Log.i(TAG, "Dart reported refresh complete (success=$result)")
                BackgroundLogFile.record(
                    applicationContext,
                    "Dart reported refresh complete (success=$result) after ${elapsed}ms",
                )
            }
        } finally {
            if (startedEngine) WorkerFlutterEngine.stop(applicationContext, "the wake ended")
        }
        // Either branch returns success — retrying a stale wakeup adds
        // no value, the next periodic slot does the same job fresh.
        Result.success()
    }

    companion object {
        private const val REFRESH_TIMEOUT_MS = 60_000L
        private const val COLD_REFRESH_TIMEOUT_MS = 120_000L
        private const val TAG = "WebspaceBgRefresh"
    }
}
