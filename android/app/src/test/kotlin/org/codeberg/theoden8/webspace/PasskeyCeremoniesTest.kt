// JVM unit tests for PasskeyCeremonies, the part of PasskeyPlugin that
// decides what a ceremony answers without Credential Manager behind it.
//
// Two of these stand in for device tiers that would each need another
// build or another emulator: a build without CREDENTIAL_MANAGER_SET_ORIGIN
// (the framework throws SecurityException synchronously from the binder
// call, PASSKEY-008) and an API 33 device (PASSKEY-002).
package org.codeberg.theoden8.webspace

import android.os.CancellationSignal
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.mockito.kotlin.mock
import org.mockito.kotlin.verify

class PasskeyCeremoniesTest {

    private class FakeGateway(
        private val onCall: (op: String, reply: (PasskeyOutcome) -> Unit) -> Unit,
    ) : PasskeyGateway {
        var calls = 0
        var lastOrigin: String? = null
        var lastHash: ByteArray? = null

        override fun create(requestJson: String, origin: String, clientDataHash: ByteArray,
                            signal: CancellationSignal, reply: (PasskeyOutcome) -> Unit) {
            calls++
            lastOrigin = origin
            lastHash = clientDataHash
            onCall("create", reply)
        }

        override fun get(requestJson: String, origin: String, clientDataHash: ByteArray,
                         signal: CancellationSignal, reply: (PasskeyOutcome) -> Unit) {
            calls++
            lastOrigin = origin
            lastHash = clientDataHash
            onCall("get", reply)
        }
    }

    private val hash = ByteArray(32) { it.toByte() }

    private fun ceremonies(gateway: PasskeyGateway, sdk: Int = 35,
                           signal: CancellationSignal = mock()) =
        PasskeyCeremonies(sdkInt = sdk, gateway = gateway, newSignal = { signal })

    @Test
    fun belowApi34ItRefusesWithoutCallingCredentialManager() {
        val gateway = FakeGateway { _, _ -> }
        val outcomes = mutableListOf<PasskeyOutcome>()
        ceremonies(gateway, sdk = 33).start("create", "k", "{}", "https://a.test", hash) { outcomes.add(it) }
        assertEquals(listOf(PasskeyOutcome.Failure("UNSUPPORTED")), outcomes)
        assertEquals(0, gateway.calls)
    }

    @Test
    fun aMissingOriginPermissionIsCaughtAndFreesTheSlot() {
        var throwOnce = true
        val gateway = FakeGateway { _, reply ->
            if (throwOnce) {
                throwOnce = false
                throw SecurityException("uid 10123 does not have android.permission.CREDENTIAL_MANAGER_SET_ORIGIN.")
            }
            reply(PasskeyOutcome.Success("{\"id\":\"x\"}"))
        }
        val c = ceremonies(gateway)
        val outcomes = mutableListOf<PasskeyOutcome>()
        c.start("create", "k1", "{}", "https://a.test", hash) { outcomes.add(it) }
        c.start("get", "k2", "{}", "https://a.test", hash) { outcomes.add(it) }
        assertEquals(PasskeyOutcome.Failure("SECURITY"), outcomes[0])
        assertEquals(PasskeyOutcome.Success("{\"id\":\"x\"}"), outcomes[1])
        assertFalse(c.busy)
    }

    @Test
    fun aRequestTheLibraryRejectsIsInvalid() {
        val gateway = FakeGateway { _, _ -> throw IllegalArgumentException("user.name must be defined in requestJson") }
        val outcomes = mutableListOf<PasskeyOutcome>()
        val c = ceremonies(gateway)
        c.start("create", "k", "{}", "https://a.test", hash) { outcomes.add(it) }
        assertEquals(listOf(PasskeyOutcome.Failure("INVALID_REQUEST")), outcomes)
        assertFalse(c.busy)
    }

    @Test
    fun oneCeremonyAtATime() {
        var pending: ((PasskeyOutcome) -> Unit)? = null
        val gateway = FakeGateway { _, reply -> pending = reply }
        val c = ceremonies(gateway)
        val first = mutableListOf<PasskeyOutcome>()
        val second = mutableListOf<PasskeyOutcome>()
        c.start("create", "tab1:1", "{}", "https://a.test", hash) { first.add(it) }
        c.start("get", "tab2:1", "{}", "https://b.test", hash) { second.add(it) }
        assertEquals(listOf(PasskeyOutcome.Failure("BUSY")), second)
        assertEquals(1, gateway.calls)
        assertEquals("https://a.test", gateway.lastOrigin)
        pending!!(PasskeyOutcome.Success("{}"))
        assertEquals(listOf(PasskeyOutcome.Success("{}")), first)
        assertFalse(c.busy)
    }

    @Test
    fun theOriginAndHashReachTheGatewayUnchanged() {
        val gateway = FakeGateway { _, reply -> reply(PasskeyOutcome.Success("{}")) }
        ceremonies(gateway).start("get", "k", "{}", "http://localhost:8443", hash) {}
        assertEquals("http://localhost:8443", gateway.lastOrigin)
        assertTrue(hash.contentEquals(gateway.lastHash))
    }

    @Test
    fun cancelAnswersOnceAndALateProviderReplyIsDropped() {
        var pending: ((PasskeyOutcome) -> Unit)? = null
        val gateway = FakeGateway { _, reply -> pending = reply }
        val signal: CancellationSignal = mock()
        val c = ceremonies(gateway, signal = signal)
        val outcomes = mutableListOf<PasskeyOutcome>()
        c.start("get", "k", "{}", "https://a.test", hash) { outcomes.add(it) }
        c.cancel("someone-else")
        assertTrue(c.busy)
        c.cancel("k")
        verify(signal).cancel()
        pending!!(PasskeyOutcome.Success("{}"))
        assertEquals(listOf(PasskeyOutcome.Failure("CANCELLED")), outcomes)
        assertFalse(c.busy)
    }

    @Test
    fun aGatewayThatAnswersTwiceIsHeardOnce() {
        val gateway = FakeGateway { _, reply ->
            reply(PasskeyOutcome.Failure("USER_CANCELED"))
            reply(PasskeyOutcome.Success("{}"))
        }
        val outcomes = mutableListOf<PasskeyOutcome>()
        ceremonies(gateway).start("create", "k", "{}", "https://a.test", hash) { outcomes.add(it) }
        assertEquals(listOf(PasskeyOutcome.Failure("USER_CANCELED")), outcomes)
    }
}
