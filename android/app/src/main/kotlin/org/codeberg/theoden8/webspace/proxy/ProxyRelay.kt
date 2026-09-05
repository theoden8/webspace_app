package org.codeberg.theoden8.webspace.proxy

import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.URI
import java.util.concurrent.Executors
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory

/**
 * A loopback HTTP proxy that fronts an authenticated upstream proxy.
 *
 * Android's `ProxyController` has no proxy-authentication primitive: a
 * proxy rule with embedded `user:pass@` userinfo is rejected by Chromium
 * and the WebView silently falls back to a direct connection (the user's
 * real IP). This relay is the standard workaround — WebView points at
 * `127.0.0.1:<ephemeral>` with *no* credentials, and the relay injects the
 * upstream credentials itself (HTTP `Proxy-Authorization` or the SOCKS5
 * username/password handshake, RFC 1929).
 *
 * Fail-closed by construction: the relay only ever connects to the
 * upstream configured for that connection, and for an HTTPS upstream only
 * past a handshake that verified that upstream's certificate identity
 * (see [startTls]). If the upstream is unreachable, untrusted, or rejects
 * auth, the client gets a `502` and the connection closes. There is no
 * fallback path of any kind, so a failed proxy cannot leak the IP — not
 * even in router mode, where a *different* connection may legitimately be
 * routed [UpstreamType.DIRECT] because its own site has no proxy set.
 *
 * In router mode it additionally fronts every site at once, selecting the
 * upstream from the `Proxy-Authorization` credential the WebView presents
 * (see [startRouter]).
 *
 * Deliberately free of `android.*` imports so it runs under plain JVM
 * JUnit (no Robolectric). The lifecycle wrapper / method channel lives in
 * [ProxyRelayPlugin].
 */
class ProxyRelay(private val logger: ((String) -> Unit)? = null) {

    /**
     * DIRECT exists only for router mode. With `ProxyController` pointed
     * at the relay, EVERY site's traffic arrives here, including a site
     * the user left on the system default -- that site has to reach its
     * origin unproxied. It is reachable only through a route the app
     * configured as DIRECT and is never a fallback: a site whose proxy is
     * unreachable still gets a 502, so a failing proxy can no more leak
     * the device IP than it could before router mode existed.
     */
    enum class UpstreamType { HTTP, HTTPS, SOCKS5, DIRECT }

    data class UpstreamConfig(
        val type: UpstreamType,
        val host: String,
        val port: Int,
        val username: String?,
        val password: String?,
    ) {
        val hasCredentials: Boolean
            get() = !username.isNullOrEmpty() && !password.isNullOrEmpty()
    }

    /** One site's upstream, as reached through its credential. */
    data class Route(val siteId: String, val upstream: UpstreamConfig)

    @Volatile
    private var serverSocket: ServerSocket? = null
    @Volatile
    private var config: UpstreamConfig? = null
    // Router mode. `routerRealm` non-null selects it; `routes` maps the
    // base64 credential a WebView presents to the upstream it may reach.
    // Both are replaced wholesale under the class monitor and read as a
    // single volatile snapshot, never mutated in place, so an accept-thread
    // reader can never observe a half-applied route table (BUG-007).
    @Volatile
    private var routerRealm: String? = null
    @Volatile
    private var routes: Map<String, Route> = emptyMap()
    // Probe observations: nonce -> siteId whose credential carried it.
    // Replaced wholesale like `routes` so an accept-thread writer and a
    // channel-thread reader never see a torn map (BUG-007).
    @Volatile
    private var probes: Map<String, String> = emptyMap()
    @Volatile
    private var boundPort: Int = -1
    private var acceptThread: Thread? = null

    private val pool = Executors.newCachedThreadPool { r ->
        Thread(r, "proxy-relay-worker").apply { isDaemon = true }
    }

    val port: Int
        get() = boundPort

