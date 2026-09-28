package org.codeberg.theoden8.webspace.testprovider

import android.app.Activity
import android.os.Bundle
import android.util.Log
import androidx.credentials.GetCredentialResponse
import androidx.credentials.GetPublicKeyCredentialOption
import androidx.credentials.PublicKeyCredential
import androidx.credentials.exceptions.GetCredentialUnknownException
import androidx.credentials.exceptions.domerrors.NotAllowedError
import androidx.credentials.exceptions.publickeycredential.GetPublicKeyCredentialDomException
import androidx.credentials.provider.PendingIntentHandler
import java.security.KeyFactory
import java.security.spec.PKCS8EncodedKeySpec

class GetPasskeyActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val out = intent
        try {
            val req = PendingIntentHandler.retrieveProviderGetCredentialRequest(intent)
                ?: error("no provider request")
            val option = req.credentialOptions.filterIsInstance<GetPublicKeyCredentialOption>().first()
            val caller = req.callingAppInfo
            val origin = Allowlist(this).originOf(caller)
            if (origin == null) {
                Log.i(TAG, "refuse get caller=${caller.packageName} fp=${fingerprintOf(caller)} " +
                    "originPopulated=${caller.isOriginPopulated()}")
                PendingIntentHandler.setGetCredentialException(out,
                    GetPublicKeyCredentialDomException(NotAllowedError(), "caller not trusted"))
            } else {
                val hash = option.clientDataHash ?: error("the browser sent no clientDataHash")
                check(hash.size == 32) { "clientDataHash is ${hash.size} bytes" }
                val store = Store(this)
                val stored = store.get(intent.getStringExtra("credId") ?: error("no credId"))
                    ?: error("unknown credential")
                val count = stored.signCount + 1
                store.put(stored.copy(signCount = count))
                val key = KeyFactory.getInstance("EC")
                    .generatePrivate(PKCS8EncodedKeySpec(WebAuthn.unb64u(stored.pkcs8)))
                Log.i(TAG, "get origin=$origin rpId=${stored.rpId} signCount=$count caller=${caller.packageName}")
                PendingIntentHandler.setGetCredentialResponse(out, GetCredentialResponse(PublicKeyCredential(
                    WebAuthn.assertionJson(stored.rpId, WebAuthn.unb64u(stored.id), key, hash,
                        WebAuthn.unb64u(stored.userId), count))))
            }
        } catch (e: Exception) {
            Log.e(TAG, "get failed: $e")
            PendingIntentHandler.setGetCredentialException(out, GetCredentialUnknownException(e.toString()))
        }
        setResult(RESULT_OK, out)
        finish()
    }
}
