package org.codeberg.theoden8.webspace

/**
 * Host-only DNS blocklist for the sub-resource interceptor: holds the parsed
 * domains, grouped by which severity levels name them, and answers
 * subdomain-aware membership at a given level.
 *
 * The obvious compression — one "lowest level that names it" per domain,
 * blocking whenever that level is at or below the site's — assumes the levels
 * nest. They do not: 21,921 of the 297,756 domains across Hagezi's five lists
 * drop out of a higher level. The mask is the exact model instead, so a site
 * at level N blocks a domain iff level N's own list names it.
 *
 * Groups are disjoint, so the entry count across all of them is exactly the
 * union of the downloaded lists — what a flat set of that union would cost —
 * and there is one group while a single level is downloaded, which is where
 * an install that never sets a per-site level stays.
 *
 * Extracted from [WebInterceptPlugin] so the parse + match logic is unit-
 * testable on the JVM (see DnsHostBlocklistTest).
 *
 * The groups are built on a background thread (a full ~300k-entry build must
 * not run on the Android main thread). Readers on WebView request threads
 * fail-closed via [awaitReady]: while a build is in flight they block rather
 * than evaluate against a stale/empty set, so a request can never slip past
 * the DNS blocklist during the build window. The groups are swapped in
 * atomically (@Volatile) so a reader always sees a complete set.
 */
class DnsHostBlocklist {
    private val lock = Object()

    /** Level-membership mask -> the domains carrying exactly that mask. */
    @Volatile
    private var groups: Map<Int, Set<String>> = emptyMap()

    // True between [beginBuild] and the [replaceFromBlob] that completes it.
    // Starts false: a site with no DNS blocklist never calls beginBuild, so its
    // request threads never wait.
    @Volatile
    private var building = false

    val size: Int get() = groups.values.sumOf { it.size }

    /** How many disjoint groups the downloaded levels resolve to. */
    val groupCount: Int get() = groups.size

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
     * Format: a `#<mask-hex>` marker line introduces each group, followed by
     * that group's domains one per line. Lines before any marker are taken as
     * level 1 so an unmarked blob still loads.
     */
    fun replaceFromBlob(blob: String) {
        val built = parse(blob)
        synchronized(lock) {
            groups = built
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
     * Which levels name [host] — or a registrable parent domain of it — as a
     * mask; 0 when none does. Walks subdomain -> parent
     * (`a.b.example.com` -> `b.example.com` -> `example.com`), stopping before
     * the final eTLD label so a bare TLD like `com` is never matched.
     * `host.substring(dot + 1)` is the lookup key directly; `HashSet.contains`
     * accepts it without further allocation.
     *
     * One number per host answers every level, so the interceptor caches this
     * once and bit-tests it against whatever level its site runs at.
     */
    fun maskOf(host: String): Int {
        var mask = 0
        for ((groupMask, domains) in groups) {
            if (mask and groupMask == groupMask) continue
            if (contains(host, domains)) mask = mask or groupMask
        }
        return mask
    }

    private fun contains(host: String, domains: Set<String>): Boolean {
        if (domains.contains(host)) return true
        var dot = host.indexOf('.')
        while (dot in 0 until host.length - 1) {
            val parent = host.substring(dot + 1)
            if (parent.indexOf('.') < 0) return false
            if (domains.contains(parent)) return true
            dot = host.indexOf('.', dot + 1)
        }
        return false
    }

    /** Whether any downloaded level names [host]. */
    fun isBlocked(host: String): Boolean = maskOf(host) != 0

    /** Whether a site blocking at [level] blocks [host]. */
    fun isBlockedAt(host: String, level: Int): Boolean {
        if (level <= 0 || level > MAX_LEVEL) return false
        return maskOf(host) and levelBit(level) != 0
    }

    private fun parse(blob: String): Map<Int, Set<String>> {
        if (blob.isEmpty()) return emptyMap()
        // Two passes so each group's HashSet is allocated at its final size:
        // one 300k-entry set filled from a default capacity pays ~20 rehashes,
        // and pre-sizing every group to the whole blob would waste a table per
        // group for the single-group case that is the norm.
        val counts = HashMap<Int, Int>()
        forEachEntry(blob) { mask, _ -> counts[mask] = (counts[mask] ?: 0) + 1 }
        val built = HashMap<Int, HashSet<String>>(counts.size * 2)
        for ((mask, n) in counts) {
            built[mask] = HashSet(n * 4 / 3 + 1)
        }
        forEachEntry(blob) { mask, domain -> built[mask]?.add(domain) }
        return built
    }

    /**
     * Walk the blob's `#<mask-hex>` sections. Entries before any marker belong
     * to level 1 so an unmarked blob still loads.
     */
    private inline fun forEachEntry(blob: String, body: (Int, String) -> Unit) {
        var mask = levelBit(1)
        for (line in blob.splitToSequence('\n')) {
            if (line.isEmpty()) continue
            if (line[0] == '#') {
                val parsed = line.substring(1).trim().toIntOrNull(16)
                if (parsed != null && parsed in 1..ALL_LEVELS) mask = parsed
                continue
            }
            body(mask, line)
        }
    }

    companion object {
        const val MAX_LEVEL = 5
        const val ALL_LEVELS = (1 shl MAX_LEVEL) - 1

        fun levelBit(level: Int): Int = 1 shl (level - 1)
    }
}
