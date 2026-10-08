package org.codeberg.theoden8.webspace

/**
 * State that more than one thread touches, reachable only inside [with]
 * (BUG-007). Every read, write and eviction takes the same monitor, so the
 * half-lock that each BUG-007 instance shipped (a locked writer beside an
 * unlocked reader) cannot be written against this type.
 *
 * Keep the block to memory work and never return the state itself out of
 * it. A blocking call inside it stalls every chromium IO thread queued on the
 * monitor: read under the lock, compute outside, write back under it.
 */
class Guarded<T : Any>(private val state: T) {
    private val lock = Any()

    fun <R> with(block: T.() -> R): R = synchronized(lock) { state.block() }
}
