package org.codeberg.theoden8.webspace

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager

/**
 * Debug-only trigger for a single [NotificationRefreshWorker] run, used by
 * the adb lifecycle tier (INTEG-012).
 *
 * The periodic work cannot be driven from outside the process:
 * `cmd jobscheduler run -f` bypasses JobScheduler's own constraints, but
 * WorkManager still refuses any periodic `WorkSpec` whose next run time has
 * not arrived ("executed before schedule") and silently reschedules instead,
 * so the forced job reaches neither the worker nor Dart. Enqueueing a
 * one-shot of the same worker runs the leg the scenario is about — worker to
 * `NotificationRefreshDispatcher` to `onBackgroundRefresh` to the reload —
 * with the scheduling contract asserted separately from the job dump.
 *
 * Lives in the `debug` source set: no release build compiles or declares it.
 */
class NotificationRefreshDebugReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        Log.i(TAG, "debug trigger: enqueueing a one-shot notification refresh")
        // No constraints: the point is to reach the worker now, not to
        // re-test what the periodic request's constraints gate.
        WorkManager.getInstance(context.applicationContext).enqueueUniqueWork(
            UNIQUE_NAME,
            ExistingWorkPolicy.REPLACE,
            OneTimeWorkRequestBuilder<NotificationRefreshWorker>().build(),
        )
    }

    private companion object {
        const val UNIQUE_NAME = "webspace-notification-refresh-once"
        const val TAG = "WebspaceBgRefresh"
    }
}
