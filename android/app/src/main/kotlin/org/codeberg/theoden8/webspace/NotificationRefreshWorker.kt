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
 * 15 min by [BackgroundTaskAndroidPlugin]'s `PeriodicWorkRequest`. If
 * the Flutter engine is still reachable (cached activity, warm process)
 * we hand control to the Dart `onBackgroundRefresh` handler which
 * reloads every loaded notification site; otherwise we exit cleanly so
 * WorkManager moves on to the next slot.
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
        val dispatched = NotificationRefreshDispatcher.dispatch { success ->
            if (!deferred.isCompleted) deferred.complete(success)
        }
        if (!dispatched) {
            Log.w(TAG, "Flutter engine unreachable — refresh is a no-op this slot")
            BackgroundLogFile.record(
                applicationContext,
                "no Flutter engine in this process; refresh skipped, no site reloaded",
                "warning",
            )
            return@withContext Result.success()
        }
        val started = System.currentTimeMillis()
        // 60s ceiling — Dart's reload-all-notif-sites flow finishes in
        // a few seconds in practice; the cap stops a stuck channel from
        // pinning the worker until WorkManager's own ~10min ANR timeout.
        val result = try {
            withTimeoutOrNull(REFRESH_TIMEOUT_MS) { deferred.await() }
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
            Log.w(TAG, "Dart did not report completion within ${REFRESH_TIMEOUT_MS}ms")
            BackgroundLogFile.record(
                applicationContext,
                "Dart did not report completion within ${REFRESH_TIMEOUT_MS}ms",
                "warning",
            )
        } else {
            Log.i(TAG, "Dart reported refresh complete (success=$result)")
            BackgroundLogFile.record(
                applicationContext,
                "Dart reported refresh complete (success=$result) after ${elapsed}ms",
            )
        }
        // Either branch returns success — retrying a stale wakeup adds
        // no value, the next periodic slot does the same job fresh.
        Result.success()
    }

    companion object {
        private const val REFRESH_TIMEOUT_MS = 60_000L
        private const val TAG = "WebspaceBgRefresh"
    }
}
