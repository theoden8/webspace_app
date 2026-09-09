package org.codeberg.theoden8.webspace.proxy

import java.io.File
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
 * configured upstream, and for an HTTPS upstream only past a handshake
 * that verified that upstream's certificate identity (see [startTls]).
 * If the upstream is unreachable, untrusted, or rejects auth, the client
 * gets a `502` and the connection closes — the relay never opens a
 * direct connection to the origin, so a failed proxy cannot leak the IP.
 *
 * The listener is bound to loopback, which keeps it off the network but not
 * away from the device: every other app with `INTERNET` can reach
 * `127.0.0.1:<port>` too, and this relay answers with the user's upstream
 * credentials attached. Each accepted connection is therefore checked against
 * `/proc/net/tcp{,6}`: the peer's connection appears as a row whose local port
 * is its own and whose remote port is ours, and field 7 names the UID that owns
 * it. A row owned by anyone but us is another app, and is refused before any
 * upstream connection is opened.
 *
 * **Know what this does and does not cover.** The port pair alone is the row
 * *any* caller creates, so the UID is the whole discriminator — matching ports
 * and stopping there would classify every caller as OWN. And the table is only
 * readable up to API 28: Android 10 denies `/proc/net` outright rather than
 * filtering it per-UID, so from API 29 the read fails and every peer is
 * UNKNOWN. The check therefore bites on API 24-28 and is inert above it.
 * Nothing supported replaces it: `ConnectivityManager.getConnectionOwnerUid`
 * answers only for the caller's own `VpnService` tunnel, and TCP has no
 * `SO_PEERCRED`. On API 29+ the ephemeral port is the only thing between a
 * local app and this relay, and ~15 bits is scannable — that residual exposure
 * predates this check and is not closed by it.
 *
 * Unreadable table means unverifiable, not hostile: failing closed there would
 * strand proxying on every modern device for a threat that needs a malicious
 * app already installed.
 *
 * Deliberately free of `android.*` imports so it runs under plain JVM
 * JUnit (no Robolectric). The lifecycle wrapper / method channel lives in
 * [ProxyRelayPlugin].
 */
