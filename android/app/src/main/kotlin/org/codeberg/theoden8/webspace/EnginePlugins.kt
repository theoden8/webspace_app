package org.codeberg.theoden8.webspace

import android.app.Activity
import android.content.Context
import io.flutter.embedding.engine.FlutterEngine

/**
 * The plugins that need no activity, registered on every engine the app
 * runs: the activity's, and the one [WorkerFlutterEngine] starts for a
 * background wake (NOTIF-016). One list, so the worker's engine cannot miss
 * one the app depends on at startup: without [WebSpaceContainerPlugin] the
 * `MULTI_PROFILE` gate reads false and the app would fall back to legacy
 * isolation, one cookie jar for every site.
 */
internal class EnginePlugins(
    context: Context,
    engine: FlutterEngine,
    activity: Activity?,
) {
    private val webIntercept = WebInterceptPlugin(activity, engine)
    private val container = WebSpaceContainerPlugin(engine)
    private val backgroundTask = BackgroundTaskAndroidPlugin(context.applicationContext, engine)
    private val mediaSession = MediaSessionPlugin(context.applicationContext, engine)
    private val proxyRelay = ProxyRelayPlugin(engine)
    private val siteIcon = SiteIconPlugin(context.applicationContext, engine)

    fun dispose() {
        backgroundTask.dispose()
        mediaSession.dispose()
        proxyRelay.dispose()
    }
}
