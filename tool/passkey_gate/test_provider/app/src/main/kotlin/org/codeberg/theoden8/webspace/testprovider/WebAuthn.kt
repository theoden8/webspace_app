package org.codeberg.theoden8.webspace.testprovider

import java.io.ByteArrayOutputStream
import java.math.BigInteger
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.Signature
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.util.Base64
import org.json.JSONArray
import org.json.JSONObject

/**
 * The authenticator side of an ES256 passkey, by hand: canonical CBOR,
 * `fmt: "none"` attestation, and a DER signature over
 * `authenticatorData || clientDataHash`.
 *
 * The browser supplies clientDataHash and splices its own clientDataJSON
 * into the response, so this never builds one; [PLACEHOLDER] marks the slot.
 */
object WebAuthn {
    val PLACEHOLDER: String = b64u("{}".toByteArray())

    fun b64u(b: ByteArray): String = Base64.getUrlEncoder().withoutPadding().encodeToString(b)
    fun unb64u(s: String): ByteArray = Base64.getUrlDecoder().decode(s)
    fun sha256(b: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(b)

    private class Cbor {
        val out = ByteArrayOutputStream()
        fun head(major: Int, arg: Long) {
            val m = major shl 5
            when {
                arg < 24 -> out.write(m or arg.toInt())
                arg < 0x100 -> { out.write(m or 24); out.write(arg.toInt()) }
                arg < 0x10000 -> { out.write(m or 25); out.write((arg shr 8).toInt()); out.write(arg.toInt()) }
                else -> { out.write(m or 26); for (s in intArrayOf(24, 16, 8, 0)) out.write((arg shr s).toInt()) }
            }
        }
        fun int(v: Long) = if (v >= 0) head(0, v) else head(1, -1 - v)
        fun bytes(b: ByteArray) { head(2, b.size.toLong()); out.write(b) }
        fun text(s: String) { val b = s.toByteArray(Charsets.UTF_8); head(3, b.size.toLong()); out.write(b) }
        fun map(n: Int) = head(5, n.toLong())
    }

    private fun fixed32(n: BigInteger): ByteArray {
        val b = n.toByteArray()
        val off = if (b.size > 32) b.size - 32 else 0
        return ByteArray(32).also { System.arraycopy(b, off, it, 32 - (b.size - off), b.size - off) }
    }

    private val P256_SPKI_PREFIX = Base64.getDecoder().decode("MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE")

    private fun counter(n: Int) = byteArrayOf((n ushr 24).toByte(), (n ushr 16).toByte(), (n ushr 8).toByte(), n.toByte())

    fun newKeyPair(): KeyPair = KeyPairGenerator.getInstance("EC")
        .apply { initialize(ECGenParameterSpec("secp256r1")) }.generateKeyPair()

    fun registrationJson(rpId: String, credId: ByteArray, pub: ECPublicKey): String {
        val x = fixed32(pub.w.affineX)
        val y = fixed32(pub.w.affineY)
        val cose = Cbor().apply {
            map(5)
            int(1); int(2)
            int(3); int(-7)
            int(-1); int(1)
            int(-2); bytes(x)
            int(-3); bytes(y)
        }.out.toByteArray()
        val flags = 0x01 or 0x04 or 0x40
        val authData = ByteArrayOutputStream().apply {
            write(sha256(rpId.toByteArray(Charsets.UTF_8)))
            write(flags)
            write(counter(0))
            write(ByteArray(16))
            write(credId.size shr 8); write(credId.size and 0xff)
            write(credId)
            write(cose)
        }.toByteArray()
        val attObj = Cbor().apply {
            map(3)
            text("fmt"); text("none")
            text("attStmt"); map(0)
            text("authData"); bytes(authData)
        }.out.toByteArray()
        val id = b64u(credId)
        return JSONObject()
            .put("id", id).put("rawId", id).put("type", "public-key")
            .put("authenticatorAttachment", "platform")
            .put("response", JSONObject()
                .put("clientDataJSON", PLACEHOLDER)
                .put("attestationObject", b64u(attObj))
                .put("authenticatorData", b64u(authData))
                .put("publicKey", b64u(P256_SPKI_PREFIX + x + y))
                .put("publicKeyAlgorithm", -7)
                .put("transports", JSONArray(listOf("internal", "hybrid"))))
            .put("clientExtensionResults", JSONObject().put("credProps", JSONObject().put("rk", true)))
            .toString()
    }

    fun assertionJson(
        rpId: String, credId: ByteArray, priv: PrivateKey, clientDataHash: ByteArray,
        userHandle: ByteArray, signCount: Int,
    ): String {
        val authData = sha256(rpId.toByteArray(Charsets.UTF_8)) +
            byteArrayOf((0x01 or 0x04).toByte()) + counter(signCount)
        val sig = Signature.getInstance("SHA256withECDSA").run {
            initSign(priv); update(authData + clientDataHash); sign()
        }
        val id = b64u(credId)
        return JSONObject()
            .put("id", id).put("rawId", id).put("type", "public-key")
            .put("authenticatorAttachment", "platform")
            .put("response", JSONObject()
                .put("clientDataJSON", PLACEHOLDER)
                .put("authenticatorData", b64u(authData))
                .put("signature", b64u(sig))
                .put("userHandle", b64u(userHandle)))
            .put("clientExtensionResults", JSONObject())
            .toString()
    }
}
