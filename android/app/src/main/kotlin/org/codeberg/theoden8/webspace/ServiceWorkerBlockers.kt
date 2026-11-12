package org.codeberg.theoden8.webspace

import android.webkit.ServiceWorkerClient
import android.webkit.ServiceWorkerController
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import androidx.webkit.Profile
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import com.pichillilorenzo.flutter_inappwebview_android.types.WebResourceRequestExt

/// The service workers of each site's container (CB-022). A container is a
/// WebView profile with a service worker controller of its own, and a
/// worker's requests reach that controller's client, never a webview's, so
/// they would meet none of the site's blockers. The client is the interceptor
/// the site's webview runs: a worker loads what the site's pages may load, at
/// its DNS level, filter lists and LocalCDN, and counts in its report.
class ServiceWorkerBlockers(private val log: (String, String) -> Unit) {
    /// Hands [workers] to [interceptor] and lets them onto the network. The
    /// log says whether the profile's workers had the network before, which
    /// tells whether the app-wide block at launch reaches a site's container.
    fun attach(workers: ProfileWorkers?, interceptor: FastSubresourceInterceptor, siteId: String) {
        if (workers == null) return
        val blocked = workers.blockNetworkLoads
        // The client before the network, so no request goes out unjudged.
        workers.setClient(SiteServiceWorkerClient(interceptor))
        workers.blockNetworkLoads = false
        log("ServiceWorker",
            "site=$siteId profile=${workers.name} through the site's blockers " +
            "(network blocked was $blocked)")
    }
}

/// One profile's service workers, as [ServiceWorkerBlockers] reaches them.
interface ProfileWorkers {
    val name: String
    var blockNetworkLoads: Boolean
    fun setClient(client: ServiceWorkerClient)

    companion object {
        /// [webView]'s container, or null where it runs in the default
        /// profile (no MULTI_PROFILE), which the app-wide block at launch
        /// covers. Main thread only.
        fun of(webView: WebView): ProfileWorkers? {
            if (!WebViewFeature.isFeatureSupported(WebViewFeature.MULTI_PROFILE)) return null
            val profile = WebViewCompat.getProfile(webView)
            if (profile.name == Profile.DEFAULT_PROFILE_NAME) return null
            return ControllerWorkers(profile.name, profile.serviceWorkerController)
        }
    }
}

private class ControllerWorkers(
    override val name: String,
    private val controller: ServiceWorkerController,
) : ProfileWorkers {
    override var blockNetworkLoads: Boolean
        get() = controller.serviceWorkerWebSettings.blockNetworkLoads
        set(value) {
            controller.serviceWorkerWebSettings.blockNetworkLoads = value
        }

    override fun setClient(client: ServiceWorkerClient) =
        controller.setServiceWorkerClient(client)
}

/// A worker's request, judged as a request of the site's pages is.
class SiteServiceWorkerClient(
    private val interceptor: FastSubresourceInterceptor,
) : ServiceWorkerClient() {
    override fun shouldInterceptRequest(request: WebResourceRequest): WebResourceResponse? =
        check(WebResourceRequestExt.fromWebResourceRequest(request))

    internal fun check(request: WebResourceRequestExt): WebResourceResponse? =
        interceptor.check(request)
}
