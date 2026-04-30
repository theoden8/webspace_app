package org.codeberg.theoden8.webspace

import android.app.Activity
import android.os.CancellationSignal
import android.util.Log
import android.view.ViewGroup
import android.webkit.WebView
import androidx.credentials.CreateCredentialResponse
import androidx.credentials.CreatePublicKeyCredentialRequest
import androidx.credentials.CredentialManager
import androidx.credentials.CredentialManagerCallback
import androidx.credentials.GetCredentialRequest
import androidx.credentials.GetCredentialResponse
import androidx.credentials.GetPublicKeyCredentialOption
import androidx.credentials.exceptions.CreateCredentialException
import androidx.credentials.exceptions.GetCredentialException
import androidx.webkit.WebSettingsCompat
import androidx.webkit.WebViewFeature
import java.util.concurrent.Executors

private const val TAG = "WebAuthnHandler"

class WebAuthnHandler(private val activity: Activity) {

    interface WebAuthnResultCallback {
        fun onSuccess(responseJson: String)
        fun onError(errorType: String, errorMessage: String)
    }

    private val credentialManager = CredentialManager.create(activity)
    private val executor = Executors.newSingleThreadExecutor()

    /**
     * Set up WebAuthn support on all WebViews in the activity's view hierarchy.
     * Returns a diagnostic string with the result of the setup.
     */
    fun setupWebAuthn(): String {
        val supported = try {
            WebViewFeature.isFeatureSupported(WebViewFeature.WEB_AUTHENTICATION)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to check WEB_AUTHENTICATION feature support", e)
            false
        }

        if (!supported) {
            val msg = "WEB_AUTHENTICATION feature not supported by this WebView"
            Log.w(TAG, msg)
            return msg
        }

        val webViews = findWebViews(activity.window.decorView as? ViewGroup)
        if (webViews.isEmpty()) {
            val msg = "WEB_AUTHENTICATION supported but no WebViews found in hierarchy"
            Log.w(TAG, msg)
            return msg
        }

        var configured = 0
        for (wv in webViews) {
            try {
                WebSettingsCompat.setWebAuthenticationSupport(
                    wv.settings,
                    WebSettingsCompat.WEB_AUTHENTICATION_SUPPORT_FOR_APP
                )
                configured++
            } catch (e: Exception) {
                Log.e(TAG, "Failed to set WebAuthentication support on WebView", e)
            }
        }

        val msg = "WebAuthn: configured $configured/${webViews.size} WebViews (FOR_APP mode)"
        Log.i(TAG, msg)
        return msg
    }

    /**
     * Handle a WebAuthn navigator.credentials.create() request via Credential Manager.
     *
     * Note: We use CreatePublicKeyCredentialRequest WITHOUT setting origin because
     * CREDENTIAL_MANAGER_SET_ORIGIN requires a system-level permission that third-party
     * apps cannot obtain. The Credential Manager will use the app's package identity.
     */
    fun handleCreate(requestJson: String, origin: String, callback: WebAuthnResultCallback) {
        Log.d(TAG, "handleCreate: origin=$origin requestJson=${requestJson.take(200)}...")

        val request = CreatePublicKeyCredentialRequest(
            requestJson = requestJson
        )

        credentialManager.createCredentialAsync(
            context = activity,
            request = request,
            cancellationSignal = CancellationSignal(),
            executor = executor,
            callback = object : CredentialManagerCallback<CreateCredentialResponse, CreateCredentialException> {
                override fun onResult(result: CreateCredentialResponse) {
                    Log.d(TAG, "createCredential success: type=${result.type}")
                    callback.onSuccess(result.data.getString("androidx.credentials.BUNDLE_KEY_REGISTRATION_RESPONSE_JSON", "{}"))
                }

                override fun onError(e: CreateCredentialException) {
                    Log.e(TAG, "createCredential error: type=${e.type} message=${e.message}")
                    callback.onError(e.type, e.message ?: "Unknown error")
                }
            }
        )
    }

    /**
     * Handle a WebAuthn navigator.credentials.get() request via Credential Manager.
     */
    fun handleGet(requestJson: String, origin: String, callback: WebAuthnResultCallback) {
        Log.d(TAG, "handleGet: origin=$origin requestJson=${requestJson.take(200)}...")

        val option = GetPublicKeyCredentialOption(
            requestJson = requestJson
        )

        val request = GetCredentialRequest.Builder()
            .addCredentialOption(option)
            .build()

        credentialManager.getCredentialAsync(
            context = activity,
            request = request,
            cancellationSignal = CancellationSignal(),
            executor = executor,
            callback = object : CredentialManagerCallback<GetCredentialResponse, GetCredentialException> {
                override fun onResult(result: GetCredentialResponse) {
                    Log.d(TAG, "getCredential success: type=${result.credential.type}")
                    callback.onSuccess(result.credential.data.getString("androidx.credentials.BUNDLE_KEY_AUTHENTICATION_RESPONSE_JSON", "{}"))
                }

                override fun onError(e: GetCredentialException) {
                    Log.e(TAG, "getCredential error: type=${e.type} message=${e.message}")
                    callback.onError(e.type, e.message ?: "Unknown error")
                }
            }
        )
    }

    /**
     * Recursively find all WebView instances in a ViewGroup hierarchy.
     */
    private fun findWebViews(viewGroup: ViewGroup?): List<WebView> {
        if (viewGroup == null) return emptyList()
        val result = mutableListOf<WebView>()
        for (i in 0 until viewGroup.childCount) {
            val child = viewGroup.getChildAt(i)
            if (child is WebView) {
                result.add(child)
            } else if (child is ViewGroup) {
                result.addAll(findWebViews(child))
            }
        }
        return result
    }
}