    @Synchronized
    fun isRunning(): Boolean = serverSocket?.isClosed == false

    /**
     * Start (or reconfigure) the relay. Returns the loopback port the
     * caller should hand to `ProxyController`. Binds a fresh ephemeral
     * port on every (re)start; the port is never persisted.
     *
     * Idempotent for an unchanged config: returns the existing port
     * without rebinding.
     */
    @Synchronized
    fun start(cfg: UpstreamConfig): Int {
        if (isRunning() && cfg == config && routerRealm == null) {
            return boundPort
        }
        stop()
        val socket = bindLoopback()
        serverSocket = socket
        config = cfg
        boundPort = socket.localPort
        startAcceptLoop(socket)
        log("started on 127.0.0.1:$boundPort (upstream type=${cfg.type})")
        return boundPort
    }

    /**
     * Start (or reconfigure) the relay in router mode, fronting every
     * site's upstream at once. Returns the loopback port.
     *
     * Every connection MUST present a `Proxy-Authorization` credential
     * that [setRoutes] maps to an upstream: a connection without one gets
     * a 407 naming [realm], and one bearing an unknown credential gets a
     * 502. Nothing is ever routed without a match and there is no default
     * upstream, so another app on the device cannot borrow the user's
     * proxy by connecting to this port. That matters because Android
     * shares the loopback interface across every installed app and offers
     * no way to identify the peer of a local TCP connection, making this
     * credential the only admission control the socket can have.
     */
    @Synchronized
    fun startRouter(realm: String): Int {
        require(realm.isNotEmpty() && realm.all { it in REALM_ALPHABET }) {
            "realm must be a non-empty hex nonce"
        }
        if (isRunning() && routerRealm == realm) {
            return boundPort
        }
        stop()
        val socket = bindLoopback()
        serverSocket = socket
        routerRealm = realm
        boundPort = socket.localPort
        startAcceptLoop(socket)
        log("started on 127.0.0.1:$boundPort (router mode)")
        return boundPort
    }

    /**
     * Replace the route table. Keys are the base64 `user:pass` credential
     * a WebView presents; the relay never decodes them, so a token is only
     * ever compared, never parsed or logged.
     */
    @Synchronized
    fun setRoutes(newRoutes: Map<String, Route>) {
        routes = java.util.Collections.unmodifiableMap(LinkedHashMap(newRoutes))
        log("routes updated (${routes.size} site(s): ${routes.values.map { it.siteId }})")
    }

    @Synchronized
    private fun recordProbe(nonce: String, siteId: String) {
        probes = java.util.Collections.unmodifiableMap(LinkedHashMap(probes).apply {
            put(nonce, siteId)
        })
    }

    /** Probe pairs observed so far: nonce -> the siteId that presented it. */
    @Synchronized
    fun probeObservations(): Map<String, String> = probes

    @Synchronized
    fun clearProbeObservations() {
        probes = emptyMap()
    }

    private fun bindLoopback(): ServerSocket {
        val socket = ServerSocket()
        socket.reuseAddress = true
        // Pin to IPv4 loopback (127.0.0.1) explicitly. InetAddress
        // .getLoopbackAddress() can return ::1 on dual-stack JVMs, which
        // is unreachable from the http://127.0.0.1:<port> rule we hand to
        // ProxyController — Chromium gets ERR_PROXY_CONNECTION_FAILED
        // without ever opening a TCP connection to our listener.
        val bindAddr = InetAddress.getByName("127.0.0.1")
        socket.bind(InetSocketAddress(bindAddr, 0), BACKLOG)
        return socket
    }

    private fun startAcceptLoop(socket: ServerSocket) {
        val t = Thread({ acceptLoop(socket) }, "proxy-relay-accept").apply { isDaemon = true }
        acceptThread = t
        t.start()
    }

