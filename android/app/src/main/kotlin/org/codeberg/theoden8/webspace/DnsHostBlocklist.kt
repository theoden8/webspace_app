package org.codeberg.theoden8.webspace

/**
 * Host-only DNS blocklist for the sub-resource interceptor: holds the parsed
 * domain set and answers subdomain-aware membership.
 *
 * Extracted from [WebInterceptPlugin] so the parse + match logic is unit-
 * testable on the JVM (see DnsHostBlocklistTest), and so the set is swapped
 * atomically — the previous in-place `clear()` + `addAll()` mutated the live
 * set while interceptors read it from request threads, a latent race.
 */
class DnsHostBlocklist {
    // Swapped wholesale on replace; @Volatile so a request thread always sees a
    // complete set, never one mid-rebuild.
    @Volatile
    private var domains: Set<String> = emptySet()

    val size: Int get() = domains.size

    /**
     * Replace the blocklist from a newline-joined blob (one domain per line;
     * blank lines ignored). Pre-sizes the HashSet to the line count so a full
     * ~650k-entry list doesn't pay the ~20 rehashes a default-capacity set
     * incurs while filling — that rehashing was a chunk of the cold-start
     * `setDnsBlockedDomains` cost.
     */
    fun replaceFromBlob(blob: String) {
        if (blob.isEmpty()) {
            domains = emptySet()
            return
        }
        var lines = 1
        for (i in blob.indices) if (blob[i] == '\n') lines++
        val s = HashSet<String>(lines * 4 / 3 + 1)
        for (d in blob.splitToSequence('\n')) {
            if (d.isNotEmpty()) s.add(d)
        }
        domains = s
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
}
