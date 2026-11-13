package org.codeberg.theoden8.webspace

import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * What Dart asks of the app's launch. [MainActivity] answers from its launch
 * intent, [WorkerFlutterEngine] with [NothingLaunched]; a query added here
 * does not compile until both answer it. Each read drains what it returns, so
 * a resume does not deliver it twice.
 */
internal interface LaunchSource {
    /** The tapped tile's `siteId` and `shortcutId`. */
    fun launchSite(): Map<String, String?>?
    /** The INTEG-011 adb tier's extras, read only on a debuggable build. */
    fun diagSeed(): String?
    fun diagRepaintSuppression(): String?
    fun diagReload(): String?
    /** What another app shared: a URL, or an HTML file with its title. */
    fun sharedUrl(): String?
    fun sharedHtml(): Map<String, String?>?
}

/** A wake's engine: no intent, so nothing was launched or shared. */
internal object NothingLaunched : LaunchSource {
    override fun launchSite(): Map<String, String?>? = null
    override fun diagSeed(): String? = null
    override fun diagRepaintSuppression(): String? = null
    override fun diagReload(): String? = null
    override fun sharedUrl(): String? = null
    override fun sharedHtml(): Map<String, String?>? = null
}

/** The `shortcuts` and `share_intent` channels, which every engine serves. */
internal object LaunchChannels {
    private const val SHORTCUTS = "org.codeberg.theoden8.webspace/shortcuts"
    private const val SHARE = "org.codeberg.theoden8.webspace/share_intent"

    /** [act] answers the rest of the shortcuts channel: pins and tile updates,
     * which only an activity makes. */
    fun register(
        messenger: BinaryMessenger,
        context: Context,
        source: LaunchSource,
        act: (MethodCall, MethodChannel.Result) -> Unit,
    ) {
        MethodChannel(messenger, SHORTCUTS).setMethodCallHandler { call, result ->
            when (call.method) {
                "getLaunchSiteId" -> result.success(source.launchSite())
                "getDiagSeed" -> result.success(source.diagSeed())
                "getDiagRepaintSuppression" -> result.success(source.diagRepaintSuppression())
                "getDiagReload" -> result.success(source.diagReload())
                // Real in every engine, or startup would drop their ledger (HS-011).
                "getPinnedShortcuts" -> result.success(pinnedShortcuts(context))
                else -> act(call, result)
            }
        }
        MethodChannel(messenger, SHARE).setMethodCallHandler { call, result ->
            when (call.method) {
                "consumeLaunchUrl" -> result.success(source.sharedUrl())
                "consumeLaunchHtml" -> result.success(source.sharedHtml())
                else -> result.notImplemented()
            }
        }
    }
}