    @Synchronized
    fun stop() {
        serverSocket?.let { runCatching { it.close() } }
        serverSocket = null
        config = null
        routerRealm = null
        routes = emptyMap()
        probes = emptyMap()
        boundPort = -1
        acceptThread = null
    }

    private fun acceptLoop(socket: ServerSocket) {
        while (!socket.isClosed) {
            val client = try {
                socket.accept()
            } catch (e: Exception) {
                // socket.close() from stop() throws SocketException here
                // and we exit cleanly. Any other exception is worth seeing.
                if (!socket.isClosed) {
                    log("accept loop ended with ${e.javaClass.simpleName}: ${e.message}")
                }
                break
            }
            if (config == null && routerRealm == null) {
                runCatching { client.close() }
                continue
            }
            log("accepted connection from ${client.inetAddress.hostAddress}:${client.port}")
            pool.execute {
                try {
                    handle(client)
                } catch (e: Exception) {
                    log("client handling failed: ${e.javaClass.simpleName}")
                } finally {
                    runCatching { client.close() }
                }
            }
        }
    }

    private fun handle(client: Socket) {
        client.soTimeout = HANDSHAKE_TIMEOUT_MS
        val cin = client.getInputStream()
        val cout = client.getOutputStream()

        val preamble = readPreamble(cin) ?: return
        val requestLine = preamble.first
        val headers = preamble.second
        val parts = requestLine.split(" ")
        if (parts.size < 3) {
            writeStatus(cout, 400, "Bad Request")
            return
        }
        val route = resolveUpstream(headers, cout) ?: return
        val cfg = route.upstream
        val method = parts[0].uppercase()
        val target = parts[1]
        val isConnect = method == "CONNECT"

        val (host, hostPort) = if (isConnect) {
            parseAuthority(target, 443)
        } else {
            val uri = runCatching { URI(target) }.getOrNull()
            if (uri?.host == null) {
                writeStatus(cout, 400, "Bad Request")
                return
            }
            val p = if (uri.port != -1) uri.port else if (uri.scheme == "https") 443 else 80
            Pair(uri.host, p)
        }
        if (host.isEmpty()) {
            writeStatus(cout, 400, "Bad Request")
            return
        }

        // Attribution self-test (PROXY-015). A probe host is answered here
        // and NEVER forwarded: no upstream is contacted, so a probe cannot
        // egress anywhere even if the site's proxy is broken or the route
        // table is wrong. What it records is the pair the app needs --
        // which credential arrived carrying which nonce -- so the app can
        // prove, on THIS device and THIS WebView, that each container
        // presents its own credential rather than replaying a sibling's.
        if (host.endsWith(PROBE_SUFFIX)) {
            val nonce = host.removeSuffix(PROBE_SUFFIX)
            recordProbe(nonce, route.siteId)
            log("probe ${route.siteId} (answered locally, no upstream)")
            writeStatus(cout, 200, "OK")
            return
        }

        log("upstream connecting via ${cfg.type} ${cfg.host}:${cfg.port} for ${if (isConnect) "CONNECT" else method} $host:$hostPort")
        val upstream: Socket = try {
            when (cfg.type) {
                UpstreamType.DIRECT -> openDirect(host, hostPort)
                UpstreamType.SOCKS5 -> openViaSocks5(cfg, host, hostPort)
                UpstreamType.HTTP, UpstreamType.HTTPS ->
                    openViaHttpProxy(cfg, host, hostPort, isConnect)
            }
        } catch (e: Exception) {
            log("upstream connect FAILED for $host:$hostPort via ${cfg.type}: ${e.javaClass.simpleName}: ${e.message} — sending 502")
            writeStatus(cout, 502, "Bad Gateway")
            return
        }
        log("upstream connected for $host:$hostPort")

        try {
            if (isConnect) {
                // Tunnel established at the upstream; tell the WebView the
                // CONNECT succeeded and splice raw bytes both ways.
                cout.write("HTTP/1.1 200 Connection Established\r\n\r\n".toByteArray(Charsets.ISO_8859_1))
                cout.flush()
            } else {
                // Forward mode: replay the (rewritten) request preamble to
                // the upstream, then splice. SOCKS gives an origin tunnel
                // (origin-form path, no proxy auth header); an HTTP proxy
                // wants the absolute-form line plus Proxy-Authorization.
                val rewritten = if (cfg.type != UpstreamType.HTTP && cfg.type != UpstreamType.HTTPS) {
                    rewriteForOriginTunnel(requestLine, target, headers)
                } else {
                    rewriteForHttpProxy(requestLine, headers, cfg)
                }
                upstream.getOutputStream().write(rewritten.toByteArray(Charsets.ISO_8859_1))
                upstream.getOutputStream().flush()
            }
            // Switch to indefinite blocking for the splice phase.
            client.soTimeout = 0
            upstream.soTimeout = 0
            pump(client, upstream)
        } finally {
            runCatching { upstream.close() }
        }
    }

