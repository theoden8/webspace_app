package org.codeberg.theoden8.webspace.testprovider

import android.app.PendingIntent
import android.content.Intent
import android.os.CancellationSignal
import android.os.OutcomeReceiver
import android.util.Log
import androidx.credentials.exceptions.ClearCredentialException
import androidx.credentials.exceptions.CreateCredentialException
import androidx.credentials.exceptions.CreateCredentialUnsupportedException
import androidx.credentials.exceptions.GetCredentialException
import androidx.credentials.provider.BeginCreateCredentialRequest
import androidx.credentials.provider.BeginCreateCredentialResponse
import androidx.credentials.provider.BeginCreatePublicKeyCredentialRequest
import androidx.credentials.provider.BeginGetCredentialRequest
import androidx.credentials.provider.BeginGetCredentialResponse
import androidx.credentials.provider.BeginGetPublicKeyCredentialOption
import androidx.credentials.provider.CreateEntry
import androidx.credentials.provider.CredentialProviderService
import androidx.credentials.provider.ProviderClearCredentialStateRequest
import androidx.credentials.provider.PublicKeyCredentialEntry
import org.json.JSONObject

/**
 * Offers one "save" entry for every passkey creation and one entry per stored
 * passkey for the requested rpId. The allowlist check happens in the final
 * activities, where the calling app is always known; a real provider decides
 * there too, since that is where it can show its own prompt.
 *
 * The system gives these callbacks three seconds including the bind, so they
 * only read preferences.
 */
class TestProviderService : CredentialProviderService() {
    override fun onBeginCreateCredentialRequest(
        request: BeginCreateCredentialRequest,
        cancellationSignal: CancellationSignal,
        callback: OutcomeReceiver<BeginCreateCredentialResponse, CreateCredentialException>,
    ) {
        if (request !is BeginCreatePublicKeyCredentialRequest) {
            callback.onError(CreateCredentialUnsupportedException())
            return
        }
        val pi = PendingIntent.getActivity(this, 1, Intent(this, CreatePasskeyActivity::class.java),
            PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        Log.i(TAG, "begin create caller=${request.callingAppInfo?.packageName}")
        callback.onResult(BeginCreateCredentialResponse.Builder()
            .addCreateEntry(CreateEntry.Builder("webspace-test", pi).setAutoSelectAllowed(true).build())
            .build())
    }

    override fun onBeginGetCredentialRequest(
        request: BeginGetCredentialRequest,
        cancellationSignal: CancellationSignal,
        callback: OutcomeReceiver<BeginGetCredentialResponse, GetCredentialException>,
    ) {
        val response = BeginGetCredentialResponse.Builder()
        var code = 100
        for (option in request.beginGetCredentialOptions.filterIsInstance<BeginGetPublicKeyCredentialOption>()) {
            val options = JSONObject(option.requestJson)
            val rpId = options.optString("rpId")
            // An RP that names its credentials gets only those, as from any
            // provider; offering the rest would put a chooser in front of it.
            val allowed = options.optJSONArray("allowCredentials")
                ?.let { list -> (0 until list.length()).map { list.getJSONObject(it).getString("id") }.toSet() }
                ?.takeIf { it.isNotEmpty() }
            for (c in Store(this).forRp(rpId).filter { allowed == null || it.id in allowed }) {
                val pi = PendingIntent.getActivity(this, code++,
                    Intent(this, GetPasskeyActivity::class.java).putExtra("credId", c.id),
                    PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
                response.addCredentialEntry(PublicKeyCredentialEntry.Builder(this, c.userName, pi, option)
                    .setAutoSelectAllowed(true).build())
            }
            Log.i(TAG, "begin get rpId=$rpId entries=${code - 100} caller=${request.callingAppInfo?.packageName}")
        }
        callback.onResult(response.build())
    }

    override fun onClearCredentialStateRequest(
        request: ProviderClearCredentialStateRequest,
        cancellationSignal: CancellationSignal,
        callback: OutcomeReceiver<Void?, ClearCredentialException>,
    ) = callback.onResult(null)
}
