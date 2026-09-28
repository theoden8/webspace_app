package org.codeberg.theoden8.webspace

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.os.Build
import android.os.CancellationSignal
import android.view.View
import android.view.ViewGroup
import android.webkit.WebView
import androidx.core.content.ContextCompat
import androidx.credentials.CreateCredentialResponse
import androidx.credentials.CreatePublicKeyCredentialRequest
import androidx.credentials.CreatePublicKeyCredentialResponse
import androidx.credentials.CredentialManager
import androidx.credentials.CredentialManagerCallback
import androidx.credentials.GetCredentialRequest
import androidx.credentials.GetCredentialResponse
import androidx.credentials.GetPublicKeyCredentialOption
import androidx.credentials.PublicKeyCredential
import androidx.credentials.exceptions.CreateCredentialCancellationException
import androidx.credentials.exceptions.CreateCredentialException
import androidx.credentials.exceptions.CreateCredentialInterruptedException
import androidx.credentials.exceptions.CreateCredentialNoCreateOptionException
import androidx.credentials.exceptions.CreateCredentialProviderConfigurationException
import androidx.credentials.exceptions.CreateCredentialUnsupportedException
import androidx.credentials.exceptions.GetCredentialCancellationException
import androidx.credentials.exceptions.GetCredentialException
import androidx.credentials.exceptions.GetCredentialInterruptedException
import androidx.credentials.exceptions.GetCredentialProviderConfigurationException
import androidx.credentials.exceptions.GetCredentialUnsupportedException
import androidx.credentials.exceptions.NoCredentialException
import androidx.credentials.exceptions.domerrors.AbortError
import androidx.credentials.exceptions.domerrors.DomError
import androidx.credentials.exceptions.domerrors.InvalidStateError
import androidx.credentials.exceptions.domerrors.NotAllowedError
import androidx.credentials.exceptions.domerrors.NotSupportedError
import androidx.credentials.exceptions.domerrors.SecurityError
import androidx.credentials.exceptions.publickeycredential.CreatePublicKeyCredentialDomException
import androidx.credentials.exceptions.publickeycredential.GetPublicKeyCredentialDomException
import androidx.webkit.WebSettingsCompat
import androidx.webkit.WebViewFeature
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Passkeys for pages, the way a browser offers them (passkey-support).
 *
 * Dart has already decided the request may go out and built it: the origin
 * is the calling document's, the rpId belongs to it, and clientDataHash is
 * the SHA-256 of the clientDataJSON Dart will hand the page. This side only
 * asks Credential Manager with that origin, which the manifest's
 * CREDENTIAL_MANAGER_SET_ORIGIN (a normal permission) allows, and returns
 * the provider's JSON. No origin, rpId or request body is logged: logcat is
 * outside the app's log tiers.
 */
class PasskeyPlugin(private val activity: Activity, flutterEngine: FlutterEngine) {
    companion object {
        private const val CHANNEL = "org.codeberg.theoden8.webspace/passkey"
        private const val FEATURE_CREDENTIALS = "android.software.credentials"
    }

    private val ceremonies = PasskeyCeremonies(
        sdkInt = Build.VERSION.SDK_INT,
        gateway = AndroidxPasskeyGateway(activity),
        newSignal = { CancellationSignal() },
    )