    private fun openDirect(host: String, port: Int): Socket {
        val s = Socket()
        s.connect(InetSocketAddress(host, port), CONNECT_TIMEOUT_MS)
        return s
    }

    // --- Upstream: SOCKS5 (with optional RFC 1929 username/password) ---

    private fun openViaSocks5(cfg: UpstreamConfig, host: String, port: Int): Socket {
        val s = Socket()
        s.connect(InetSocketAddress(cfg.host, cfg.port), CONNECT_TIMEOUT_MS)
        s.soTimeout = HANDSHAKE_TIMEOUT_MS
        val out = s.getOutputStream()
        val ins = s.getInputStream()

        // Greeting: when the user explicitly configured credentials,
        // insist on RFC 1929 user/pass — offering no-auth alongside lets
        // the server silently skip the credentials the user provided.
        if (cfg.hasCredentials) {
            out.write(byteArrayOf(0x05, 0x01, 0x02))
        } else {
            out.write(byteArrayOf(0x05, 0x01, 0x00))
        }
        out.flush()
        val method = byteArrayOf(0, 0)
        readFully(ins, method)
        if (method[0].toInt() != 0x05) throw IllegalStateException("bad socks version")
        when (method[1].toInt() and 0xFF) {
            0x00 -> { /* no auth */ }
            0x02 -> {
                if (!cfg.hasCredentials) throw IllegalStateException("socks requires auth, none configured")
                val u = cfg.username!!.toByteArray(Charsets.UTF_8)
                val p = cfg.password!!.toByteArray(Charsets.UTF_8)
                val buf = ByteArray(3 + u.size + p.size)
                buf[0] = 0x01
                buf[1] = u.size.toByte()
                System.arraycopy(u, 0, buf, 2, u.size)
                buf[2 + u.size] = p.size.toByte()
                System.arraycopy(p, 0, buf, 3 + u.size, p.size)
                out.write(buf)
                out.flush()
                val authReply = byteArrayOf(0, 0)
                readFully(ins, authReply)
                if (authReply[1].toInt() != 0x00) throw IllegalStateException("socks auth rejected")
            }
            else -> throw IllegalStateException("no acceptable socks auth method")
        }

        // CONNECT command, ATYP=domain so the upstream resolves DNS (no
        // local DNS leak).
        val hostBytes = host.toByteArray(Charsets.US_ASCII)
        if (hostBytes.size > 255) throw IllegalStateException("hostname too long")
        val req = ByteArray(7 + hostBytes.size)
        req[0] = 0x05; req[1] = 0x01; req[2] = 0x00; req[3] = 0x03
        req[4] = hostBytes.size.toByte()
        System.arraycopy(hostBytes, 0, req, 5, hostBytes.size)
        req[5 + hostBytes.size] = ((port shr 8) and 0xFF).toByte()
        req[6 + hostBytes.size] = (port and 0xFF).toByte()
        out.write(req)
        out.flush()

        val reply = ByteArray(4)
        readFully(ins, reply)
        if (reply[1].toInt() != 0x00) throw IllegalStateException("socks connect failed rep=${reply[1].toInt()}")
        // Consume the bound address so the stream is positioned at the tunnel.
        when (reply[3].toInt() and 0xFF) {
            0x01 -> readFully(ins, ByteArray(4 + 2))
            0x04 -> readFully(ins, ByteArray(16 + 2))
            0x03 -> {
                val len = ByteArray(1); readFully(ins, len)
                readFully(ins, ByteArray((len[0].toInt() and 0xFF) + 2))
            }
            else -> throw IllegalStateException("bad socks atyp")
        }
        return s
    }

