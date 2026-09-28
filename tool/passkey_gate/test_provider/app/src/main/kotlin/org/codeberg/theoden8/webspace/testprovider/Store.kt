package org.codeberg.theoden8.webspace.testprovider

import android.content.Context
import android.util.Log
import androidx.credentials.provider.CallingAppInfo
import org.json.JSONArray
import org.json.JSONObject

const val TAG = "TESTPROVIDER"

/** A stored passkey. The private key is PKCS#8; this is a test fixture, not a vault. */
data class StoredCredential(
    val id: String,
    val rpId: String,
    val userId: String,
    val userName: String,
    val pkcs8: String,
    val signCount: Int,
)

class Store(context: Context) {
    private val prefs = context.getSharedPreferences("passkeys", Context.MODE_PRIVATE)

    fun put(c: StoredCredential) {
        prefs.edit().putString("cred:${c.id}", JSONObject()
            .put("id", c.id).put("rpId", c.rpId).put("userId", c.userId)
            .put("userName", c.userName).put("pkcs8", c.pkcs8).put("signCount", c.signCount)
            .toString()).commit()
    }

    fun get(id: String): StoredCredential? = prefs.getString("cred:$id", null)?.let { parse(it) }

    fun forRp(rpId: String): List<StoredCredential> = prefs.all
        .filterKeys { it.startsWith("cred:") }
        .values.mapNotNull { (it as? String)?.let(::parse) }
        .filter { it.rpId == rpId }

    private fun parse(s: String): StoredCredential = JSONObject(s).run {
        StoredCredential(getString("id"), getString("rpId"), getString("userId"),
            getString("userName"), getString("pkcs8"), getInt("signCount"))
    }
}

/**
 * The privileged-browser allowlist, in the gstatic apps.json format that
 * [CallingAppInfo.getOrigin] parses. Empty until a TRUST broadcast names the
 * browser, which stands in for a provider's own "trust this browser" prompt.
 * Like Bitwarden's, that trust pins the certificate of the first request the
 * named package makes, unless the broadcast carried one.
 */
class Allowlist(context: Context) {
    private val prefs = context.getSharedPreferences("allowlist", Context.MODE_PRIVATE)

    fun trust(packageName: String, fingerprint: String?) {
        val fp = fingerprint?.replace(":", "")?.uppercase()?.chunked(2)?.joinToString(":")
        prefs.edit().clear().putString("package", packageName).putString("fp", fp).commit()
        Log.i(TAG, "allowlist trust package=$packageName fp=${fp ?: "pinned on first request"}")
    }

    private fun pinIfUnpinned(caller: CallingAppInfo) {
        if (prefs.getString("fp", null) != null) return
        if (prefs.getString("package", null) != caller.packageName) return
        val fp = fingerprintOf(caller)
        prefs.edit().putString("fp", fp).commit()
        Log.i(TAG, "allowlist pinned package=${caller.packageName} fp=$fp")
    }

    fun clear() {
        prefs.edit().clear().commit()
        Log.i(TAG, "allowlist cleared")
    }

    val json: String
        get() {
            val apps = JSONArray()
            val pkg = prefs.getString("package", null)
            val fp = prefs.getString("fp", null)
            if (pkg != null && fp != null) {
                apps.put(JSONObject().put("type", "android").put("info", JSONObject()
                    .put("package_name", pkg)
                    .put("signatures", JSONArray().put(JSONObject()
                        .put("build", "release").put("cert_fingerprint_sha256", fp)))))
            }
            return JSONObject().put("apps", apps).toString()
        }

    /**
     * The caller's asserted origin, or null when the caller is not trusted
     * with one. `getOrigin` throws for an unlisted caller and rejects an
     * allowlist with no apps at all, and both mean "not trusted" here.
     */
    fun originOf(caller: CallingAppInfo): String? = try {
        pinIfUnpinned(caller)
        caller.getOrigin(json)
    } catch (e: IllegalStateException) {
        null
    } catch (e: IllegalArgumentException) {
        null
    }
}

fun fingerprintOf(caller: CallingAppInfo): String = try {
    val cert = caller.signingInfo.signingCertificateHistory.first().toByteArray()
    WebAuthn.sha256(cert).joinToString(":") { "%02X".format(it) }
} catch (e: Exception) {
    "unknown"
}
