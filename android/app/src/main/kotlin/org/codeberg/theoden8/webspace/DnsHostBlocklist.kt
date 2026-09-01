package org.codeberg.theoden8.webspace

/**
 * Host-only DNS blocklist for the sub-resource interceptor: holds the parsed
 * domains, partitioned by the severity level each one enters at, and answers
 * subdomain-aware membership at a given level.
 *
 * The partition is what lets sites run at different levels off one copy of the
 * blocklist: [tierOf] is level-independent and cacheable, and each site's
 * level is applied as a comparison against it.
 *
 * Extracted from [WebInterceptPlugin] so the parse + match logic is unit-
 * testable on the JVM (see DnsHostBlocklistTest).
 *
 * The sets are built on a background thread (a full ~650k-entry build is ~1.2s
 * on ART and must not run on the Android main thread). Readers on WebView
 * request threads fail-closed via [awaitReady]: while a build is in flight
 * they block rather than evaluate against a stale/empty set, so a request can
 * never slip past the DNS blocklist during the build window. The tiers are
 * swapped in atomically (@Volatile) so a reader always sees a complete set.
 */
class DnsHostBlocklist {
    private val lock = Object()

    /** Indexed by level; index 0 is unused. Tiers are disjoint. */
    @Volatile
    private var tiers: Array<Set<String>> = emptyTiers()

    // True between [beginBuild] and the [replaceFromBlob] that completes it.
    // Starts false: a site with no DNS blocklist never calls beginBuild, so its
    // request threads never wait.
    @Volatile
    private var building = false

    val size: Int get() = tiers.sumOf { it.size }

    /** Levels that carry at least one domain, ascending. */
    val levels: List<Int> get() = (1..MAX_LEVEL).filter { tiers[it].isNotEmpty() }

    /**
     * Mark that a build is starting. Call on the requesting (main) thread,
     * synchronously, before handing the blob to a worker thread — so a request
     * thread that races in observes `building` and waits in [awaitReady].
     */
    fun beginBuild() {
        synchronized(lock) { building = true }
    }

    /**
     * Parse a newline-joined blob and swap it in, clearing the in-flight flag
     * and waking [awaitReady] waiters.
     *
     * Format: a `#<level>` marker line introduces each tier, followed by that
     * tier's domains one per line. Lines before any marker are taken as level
     * 1 so an unmarked blob still loads.
     */
    fun replaceFromBlob(blob: String) {
        val built = parse(blob)
        synchronized(lock) {
            tiers = built
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
     * Lowest level whose list names [host] — or a registrable parent domain of
     * it — or 0 when none does. Walks subdomain -> parent
     * (`a.b.example.com` -> `b.example.com` -> `example.com`), stopping before
     * the final eTLD label so a bare TLD like `com` is never matched.
     * `host.substring(dot + 1)` is the lookup key directly; `HashSet.contains`
     * accepts it without further allocation.
     *
     * Ascending by level so the first hit is the answer, and so the common
     * single-tier case costs exactly what the flat set used to.
     */
    fun tierOf(host: String): Int {
        val t = tiers
        for (level in 1..MAX_LEVEL) {
            val s = t[level]
            if (s.isEmpty()) continue
            if (s.contains(host)) return level
            var dot = host.indexOf('.')
            while (dot in 0 until host.length - 1) {
                val parent = host.substring(dot + 1)
                if (parent.indexOf('.') < 0) break
                if (s.contains(parent)) return level
                dot = host.indexOf('.', dot + 1)
            }
        }
        return 0
    }

    /** Whether any downloaded level names [host]. */
    fun isBlocked(host: String): Boolean = tierOf(host) != 0

    /** Whether a site blocking at [level] blocks [host]. */
    fun isBlockedAt(host: String, level: Int): Boolean {
        if (level <= 0) return false
        val tier = tierOf(host)
        return tier != 0 && tier <= level
    }

    private fun parse(blob: String): Array<Set<String>> {
        if (blob.isEmpty()) return emptyTiers()
        // Two passes so each tier's HashSet is allocated at its final size:
        // one 650k-entry set filled from a default capacity pays ~20 rehashes,
        // and pre-sizing every tier to the whole blob would waste five times
        // the table for the single-tier case that is the norm.
        val counts = IntArray(MAX_LEVEL + 1)
        forEachEntry(blob) { level, _ -> counts[level]++ }
        val sets = Array(MAX_LEVEL + 1) { level ->
            HashSet<String>(if (counts[level] == 0) 0 else counts[level] * 4 / 3 + 1)
        }
        forEachEntry(blob) { level, domain -> sets[level].add(domain) }
        return Array<Set<String>>(MAX_LEVEL + 1) { sets[it] }
    }

    /**
     * Walk the blob's `#<level>` sections. Entries before any marker belong to
     * level 1 so an unmarked blob still loads.
     */
    private inline fun forEachEntry(blob: String, body: (Int, String) -> Unit) {
        var level = 1
        for (line in blob.splitToSequence('\n')) {
            if (line.isEmpty()) continue
            if (line[0] == '#') {
                val parsed = line.substring(1).trim().toIntOrNull()
                if (parsed != null && parsed in 1..MAX_LEVEL) level = parsed
                continue
            }
            body(level, line)
        }
    }

    companion object {
        const val MAX_LEVEL = 5

        private fun emptyTiers(): Array<Set<String>> =
            Array<Set<String>>(MAX_LEVEL + 1) { emptySet() }
    }
}