    // --- Upstream: HTTP / HTTPS proxy ---

    private fun openViaHttpProxy(cfg: UpstreamConfig, host: String, port: Int, isConnect: Boolean): Socket {
        val raw = Socket()
        raw.connect(InetSocketAddress(cfg.host, cfg.port), CONNECT_TIMEOUT_MS)
        raw.soTimeout = HANDSHAKE_TIMEOUT_MS
        var s: Socket = raw
        try {
            if (cfg.type == UpstreamType.HTTPS) {
                s = startTls(raw, cfg)
            }
            if (isConnect) {
                // Establish the CONNECT tunnel through the upstream proxy.
                val authority = "$host:$port"
                val sb = StringBuilder()
                sb.append("CONNECT ").append(authority).append(" HTTP/1.1\r\n")
                sb.append("Host: ").append(authority).append("\r\n")
                credentialHeader(cfg)?.let { sb.append(it).append("\r\n") }
                sb.append("\r\n")
                s.getOutputStream().write(sb.toString().toByteArray(Charsets.ISO_8859_1))
                s.getOutputStream().flush()
                val resp = readPreamble(s.getInputStream())
                    ?: throw IllegalStateException("no CONNECT response")
                val code = resp.first.split(" ").getOrNull(1)?.toIntOrNull() ?: 0
                if (code != 200) throw IllegalStateException("CONNECT rejected: ${resp.first}")
            }
        } catch (e: Exception) {
            runCatching { s.close() }
            runCatching { raw.close() }
            throw e
        }
        // Forward (absolute-form) mode replays its rewritten preamble in
        // handle(); nothing more to do here.
        return s
    }

    /**
     * Wrap [raw] in TLS to the configured upstream, with hostname
     * verification.
     *
     * An `SSLSocket` straight off the factory validates the certificate
     * chain but performs NO hostname check — the endpoint-identification
     * algorithm has to be asked for explicitly. Without it any host that
     * can present a valid publicly-trusted certificate for a name it owns
     * completes this handshake and receives the `Proxy-Authorization`
     * header (and every `CONNECT` target) written immediately afterwards.
     * Handshaking here rather than lazily on first write keeps that
     * failure inside the caller's fail-closed path.
     */
    private fun startTls(raw: Socket, cfg: UpstreamConfig): SSLSocket {
        val ssl = (SSLSocketFactory.getDefault() as SSLSocketFactory)
            .createSocket(raw, cfg.host, cfg.port, true) as SSLSocket
        ssl.sslParameters = ssl.sslParameters.apply {
            endpointIdentificationAlgorithm = "HTTPS"
        }
        ssl.startHandshake()
        return ssl
    }

    private fun credentialHeader(cfg: UpstreamConfig): String? {
        if (!cfg.hasCredentials) return null
        val token = base64("${cfg.username}:${cfg.password}".toByteArray(Charsets.UTF_8))
        return "Proxy-Authorization: Basic $token"
    }

    // --- Request rewriting (forward mode) ---

