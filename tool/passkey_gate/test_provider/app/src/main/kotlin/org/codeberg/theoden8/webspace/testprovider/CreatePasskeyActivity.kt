package org.codeberg.theoden8.webspace.testprovider

import android.app.Activity
import android.net.Uri
import android.os.Bundle
import android.util.Log
import androidx.credentials.CreatePublicKeyCredentialRequest
import androidx.credentials.CreatePublicKeyCredentialResponse
import androidx.credentials.exceptions.CreateCredentialUnknownException
import androidx.credentials.exceptions.domerrors.NotAllowedError
import androidx.credentials.exceptions.publickeycredential.CreatePublicKeyCredentialDomException
import androidx.credentials.provider.PendingIntentHandler
import java.security.SecureRandom
import java.security.interfaces.ECPublicKey
import org.json.JSONObject

class CreatePasskeyActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val out = intent
        try {
            val req = PendingIntentHandler.retrieveProviderCreateCredentialRequest(intent)
                ?: error("no provider request")
            val pk = req.callingRequest as? CreatePublicKeyCredentialRequest ?: error("not a passkey request")
            val caller = req.callingAppInfo
            val origin = Allowlist(this).originOf(caller)
            if (origin == null) {
                Log.i(TAG, "refuse create caller=${caller.packageName} fp=${fingerprintOf(caller)} " +
                    "originPopulated=${caller.isOriginPopulated()}")
                PendingIntentHandler.setCreateCredentialException(out,
                    CreatePublicKeyCredentialDomException(NotAllowedError(), "caller not trusted"))
            } else {
                val hash = pk.clientDataHash ?: error("the browser sent no clientDataHash")
                check(hash.size == 32) { "clientDataHash is ${hash.size} bytes" }
                val options = JSONObject(pk.requestJson)
                val user = options.getJSONObject("user")
                val rpId = options.getJSONObject("rp").optString("id").ifEmpty { Uri.parse(origin).host!! }
                val keys = WebAuthn.newKeyPair()
                val credId = ByteArray(32).also { SecureRandom().nextBytes(it) }
                Store(this).put(StoredCredential(
                    id = WebAuthn.b64u(credId), rpId = rpId, userId = user.getString("id"),
                    userName = user.getString("name"), pkcs8 = WebAuthn.b64u(keys.private.encoded),
                    signCount = 0))
                Log.i(TAG, "create origin=$origin rpId=$rpId caller=${caller.packageName}")
                PendingIntentHandler.setCreateCredentialResponse(out, CreatePublicKeyCredentialResponse(
                    WebAuthn.registrationJson(rpId, credId, keys.public as ECPublicKey)))
            }
        } catch (e: Exception) {
            Log.e(TAG, "create failed: $e")
            PendingIntentHandler.setCreateCredentialException(out, CreateCredentialUnknownException(e.toString()))
        }
        setResult(RESULT_OK, out)
        finish()
    }
}
