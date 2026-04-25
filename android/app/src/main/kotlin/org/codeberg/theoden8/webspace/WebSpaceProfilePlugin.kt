package org.codeberg.theoden8.webspace

import android.app.Activity
import android.view.View
import android.view.ViewGroup
import androidx.webkit.Profile
import androidx.webkit.ProfileStore
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import com.pichillilorenzo.flutter_inappwebview_android.webview.in_app_webview.InAppWebView
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/// Per-site Profile API plugin (Android only). Each WebViewModel.siteId
/// maps to a named native profile `ws-<siteId>` that owns its own cookie
/// jar, GeolocationPermissions, ServiceWorkerController, and storage
/// directory. Replaces the cookie-only capture-nuke-restore engine on
/// devices whose System WebView advertises WebViewFeature.MULTI_PROFILE
/// (Chrome / Android System WebView 110+, androidx.webkit 1.9+).
///
/// Methods called from [profile_native.dart]:
///   - isSupported(): WebViewFeature.MULTI_PROFILE feature gate
///   - getOrCreateProfile(siteId): idempotent ProfileStore lookup
///   - bindProfileToWebView(siteId): tree-walks the activity's view
///     hierarchy, finds InAppWebViews flutter_inappwebview created, and
///     calls WebViewCompat.setProfile on each. Same enumeration pattern
///     as [WebInterceptPlugin.attachToAllWebViews].
///   - deleteProfile(siteId): ProfileStore.deleteProfile
///   - listProfiles(): all `ws-*` entries from ProfileStore
class WebSpaceProfilePlugin(private val activity: Activity, flutterEngine: FlutterEngine) {
    private val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "isSupported" -> result.success(isSupported())
                "getOrCreateProfile" -> {
                    val siteId = call.argument<String>("siteId")
                    if (siteId == null) {
                        result.error("INVALID_ARGS", "siteId required", null)
                    } else if (!isSupported()) {
                        result.error("UNSUPPORTED", "Profile API not supported on this WebView", null)
                    } else {
                        try {
                            val name = profileNameFor(siteId)
                            ProfileStore.getInstance().getOrCreateProfile(name)
                            result.success(name)
                        } catch (e: Exception) {
                            result.error("PROFILE_ERROR", e.message, null)
                        }
                    }
                }
                "bindProfileToWebView" -> {
                    val siteId = call.argument<String>("siteId")
                    if (siteId == null) {
                        result.error("INVALID_ARGS", "siteId required", null)
                    } else if (!isSupported()) {
                        result.success(0)
                    } else {
                        try {
                            val count = bindProfile(siteId)
                            result.success(count)
                        } catch (e: Exception) {
                            result.error("BIND_ERROR", e.message, null)
                        }
                    }
                }
                "deleteProfile" -> {
                    val siteId = call.argument<String>("siteId")
                    if (siteId == null) {
                        result.error("INVALID_ARGS", "siteId required", null)
                    } else if (!isSupported()) {
                        result.success(null)
                    } else {
                        try {
                            ProfileStore.getInstance().deleteProfile(profileNameFor(siteId))
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("DELETE_ERROR", e.message, null)
                        }
                    }
                }
                "listProfiles" -> {
                    if (!isSupported()) {
                        result.success(emptyList<String>())
                    } else {
                        try {
                            val all = ProfileStore.getInstance().allProfileNames
                            // Strip the `ws-` prefix so the Dart side gets siteIds
                            // back, matching what it stored.
                            val siteIds = all
                                .filter { it.startsWith(PROFILE_PREFIX) }
                                .map { it.substring(PROFILE_PREFIX.length) }
                            result.success(siteIds)
                        } catch (e: Exception) {
                            result.error("LIST_ERROR", e.message, null)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun isSupported(): Boolean {
        return WebViewFeature.isFeatureSupported(WebViewFeature.MULTI_PROFILE)
    }

    private fun profileNameFor(siteId: String): String = "$PROFILE_PREFIX$siteId"

    /// Walks the activity's view tree, finds every flutter_inappwebview
    /// InAppWebView, and binds the requested profile to each. setProfile
    /// throws IllegalStateException if the WebView has already started a
    /// session-bound operation (loadUrl, evaluateJavascript, etc.) — we
    /// catch and skip those so a single race doesn't fail the whole batch
    /// and so a re-bind on a fresh instance still succeeds.
    private fun bindProfile(siteId: String): Int {
        val rootView = activity.window.decorView.rootView
        val webViews = mutableListOf<InAppWebView>()
        findInAppWebViews(rootView, webViews)
        val profileName = profileNameFor(siteId)
        var bound = 0
        for (webView in webViews) {
            // Skip webviews that already have the right profile to keep this
            // call idempotent (the Dart side may invoke it on every
            // onWebViewCreated for safety).
            val current: Profile? = try {
                WebViewCompat.getProfile(webView)
            } catch (_: Throwable) {
                null
            }
            if (current?.name == profileName) {
                bound++
                continue
            }
            try {
                WebViewCompat.setProfile(webView, profileName)
                bound++
            } catch (_: IllegalStateException) {
                // WebView has already done a session-bound operation; binding
                // is no longer permitted on this instance. Falls back to the
                // default profile for this view.
            } catch (_: UnsupportedOperationException) {
                // Profile API not actually supported (shouldn't happen if
                // isSupported() returned true, but be defensive).
            } catch (_: Throwable) {
                // Defensive: never let a single view's failure propagate.
            }
        }
        return bound
    }

    private fun findInAppWebViews(view: View, results: MutableList<InAppWebView>) {
        if (view is InAppWebView) {
            results.add(view)
        }
        if (view is ViewGroup) {
            for (i in 0 until view.childCount) {
                findInAppWebViews(view.getChildAt(i), results)
            }
        }
    }

    companion object {
        const val CHANNEL = "org.codeberg.theoden8.webspace/profile"
        // Prefix every WebSpace-managed profile with `ws-` so listProfiles
        // can disambiguate them from any profiles other parts of the app
        // (or future plugin versions) might create. Also matches the spec.
        private const val PROFILE_PREFIX = "ws-"
    }
}