class ProxyRelay(
    private val logger: ((String) -> Unit)? = null,
    /**
     * This process's UID, for the `/proc/net/tcp` peer check. Passed in rather
     * than read here so the class stays free of `android.*` and JVM-testable.
     * Null disables the UID half of the check, which then cannot reject.
     */
    private val ownUid: Int? = null,
    private val peerCheck: ((peerPort: Int, relayPort: Int) -> PeerVerdict)? = null,
) {

    /** Whether an accepted peer is one of this process's own sockets. */
    enum class PeerVerdict { OWN, FOREIGN, UNKNOWN }

    enum class UpstreamType { HTTP, HTTPS, SOCKS5 }

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

    @Volatile
    private var serverSocket: ServerSocket? = null
    @Volatile
    private var config: UpstreamConfig? = null
    @Volatile
    private var boundPort: Int = -1
    private var acceptThread: Thread? = null
    @Volatile
    private var peerCheckUnavailableLogged: Boolean = false

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
        if (isRunning() && cfg == config) {
            return boundPort
        }
        stop()
        val socket = ServerSocket()
        socket.reuseAddress = true
        // Pin to IPv4 loopback (127.0.0.1) explicitly. InetAddress
        // .getLoopbackAddress() can return ::1 on dual-stack JVMs, which
        // is unreachable from the http://127.0.0.1:<port> rule we hand to
        // ProxyController — Chromium gets ERR_PROXY_CONNECTION_FAILED
        // without ever opening a TCP connection to our listener.
        val bindAddr = InetAddress.getByName("127.0.0.1")
        socket.bind(InetSocketAddress(bindAddr, 0), BACKLOG)
        serverSocket = socket
        config = cfg
        boundPort = socket.localPort
        val t = Thread({ acceptLoop(socket) }, "proxy-relay-accept").apply { isDaemon = true }
        acceptThread = t
        t.start()
        log("started on ${bindAddr.hostAddress}:$boundPort (upstream type=${cfg.type})")
        return boundPort
    }

    @Synchronized
    fun stop() {
        serverSocket?.let { runCatching { it.close() } }
        serverSocket = null
        config = null
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
            val cfg = config
            if (cfg == null) {
                runCatching { client.close() }
                continue
            }
            if (!peerAllowed(client.port)) {
                runCatching { client.close() }
                continue
            }
            log("accepted connection from ${client.inetAddress.hostAddress}:${client.port}")
            pool.execute {
                try {
                    handle(client, cfg)
                } catch (e: Exception) {
                    log("client handling failed: ${e.javaClass.simpleName}")
                } finally {
                    runCatching { client.close() }
                }
            }
        }
    }

    /**
     * Gate an accepted connection on the peer being one of our own sockets.
     * An unverifiable verdict is logged once per relay, not per connection.
     */
    private fun peerAllowed(peerPort: Int): Boolean {
        val check: (Int, Int) -> PeerVerdict =
            peerCheck ?: { p, r -> readPeerVerdict(p, r, ownUid) }
        return when (check(peerPort, boundPort)) {
            PeerVerdict.OWN -> true
            PeerVerdict.FOREIGN -> {
                log("refused connection from another process (peer port $peerPort)")
                false
            }
            PeerVerdict.UNKNOWN -> {
                if (!peerCheckUnavailableLogged) {
                    peerCheckUnavailableLogged = true
                    log("peer ownership unverifiable (/proc/net/tcp unreadable); accepting local connections")
                }
                true
            }
        }
    }

    private fun handle(client: Socket, cfg: UpstreamConfig) {
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

        log("upstream connecting via ${cfg.type} ${cfg.host}:${cfg.port} for ${if (isConnect) "CONNECT" else method} $host:$hostPort")
        val upstream: Socket = try {
            when (cfg.type) {
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
                val rewritten = if (cfg.type == UpstreamType.SOCKS5) {
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

        private val PROC_NET_TCP = listOf("/proc/net/tcp", "/proc/net/tcp6")

        private fun readPeerVerdict(peerPort: Int, relayPort: Int, ownUid: Int?): PeerVerdict =
            peerVerdict(
                PROC_NET_TCP.map { path -> runCatching { File(path).readText() }.getOrNull() },
                peerPort,
                relayPort,
                ownUid,
            )

        /**
         * Classify a peer against the contents of `/proc/net/{tcp,tcp6}`.
         *
         * A connection to the relay shows up as a row whose local port is the
         * peer's and whose remote port is the relay's. Rows are
         * `sl local_address rem_address st tx:rx tr:when retrnsmt uid ...` with
         * `hex-ip:hex-port` addresses, so the owning UID is field 7.
         *
         * **The port pair alone proves nothing.** It is the row that *any*
         * connection to the relay creates, ours or another app's, so matching on
         * it and stopping there classifies every caller as OWN. [ownUid] is what
         * actually discriminates: on a table that lists the whole namespace, a
         * row owned by another UID is another app. When it is null, or the row
         * carries no parsable UID, the check degrades to the port pair and
         * cannot reject anything — which is the honest answer, not a pass.
         *
         * Split out for a JVM test, which cannot arrange a foreign process to
         * connect.
         */
        fun peerVerdict(
            tables: List<String?>,
            peerPort: Int,
            relayPort: Int,
            ownUid: Int? = null,
        ): PeerVerdict {
            var readable = false
            for (table in tables) {
                if (table == null) continue
                readable = true
                for (line in table.lineSequence()) {
                    val fields = line.trim().split(WHITESPACE)
                    if (fields.size < 3) continue
                    val local = hexPort(fields[1]) ?: continue
                    val remote = hexPort(fields[2]) ?: continue
                    if (local != peerPort || remote != relayPort) continue
                    val uid = fields.getOrNull(7)?.toIntOrNull()
                    if (ownUid == null || uid == null) return PeerVerdict.OWN
                    if (uid == ownUid) return PeerVerdict.OWN
                }
            }
            // Readable, and either no row for this peer or one owned by
            // somebody else. Both are foreign.
            return if (readable) PeerVerdict.FOREIGN else PeerVerdict.UNKNOWN
        }

        private val WHITESPACE = Regex("\\s+")

        private fun hexPort(address: String): Int? {
            val sep = address.lastIndexOf(':')
            if (sep < 0) return null
            return address.substring(sep + 1).toIntOrNull(16)
        }

        private const val CONNECT_TIMEOUT_MS = 15_000
        private const val HANDSHAKE_TIMEOUT_MS = 20_000
        private const val MAX_PREAMBLE = 64 * 1024

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