    private fun rewriteForHttpProxy(requestLine: String, headers: List<String>, cfg: UpstreamConfig): String {
        val sb = StringBuilder()
        sb.append(requestLine).append("\r\n")
        for (h in headers) {
            if (h.startsWith("Proxy-Authorization:", true)) continue
            if (h.startsWith("Proxy-Connection:", true)) continue
            if (h.startsWith("Connection:", true)) continue
            sb.append(h).append("\r\n")
        }
        credentialHeader(cfg)?.let { sb.append(it).append("\r\n") }
        sb.append("Connection: close\r\n")
        sb.append("\r\n")
        return sb.toString()
    }

    private fun rewriteForOriginTunnel(requestLine: String, target: String, headers: List<String>): String {
        // Convert absolute-form ("GET http://host/path HTTP/1.1") to
        // origin-form ("GET /path HTTP/1.1") for the tunneled origin server.
        val parts = requestLine.split(" ")
        val uri = runCatching { URI(target) }.getOrNull()
        val path = uri?.rawPath?.takeIf { it.isNotEmpty() } ?: "/"
        val query = uri?.rawQuery?.let { "?$it" } ?: ""
        val sb = StringBuilder()
        sb.append(parts[0]).append(" ").append(path).append(query).append(" ")
            .append(parts.getOrElse(2) { "HTTP/1.1" }).append("\r\n")
        for (h in headers) {
            if (h.startsWith("Proxy-Authorization:", true)) continue
            if (h.startsWith("Proxy-Connection:", true)) continue
            if (h.startsWith("Connection:", true)) continue
            sb.append(h).append("\r\n")
        }
        sb.append("Connection: close\r\n")
        sb.append("\r\n")
        return sb.toString()
    }

    // --- Byte plumbing ---

    private fun pump(a: Socket, b: Socket) {
        val ab = pool.submit {
            runCatching { copy(a.getInputStream(), b.getOutputStream()) }
            runCatching { a.shutdownInput() }
            runCatching { b.shutdownOutput() }
        }
        runCatching { copy(b.getInputStream(), a.getOutputStream()) }
        runCatching { b.shutdownInput() }
        runCatching { a.shutdownOutput() }
        ab.get()
    }

    private fun copy(src: InputStream, dst: OutputStream) {
        val buf = ByteArray(16 * 1024)
        while (true) {
            val n = src.read(buf)
            if (n < 0) break
            dst.write(buf, 0, n)
            dst.flush()
        }
    }

    private fun readPreamble(ins: InputStream): Pair<String, List<String>>? {
        val raw = StringBuilder()
        var last4 = 0
        var count = 0
        while (count < MAX_PREAMBLE) {
            val b = ins.read()
            if (b < 0) break
            raw.append(b.toChar())
            count++
            last4 = ((last4 shl 8) or b) and 0xFFFFFFFF.toInt()
            if (last4 == 0x0D0A0D0A) break // \r\n\r\n
        }
        if (raw.isEmpty()) return null
        val lines = raw.toString().split("\r\n").filter { it.isNotEmpty() }
        if (lines.isEmpty()) return null
        return Pair(lines[0], lines.drop(1))
    }

    private fun parseAuthority(authority: String, defaultPort: Int): Pair<String, Int> {
        val idx = authority.lastIndexOf(':')
        return if (idx > 0) {
            Pair(authority.substring(0, idx), authority.substring(idx + 1).toIntOrNull() ?: defaultPort)
        } else {
            Pair(authority, defaultPort)
        }
    }

    /**
     * Pick the upstream for one connection, or answer the client and
     * return null.
     *
     * Router mode is fail-closed by construction: there is no default
     * upstream to fall back to, so a caller that cannot present a known
     * credential is answered and dropped rather than routed anywhere. A
     * missing credential is a 407 (the WebView will re-issue the request
     * with one); a credential we do not recognise is a 502, not a second
     * challenge, so a caller that is guessing cannot be walked around the
     * loop indefinitely.
     */
    private fun resolveUpstream(headers: List<String>, cout: OutputStream): Route? {
        val realm = routerRealm
            ?: return config?.let { Route(LEGACY_SITE_ID, it) }
                ?: run { writeStatus(cout, 502, "Bad Gateway"); null }
        val credential = proxyAuthCredential(headers)
        if (credential == null) {
            writeChallenge(cout, realm)
            return null
        }
        val route = routes[credential]
        if (route == null) {
            log("rejecting connection bearing an unknown proxy credential")
            writeStatus(cout, 502, "Bad Gateway")
            return null
        }
        log("routing site ${route.siteId}")
        return route
    }

