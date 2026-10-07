package org.codeberg.theoden8.webspace

import android.content.Context
import android.os.Build
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterShellArgs
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/**
 * NOTIF-005-A / NOTIF-016: the Flutter engine [NotificationRefreshWorker]
 * starts when no activity's engine is reachable, because Android reclaimed
 * the process or the activity was closed. It runs the app's own `main` with
 * no activity, so the startup that loads the sites, their containers and
 * their proxies is the one the app always runs, and the wake that follows
 * checks each notification site in a headless webview.
 *
 * Main-thread confined (BUG-007): the worker, on `Dispatchers.Main`, starts
 * and stops it, and [MainActivity] stops it before building its own engine;
 * nothing else reads or writes [running].
 */
internal object WorkerFlutterEngine {
    private const val SHORTCUTS_CHANNEL = "org.codeberg.theoden8.webspace/shortcuts"
    private const val SHARE_CHANNEL = "org.codeberg.theoden8.webspace/share_intent"

    /** `kBackgroundWakeArg` in lib/services/launch_context.dart. */
    private const val BACKGROUND_WAKE_ARG = "--background-wake"

    private class Running(val engine: FlutterEngine, val plugins: EnginePlugins)

    private var running: Running? = null

    val isRunning: Boolean
        get() {
            checkMain()
            return running != null
        }

    /** Disables Impeller on x86/x86_64 (Waydroid, emulators), where Vulkan
     * swapchain creation crashes. Falls back to Skia + OpenGL ES, which is
     * still hardware-accelerated. */
    fun forThisDevice(args: FlutterShellArgs): FlutterShellArgs {
        if (Build.SUPPORTED_ABIS.any { it == "x86_64" || it == "x86" }) {
            args.remove(FlutterShellArgs.ARG_ENABLE_IMPELLER)
            args.add(FlutterShellArgs.ARG_DISABLE_IMPELLER)
        }
        return args
    }

    fun start(context: Context) {
        checkMain()
        if (running != null) return
        val app = context.applicationContext
        val engine = FlutterEngine(
            app,
            forThisDevice(FlutterShellArgs(arrayOf<String>())).toArray(),
        )
        val plugins = EnginePlugins(app, engine, activity = null)
        registerLaunchChannels(app, engine)
        // Tells `main` it runs for a wake with no activity, so it builds no
        // site webview: the native blockers could not find one (NOTIF-016).
        engine.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint.createDefault(),
            listOf(BACKGROUND_WAKE_ARG),
        )
        running = Running(engine, plugins)
        BackgroundLogFile.record(app, "started a Flutter engine for the wake, with no activity")
    }

    fun stop(context: Context, reason: String) {
        checkMain()
        val r = running ?: return
        running = null
        r.plugins.dispose()
        r.engine.destroy()
        BackgroundLogFile.record(context, "stopped the wake's Flutter engine: $reason")
    }

    /** What [MainActivity] answers from its launch intent. There is no
     * intent here, so nothing was launched or shared; the pinned shortcuts
     * are real, or startup would drop their ledger (HS-011). */
    private fun registerLaunchChannels(app: Context, engine: FlutterEngine) {
        val messenger = engine.dartExecutor.binaryMessenger
        MethodChannel(messenger, SHORTCUTS_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getLaunchSiteId", "getDiagSeed", "getDiagRepaintSuppression",
                "getDiagReload" -> result.success(null)
                "getPinnedSiteIds" -> result.success(pinnedSiteIds(app))
                else -> result.notImplemented()
            }
        }
        MethodChannel(messenger, SHARE_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "consumeLaunchUrl", "consumeLaunchHtml" -> result.success(null)
                else -> result.notImplemented()
            }
        }
    }

    private fun checkMain() =
        check(Looper.myLooper() == Looper.getMainLooper()) {
            "WorkerFlutterEngine is main-thread confined"
        }
}