    init {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "status" -> result.success(status())
                "create", "get" -> {
                    val key = call.argument<String>("key")
                    val requestJson = call.argument<String>("requestJson")
                    val origin = call.argument<String>("origin")
                    val hash = call.argument<ByteArray>("clientDataHash")
                    if (key == null || requestJson == null || origin == null || hash == null) {
                        result.error("INVALID_REQUEST", null, null)
                        return@setMethodCallHandler
                    }
                    ceremonies.start(call.method, key, requestJson, origin, hash) { outcome ->
                        when (outcome) {
                            is PasskeyOutcome.Success -> result.success(outcome.json)
                            is PasskeyOutcome.Failure -> result.error(outcome.code, null, null)
                        }
                    }
                }
                "cancel" -> {
                    call.argument<String>("key")?.let { ceremonies.cancel(it) }
                    result.success(null)
                }
                "setWebViewSupport" -> result.success(setWebViewSupport(call.argument<String>("mode")))
                else -> result.notImplemented()
            }
        }
    }

    private fun status(): Map<String, Any> {
        val sdk = Build.VERSION.SDK_INT
        val feature = sdk >= 34 && activity.packageManager.hasSystemFeature(FEATURE_CREDENTIALS)
        val permission = ContextCompat.checkSelfPermission(
            activity, Manifest.permission.CREDENTIAL_MANAGER_SET_ORIGIN,
        ) == PackageManager.PERMISSION_GRANTED
        return mapOf(
            "sdk" to sdk,
            "feature" to feature,
            "permission" to permission,
            "available" to (sdk >= 34 && feature && permission),
            "webViewSupport" to WebViewFeature.isFeatureSupported(WebViewFeature.WEB_AUTHENTICATION),
        )
    }

    /**
     * The WebView's own WebAuthn, for comparison with the bridge: "browser"
     * has the engine assert the page origin itself, "none" restores the
     * default. Applied to every WebView on screen, and read back so the
     * caller sees what the engine kept.
     */
    private fun setWebViewSupport(mode: String?): Map<String, Any> {
        if (!WebViewFeature.isFeatureSupported(WebViewFeature.WEB_AUTHENTICATION)) {
            return mapOf("supported" to false, "applied" to 0)
        }
        val value = when (mode) {
            "browser" -> WebSettingsCompat.WEB_AUTHENTICATION_SUPPORT_FOR_BROWSER
            "app" -> WebSettingsCompat.WEB_AUTHENTICATION_SUPPORT_FOR_APP
            else -> WebSettingsCompat.WEB_AUTHENTICATION_SUPPORT_NONE
        }
        val webViews = mutableListOf<WebView>()
        collectWebViews(activity.window.decorView, webViews)
        val kept = mutableListOf<Int>()
        for (wv in webViews) {
            WebSettingsCompat.setWebAuthenticationSupport(wv.settings, value)
            kept.add(WebSettingsCompat.getWebAuthenticationSupport(wv.settings))
        }
        return mapOf("supported" to true, "applied" to webViews.size, "kept" to kept)
    }

    private fun collectWebViews(view: View, out: MutableList<WebView>) {
        if (view is WebView) {
            out.add(view)
            return
        }
        if (view is ViewGroup) {
            for (i in 0 until view.childCount) collectWebViews(view.getChildAt(i), out)
        }
    }
}

sealed class PasskeyOutcome {
    data class Success(val json: String) : PasskeyOutcome()
    data class Failure(val code: String) : PasskeyOutcome()
}

/** The Credential Manager calls, behind a seam so the ceremony logic is JVM-testable. */
interface PasskeyGateway {
    fun create(requestJson: String, origin: String, clientDataHash: ByteArray,
               signal: CancellationSignal, reply: (PasskeyOutcome) -> Unit)

    fun get(requestJson: String, origin: String, clientDataHash: ByteArray,
            signal: CancellationSignal, reply: (PasskeyOutcome) -> Unit)
}

/**
 * One ceremony at a time, answered exactly once.
 *
 * Main looper only (BUG-007: single owner): the method channel handler runs
 * there, and the gateway's callbacks arrive on the main executor.
 */
class PasskeyCeremonies(
    private val sdkInt: Int,
    private val gateway: PasskeyGateway,
    private val newSignal: () -> CancellationSignal,
) {
    private class Active(val key: String, val signal: CancellationSignal, val reply: (PasskeyOutcome) -> Unit)

    private var active: Active? = null

    fun start(op: String, key: String, requestJson: String, origin: String, clientDataHash: ByteArray,
              reply: (PasskeyOutcome) -> Unit) {
        // setOrigin is API 34, and without Play Services there is no provider
        // below it, so the request would only fail later and less clearly.
        if (sdkInt < 34) {
            reply(PasskeyOutcome.Failure("UNSUPPORTED"))
            return
        }
        if (active != null) {
            reply(PasskeyOutcome.Failure("BUSY"))
            return
        }
        var replied = false
        val once: (PasskeyOutcome) -> Unit = { outcome ->
            if (!replied) {
                replied = true
                if (active?.key == key) active = null
                reply(outcome)
            }
        }
        val signal = newSignal()
        active = Active(key, signal, once)
        try {
            when (op) {
                "create" -> gateway.create(requestJson, origin, clientDataHash, signal, once)
                else -> gateway.get(requestJson, origin, clientDataHash, signal, once)
            }
        } catch (e: SecurityException) {
            // The framework enforces CREDENTIAL_MANAGER_SET_ORIGIN synchronously
            // in the binder call, so a build without the permission lands here
            // rather than in the callback.
            once(PasskeyOutcome.Failure("SECURITY"))
        } catch (e: IllegalArgumentException) {
            once(PasskeyOutcome.Failure("INVALID_REQUEST"))
        }
    }

    /** A signal the page aborted; the gateway may never call back after it. */
    fun cancel(key: String) {
        val current = active ?: return
        if (current.key != key) return
        current.signal.cancel()
        current.reply(PasskeyOutcome.Failure("CANCELLED"))
    }

    val busy: Boolean get() = active != null
}

