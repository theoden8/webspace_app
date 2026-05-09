package org.codeberg.theoden8.webspace

import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
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
        val deferred = CompletableDeferred<Boolean>()
        val dispatched = NotificationRefreshDispatcher.dispatch { success ->
            if (!deferred.isCompleted) deferred.complete(success)
        }
        if (!dispatched) return@withContext Result.success()
        // 60s ceiling — Dart's reload-all-notif-sites flow finishes in
        // a few seconds in practice; the cap stops a stuck channel from
        // pinning the worker until WorkManager's own ~10min ANR timeout.
        withTimeoutOrNull(REFRESH_TIMEOUT_MS) { deferred.await() }
        // Either branch returns success — retrying a stale wakeup adds
        // no value, the next periodic slot does the same job fresh.
        Result.success()
    }

    companion object {
        private const val REFRESH_TIMEOUT_MS = 60_000L
    }
}
