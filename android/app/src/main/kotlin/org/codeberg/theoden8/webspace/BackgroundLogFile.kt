package org.codeberg.theoden8.webspace

import android.Manifest
import android.app.ActivityManager
import android.app.NotificationManager
import android.app.usage.UsageStatsManager
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.work.WorkInfo
import androidx.work.WorkManager
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.Executors
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking

/**
 * Native half of the background log (DEVTOOLS-012): JSON lines under
 * `filesDir`, written by [BackgroundTaskAndroidPlugin] and
 * [NotificationRefreshWorker] and appended to from Dart. The file exists only
 * while developer mode is on, and its existence is the switch, so a worker in
 * a process Dart never started records exactly then.
 *
 * Nothing written here names a site: the native side has no site data, and
 * Dart sends only its non-sensitive lines.
 *
 * Single owner (BUG-007): every read, append, compaction and delete runs on
 * [io], one thread. The channel (main thread) and the worker's coroutine only
 * enqueue, so no two paths touch the file at once.
 */
internal object BackgroundLogFile {
    private const val TAG = "WebspaceBgLog"
    private const val FILE_NAME = "background_log.jsonl"
    private const val MAX_LINES = 1000
    private const val COMPACT_AT_BYTES = 192 * 1024L

    private val io = Executors.newSingleThreadExecutor { r ->
        Thread(r, TAG).apply { isDaemon = true }
    }
    private val main = Handler(Looper.getMainLooper())

    private fun dir(context: Context) = context.applicationContext.filesDir

    fun record(context: Context, message: String, level: String = "info") {
        append(context, System.currentTimeMillis(), level, "Android", message)
    }

    fun append(context: Context, t: Long, level: String, tag: String, message: String) {
        val line = JSONObject()
            .put("t", t)
            .put("l", level)
            .put("g", tag)
            .put("m", message)
            .toString()
        val dir = dir(context)
        io.execute {
            val f = File(dir, FILE_NAME)
            if (!f.exists()) return@execute
            try {
                FileOutputStream(f, true).use { it.write("$line\n".toByteArray()) }
                if (f.length() > COMPACT_AT_BYTES) compact(dir, f)
            } catch (e: IOException) {
                Log.w(TAG, "append failed: $e")
            }
        }
    }

    /** Keeps the newest [MAX_LINES]; the rename leaves the old file whole if
     * the process dies mid-write. */
    private fun compact(dir: File, f: File) {
        val keep = f.readLines().filter { it.isNotBlank() }.takeLast(MAX_LINES)
        val tmp = File(dir, "$FILE_NAME.tmp")
        tmp.writeText(keep.joinToString(separator = "\n", postfix = "\n"))
        if (!tmp.renameTo(f)) throw IOException("rename to $FILE_NAME failed")
    }

    fun setEnabled(context: Context, enabled: Boolean) {
        val dir = dir(context)
        io.execute {
            val f = File(dir, FILE_NAME)
            try {
                if (enabled) {
                    if (!f.exists()) f.createNewFile()
                } else {
                    f.delete()
                    File(dir, "$FILE_NAME.tmp").delete()
                }
            } catch (e: IOException) {
                Log.w(TAG, "setEnabled($enabled) failed: $e")
            }
        }
    }

    fun clear(context: Context) {
        val dir = dir(context)
        io.execute {
            val f = File(dir, FILE_NAME)
            try {
                if (f.exists()) f.writeText("")
            } catch (e: IOException) {
                Log.w(TAG, "clear failed: $e")
            }
        }
    }

    /** [done] runs on the main thread with the lines, or null when the file
     * could not be read. */
    fun read(context: Context, done: (List<String>?) -> Unit) {
        val dir = dir(context)
        io.execute {
            val f = File(dir, FILE_NAME)
            val lines = try {
                if (f.exists()) f.readLines().filter { it.isNotBlank() } else emptyList()
            } catch (e: IOException) {
                Log.w(TAG, "read failed: $e")
                null
            }
            main.post { done(lines) }
        }
    }

    /**
     * The OS gates a periodic refresh and a notification depend on, as
     * ordered (name, value) rows. Runs on [io] because the WorkManager query
     * blocks; [done] runs on the main thread.
     */
    fun systemState(context: Context, uniqueWorkName: String, done: (List<List<String>>) -> Unit) {
        val app = context.applicationContext
        io.execute {
            val rows = mutableListOf<List<String>>()
            fun row(name: String, value: Any?) = rows.add(listOf("android.$name", value.toString()))

            row("sdk", Build.VERSION.SDK_INT)
            row("notificationsEnabled", NotificationManagerCompat.from(app).areNotificationsEnabled())
            if (Build.VERSION.SDK_INT >= 33) {
                row(
                    "postNotificationsPermission",
                    ContextCompat.checkSelfPermission(app, Manifest.permission.POST_NOTIFICATIONS) ==
                        PackageManager.PERMISSION_GRANTED,
                )
            }
            if (Build.VERSION.SDK_INT >= 26) {
                val nm = app.getSystemService(NotificationManager::class.java)
                val channel = nm?.getNotificationChannel("webspace_web_notifications")
                row("channelImportance", channel?.importance ?: "channel not created")
            }
            val pm = app.getSystemService(Context.POWER_SERVICE) as? PowerManager
            if (pm != null) {
                if (Build.VERSION.SDK_INT >= 23) {
                    row("ignoringBatteryOptimizations", pm.isIgnoringBatteryOptimizations(app.packageName))
                    row("deviceIdle", pm.isDeviceIdleMode)
                }
                row("powerSaveMode", pm.isPowerSaveMode)
            }
            if (Build.VERSION.SDK_INT >= 28) {
                val usm = app.getSystemService(Context.USAGE_STATS_SERVICE) as? UsageStatsManager
                if (usm != null) row("standbyBucket", standbyBucketName(usm.appStandbyBucket))
                val am = app.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
                if (am != null) row("backgroundRestricted", am.isBackgroundRestricted)
            }
            try {
                // The Flow, not the ListenableFuture overload: Guava's future
                // type is not on this module's compile classpath.
                val infos = runBlocking {
                    WorkManager.getInstance(app)
                        .getWorkInfosForUniqueWorkFlow(uniqueWorkName).first()
                }
                if (infos.isEmpty()) {
                    row("refreshWork", "not enqueued")
                }
                for (info in infos) {
                    row("refreshWork", info.state.name)
                    row("refreshWorkAttempts", info.runAttemptCount)
                    val next = info.nextScheduleTimeMillis
                    row("refreshWorkNextRun", if (next == Long.MAX_VALUE) "none" else formatTime(next))
                    if (info.stopReason != WorkInfo.STOP_REASON_NOT_STOPPED) {
                        row("refreshWorkLastStopReason", info.stopReason)
                    }
                }
            } catch (e: InterruptedException) {
                row("refreshWork", "query interrupted")
            }
            main.post { done(rows) }
        }
    }

    private fun standbyBucketName(bucket: Int) = when (bucket) {
        UsageStatsManager.STANDBY_BUCKET_ACTIVE -> "active"
        UsageStatsManager.STANDBY_BUCKET_WORKING_SET -> "working_set"
        UsageStatsManager.STANDBY_BUCKET_FREQUENT -> "frequent"
        UsageStatsManager.STANDBY_BUCKET_RARE -> "rare"
        UsageStatsManager.STANDBY_BUCKET_RESTRICTED -> "restricted"
        else -> bucket.toString()
    }

    fun formatTime(epochMs: Long): String =
        SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US).format(Date(epochMs))
}
