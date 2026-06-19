package org.codeberg.theoden8.webspace

/**
 * Host-only DNS blocklist for the sub-resource interceptor: holds the parsed
 * domain set and answers subdomain-aware membership.
 *
 * Extracted from [WebInterceptPlugin] so the parse + match logic is unit-
 * testable on the JVM (see DnsHostBlocklistTest).
 *
 * The set is built on a background thread (a full ~650k-entry build is ~1.2s on
 * ART and must not run on the Android main thread). Readers on WebView request
 * threads fail-closed via [awaitReady]: while a build is in flight they block
 * rather than evaluate against a stale/empty set, so a request can never slip
 * past the DNS blocklist during the build window. The set is swapped in
 * atomically (@Volatile) so a reader always sees a complete set.
 */
class DnsHostBlocklist {
    private val lock = Object()

    @Volatile
    private var domains: Set<String> = emptySet()

    // True between [beginBuild] and the [replaceFromBlob] that completes it.
    // Starts false: a site with no DNS blocklist never calls beginBuild, so its
    // request threads never wait.
    @Volatile
    private var building = false

    val size: Int get() = domains.size

    /**
     * Mark that a build is starting. Call on the requesting (main) thread,
     * synchronously, before handing the blob to a worker thread — so a request
     * thread that races in observes `building` and waits in [awaitReady].
     */
    fun beginBuild() {
        synchronized(lock) { building = true }
    }

    /**
     * Parse a newline-joined blob (one domain per line; blank lines ignored)
     * and swap it in, clearing the in-flight flag and waking [awaitReady]
     * waiters. Pre-sizes the HashSet to the line count so a ~650k-entry list
     * doesn't pay the ~20 rehashes a default-capacity set incurs while filling.
     */
    fun replaceFromBlob(blob: String) {
        val built = parse(blob)
        synchronized(lock) {
            domains = built
            building = false
            lock.notifyAll()
        }
    }

    /**
     * Fail-closed wait: block until no build is in flight, up to [timeoutMs].
     * Returns true once ready (the common case returns immediately — nothing is
     * building), false on timeout. The timeout is a safety valve so a wedged
     * build can't hang every request forever.
     */
    fun awaitReady(timeoutMs: Long): Boolean {
        if (!building) return true
        synchronized(lock) {
            val deadline = System.currentTimeMillis() + timeoutMs
            while (building) {
                val remaining = deadline - System.currentTimeMillis()
                if (remaining <= 0L) return false
                lock.wait(remaining)
            }
        }
        return true
    }

    /**
     * True if [host] — or a registrable parent domain of it — is in the set.
     * Walks subdomain -> parent (`a.b.example.com` -> `b.example.com` ->
     * `example.com`), stopping before the final eTLD label so a bare TLD like
     * `com` is never matched. `host.substring(dot + 1)` is the lookup key
     * directly; `HashSet.contains` accepts it without further allocation.
     */
    fun isBlocked(host: String): Boolean {
        val s = domains
        if (s.isEmpty()) return false
        if (s.contains(host)) return true
        var dot = host.indexOf('.')
        while (dot in 0 until host.length - 1) {
            val parent = host.substring(dot + 1)
            if (parent.indexOf('.') < 0) return false
            if (s.contains(parent)) return true
            dot = host.indexOf('.', dot + 1)
        }
        return false
    }

    private fun parse(blob: String): Set<String> {
        if (blob.isEmpty()) return emptySet()
        var lines = 1
        for (i in blob.indices) if (blob[i] == '\n') lines++
        val s = HashSet<String>(lines * 4 / 3 + 1)
        for (d in blob.splitToSequence('\n')) {
            if (d.isNotEmpty()) s.add(d)
        }
        return s
    }
}
