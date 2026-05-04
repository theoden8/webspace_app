package org.codeberg.theoden8.webspace

import android.content.Context
import android.content.Intent
import android.os.Build
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Method-channel bridge for [BackgroundPollService]. Mirrors
 * [AndroidForegroundService] on the Dart side.
 *
 * Methods:
 *   - `start(count: Int)` — start (or update) the foreground service
 *     with a persistent notification "WebSpace is checking N sites for
 *     updates".
 *   - `stop()` — stop the foreground service and dismiss the
 *     notification.
 *
 * All calls return `null` (success) — the Dart side does not depend on a
 * synchronous result; the service starts asynchronously after this call.
 */
class WebSpaceBackgroundPollPlugin(
    private val context: Context,
    flutterEngine: FlutterEngine,
) {
    private val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val count = call.argument<Int>("count") ?: 1
                    val intent = Intent(context, BackgroundPollService::class.java).apply {
                        action = BackgroundPollService.ACTION_START
                        putExtra(BackgroundPollService.EXTRA_COUNT, count)
                    }
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        context.startForegroundService(intent)
                    } else {
                        context.startService(intent)
                    }
                    result.success(null)
                }
                "stop" -> {
                    val intent = Intent(context, BackgroundPollService::class.java).apply {
                        action = BackgroundPollService.ACTION_STOP
                    }
                    // startService(STOP) so the service receives the
                    // intent in onStartCommand, which calls stopForeground
                    // + stopSelf. Plain stopService skips onStartCommand
                    // and may leave the persistent notification visible
                    // until the OS reaps it.
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        context.startForegroundService(intent)
                    } else {
                        context.startService(intent)
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    companion object {
        const val CHANNEL = "org.codeberg.theoden8.webspace/background-poll"
    }
}