    /**
     * The base64 blob of a `Proxy-Authorization: Basic <blob>` header, or
     * null. Never decoded: the blob is the map key, so a credential is
     * only ever compared, and it cannot reach a log line by accident.
     */
    private fun proxyAuthCredential(headers: List<String>): String? {
        for (h in headers) {
            if (!h.startsWith("Proxy-Authorization:", true)) continue
            val value = h.substringAfter(':').trim()
            if (!value.startsWith("Basic ", true)) continue
            return value.substring(6).trim().takeIf { it.isNotEmpty() }
        }
        return null
    }

    private fun writeChallenge(out: OutputStream, realm: String) {
        runCatching {
            out.write(
                (
                    "HTTP/1.1 407 Proxy Authentication Required\r\n" +
                        "Proxy-Authenticate: Basic realm=\"$realm\"\r\n" +
                        "Content-Length: 0\r\n" +
                        "Connection: close\r\n\r\n"
                    ).toByteArray(Charsets.ISO_8859_1)
            )
            out.flush()
        }
    }

    private fun writeStatus(out: OutputStream, code: Int, reason: String) {
        runCatching {
            out.write("HTTP/1.1 $code $reason\r\nConnection: close\r\n\r\n".toByteArray(Charsets.ISO_8859_1))
            out.flush()
        }
    }

    private fun readFully(ins: InputStream, buf: ByteArray) {
        var off = 0
        while (off < buf.size) {
            val n = ins.read(buf, off, buf.size - off)
            if (n < 0) throw IllegalStateException("eof during read")
            off += n
        }
    }

    private fun log(msg: String) {
        logger?.invoke(msg)
    }

    companion object {
        private const val BACKLOG = 64
        private const val CONNECT_TIMEOUT_MS = 15_000
        private const val HANDSHAKE_TIMEOUT_MS = 20_000
        private const val MAX_PREAMBLE = 64 * 1024
        private val REALM_ALPHABET = ('a'..'f') + ('0'..'9')

        // RFC 2606 reserved TLD: a probe host can never resolve, so even
        // a bug that forwarded one could not reach a real server.
        const val PROBE_SUFFIX = ".webspace-probe.invalid"

        // Stand-in siteId for single-upstream (non-router) mode, where
        // there is exactly one route and no attribution to make.
        const val LEGACY_SITE_ID = "-"

        private const val B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

        // Hand-rolled so the relay works below API 26 (java.util.Base64)
        // without pulling in android.util.Base64 (which JVM unit tests stub
        // to a no-op under returnDefaultValues).
        fun base64(data: ByteArray): String {
            val sb = StringBuilder()
            var i = 0
            while (i < data.size) {
                val b0 = data[i].toInt() and 0xFF
                val b1 = if (i + 1 < data.size) data[i + 1].toInt() and 0xFF else 0
                val b2 = if (i + 2 < data.size) data[i + 2].toInt() and 0xFF else 0
                val n = (b0 shl 16) or (b1 shl 8) or b2
                sb.append(B64[(n shr 18) and 0x3F])
                sb.append(B64[(n shr 12) and 0x3F])
                sb.append(if (i + 1 < data.size) B64[(n shr 6) and 0x3F] else '=')
                sb.append(if (i + 2 < data.size) B64[n and 0x3F] else '=')
                i += 3
            }
            return sb.toString()
        }
    }
}