class AndroidxPasskeyGateway(private val activity: Activity) : PasskeyGateway {
    private val manager by lazy { CredentialManager.create(activity) }
    private val executor by lazy { ContextCompat.getMainExecutor(activity) }

    override fun create(requestJson: String, origin: String, clientDataHash: ByteArray,
                        signal: CancellationSignal, reply: (PasskeyOutcome) -> Unit) {
        val request = CreatePublicKeyCredentialRequest(
            requestJson = requestJson,
            clientDataHash = clientDataHash,
            preferImmediatelyAvailableCredentials = false,
            origin = origin,
            isAutoSelectAllowed = false,
        )
        manager.createCredentialAsync(activity, request, signal, executor,
            object : CredentialManagerCallback<CreateCredentialResponse, CreateCredentialException> {
                override fun onResult(result: CreateCredentialResponse) {
                    reply(if (result is CreatePublicKeyCredentialResponse) {
                        PasskeyOutcome.Success(result.registrationResponseJson)
                    } else {
                        PasskeyOutcome.Failure("UNREADABLE")
                    })
                }

                override fun onError(e: CreateCredentialException) {
                    reply(PasskeyOutcome.Failure(createCode(e)))
                }
            })
    }

    override fun get(requestJson: String, origin: String, clientDataHash: ByteArray,
                     signal: CancellationSignal, reply: (PasskeyOutcome) -> Unit) {
        val request = GetCredentialRequest.Builder()
            .addCredentialOption(GetPublicKeyCredentialOption(requestJson, clientDataHash))
            .setOrigin(origin)
            .build()
        manager.getCredentialAsync(activity, request, signal, executor,
            object : CredentialManagerCallback<GetCredentialResponse, GetCredentialException> {
                override fun onResult(result: GetCredentialResponse) {
                    val credential = result.credential
                    reply(if (credential is PublicKeyCredential) {
                        PasskeyOutcome.Success(credential.authenticationResponseJson)
                    } else {
                        PasskeyOutcome.Failure("UNREADABLE")
                    })
                }

                override fun onError(e: GetCredentialException) {
                    reply(PasskeyOutcome.Failure(getCode(e)))
                }
            })
    }
}

// Stable codes for Dart. The exceptions' `type` strings are library-restricted
// API, and class names do not survive shrinking, so match on the classes.
internal fun createCode(e: CreateCredentialException): String = when (e) {
    is CreateCredentialCancellationException -> "USER_CANCELED"
    is CreateCredentialNoCreateOptionException -> "NO_CREATE_OPTIONS"
    is CreateCredentialInterruptedException -> "INTERRUPTED"
    is CreateCredentialProviderConfigurationException -> "UNSUPPORTED"
    is CreateCredentialUnsupportedException -> "UNSUPPORTED"
    is CreatePublicKeyCredentialDomException -> domCode(e.domError)
    else -> "UNKNOWN"
}

internal fun getCode(e: GetCredentialException): String = when (e) {
    is GetCredentialCancellationException -> "USER_CANCELED"
    is NoCredentialException -> "NO_CREDENTIAL"
    is GetCredentialInterruptedException -> "INTERRUPTED"
    is GetCredentialProviderConfigurationException -> "UNSUPPORTED"
    is GetCredentialUnsupportedException -> "UNSUPPORTED"
    is GetPublicKeyCredentialDomException -> domCode(e.domError)
    else -> "UNKNOWN"
}

internal fun domCode(dom: DomError): String = when (dom) {
    is InvalidStateError -> "DOM_INVALID_STATE"
    is NotAllowedError -> "DOM_NOT_ALLOWED"
    is AbortError -> "DOM_ABORT"
    is SecurityError -> "DOM_SECURITY"
    is NotSupportedError -> "DOM_NOT_SUPPORTED"
    else -> "DOM_OTHER"
}
