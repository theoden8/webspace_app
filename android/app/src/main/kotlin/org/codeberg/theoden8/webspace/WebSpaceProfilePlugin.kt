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
    /// InAppWebView, and binds the requested profile to those that are
    /// still on the default profile (i.e. fresh, not yet loaded — at most
    /// one such WebView is in the tree at any moment, the one whose
    /// `onWebViewCreated` triggered this bind call).
    ///
    /// Webviews already bound to a non-default profile are siblings owned
    /// by other sites; touching them with `setProfile` would throw because
    /// they have already started session-bound operations. We skip them
    /// explicitly rather than swallowing the resulting exception, so the
    /// returned count is a faithful "bound for this siteId" tally and the
    /// surfaced log line accurately reports race losses.
    private fun bindProfile(siteId: String): Int {
        val rootView = activity.window.decorView.rootView
        val webViews = mutableListOf<InAppWebView>()
        findInAppWebViews(rootView, webViews)
        val profileName = profileNameFor(siteId)
        var newlyBound = 0
        var alreadyBound = 0
        var skippedSibling = 0
        var raceLost = 0
        for (webView in webViews) {
            val current: Profile? = try {
                WebViewCompat.getProfile(webView)
            } catch (_: Throwable) {
                null
            }
            val currentName = current?.name
            when {
                currentName == profileName -> {
                    // Already bound to this exact profile — re-bind on
                    // page reload, etc. Idempotent.
                    alreadyBound++
                }
                currentName != null && currentName != Profile.DEFAULT_PROFILE_NAME -> {
                    // A sibling site's webview, already loaded under its
                    // own profile. Don't touch it.
                    skippedSibling++
                }
                else -> {
                    // Fresh webview (default profile or null) — try to bind.
                    try {
                        WebViewCompat.setProfile(webView, profileName)
                        newlyBound++
                    } catch (_: IllegalStateException) {
                        // The view already started a session-bound operation
                        // (typically `webView.loadUrl(initialUrlRequest)` running
                        // before our bind on the platform-view-creation
                        // timeline). The Dart construction path is supposed to
                        // defer the initial load when profile mode is active so
                        // this branch doesn't fire — a non-zero raceLost in the
                        // surfaced log line means something queued a load too
                        // early and that webview is now leaking into the default
                        // profile.
                        raceLost++
                    } catch (_: UnsupportedOperationException) {
                        // Profile API not actually supported (shouldn't happen
                        // if isSupported() returned true, but be defensive).
                        raceLost++
                    } catch (_: Throwable) {
                        raceLost++
                    }
                }
            }
        }
        android.util.Log.i(
            "WebSpaceProfilePlugin",
            "bind siteId=$siteId profile=$profileName " +
                "newly=$newlyBound already=$alreadyBound " +
                "siblings=$skippedSibling raceLost=$raceLost " +
                "totalWebViews=${webViews.size}"
        )
        return newlyBound + alreadyBound
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
