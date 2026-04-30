// Tiny Node HTTP proxy server for browser-tier proxy tests. Forwards
// HTTP requests and CONNECT tunnels, records every transit so tests can
// assert which traffic flowed through it (the entire point: a real proxy
// catches every byte; a leaking config silently goes direct).
//
// Auth mode: pass `auth: {username, password}` to require Basic
// Proxy-Authorization. Wrong / missing auth returns 407 with
// `Proxy-Authenticate: Basic realm="webspace-proxy"`. The recorded log
// distinguishes auth attempts (`type: 'auth_challenge'`) from successful
// transits, so tests can assert fail-closed behaviour without parsing
// HTTP transcripts.

const http = require('node:http');
const net = require('node:net');
const url = require('node:url');

function parseBasicAuth(header) {
  if (!header || !header.startsWith('Basic ')) return null;
  const decoded = Buffer.from(header.slice(6), 'base64').toString('utf8');
  const idx = decoded.indexOf(':');
  if (idx === -1) return null;
  return { username: decoded.slice(0, idx), password: decoded.slice(idx + 1) };
}

function startProxy({ auth = null } = {}) {
  const log = [];

  function checkAuth(req, res, kind) {
    if (!auth) return true;
    const provided = parseBasicAuth(req.headers['proxy-authorization']);
    if (!provided
        || provided.username !== auth.username
        || provided.password !== auth.password) {
      log.push({
        type: 'auth_challenge',
        kind,
        url: req.url,
        host: req.headers.host,
        provided: provided ? { username: provided.username } : null,
      });
      const headers = {
        'Proxy-Authenticate': 'Basic realm="webspace-proxy"',
        'Content-Length': '0',
      };
      if (res.writeHead) {
        res.writeHead(407, headers);
        res.end();
      } else {
        // CONNECT path: res is the raw socket.
        res.write('HTTP/1.1 407 Proxy Authentication Required\r\n');
        for (const [k, v] of Object.entries(headers)) {
          res.write(`${k}: ${v}\r\n`);
        }
        res.write('\r\n');
        res.destroy();
      }
      return false;
    }
    return true;
  }

  const server = http.createServer((req, res) => {
    if (!checkAuth(req, res, 'http')) return;

    // Absolute-URI request line is what HTTP proxies receive.
    let target;
    try {
      target = new url.URL(req.url);
    } catch {
      res.writeHead(400);
      res.end('bad request');
      return;
    }

    log.push({
      type: 'http',
      method: req.method,
      url: req.url,
      host: req.headers.host,
      authedAs: auth ? parseBasicAuth(req.headers['proxy-authorization']).username : null,
    });

    const upstream = http.request({
      host: target.hostname,
      port: target.port || 80,
      path: target.pathname + target.search,
      method: req.method,
      headers: req.headers,
    }, (uRes) => {
      res.writeHead(uRes.statusCode, uRes.headers);
      uRes.pipe(res);
    });
    upstream.on('error', (e) => {
      log.push({ type: 'upstream_error', error: e.message });
      res.writeHead(502);
      res.end(`upstream error: ${e.message}`);
    });
    req.pipe(upstream);
  });

  // CONNECT for HTTPS (clients send `CONNECT host:port HTTP/1.1`).
  server.on('connect', (req, clientSocket, head) => {
    if (!checkAuth(req, clientSocket, 'connect')) return;
    const [host, portStr] = req.url.split(':');
    const port = parseInt(portStr, 10) || 443;
    log.push({
      type: 'connect',
      url: req.url,
      host, port,
      authedAs: auth ? parseBasicAuth(req.headers['proxy-authorization']).username : null,
    });
    const upstream = net.connect(port, host, () => {
      clientSocket.write('HTTP/1.1 200 Connection Established\r\n\r\n');
      upstream.write(head);
      upstream.pipe(clientSocket);
      clientSocket.pipe(upstream);
    });
    upstream.on('error', () => clientSocket.destroy());
    clientSocket.on('error', () => upstream.destroy());
  });

  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address();
      resolve({
        host: '127.0.0.1',
        port,
        url: `http://127.0.0.1:${port}/`,
        log,
        clearLog: () => { log.length = 0; },
        close: () => new Promise((r) => server.close(r)),
      });
    });
  });
}

// Tiny HTTP origin server that returns a known body so tests can
// distinguish "page loaded through proxy" from "page failed".
function startOrigin({ body = 'origin-ok', contentType = 'text/html' } = {}) {
  const log = [];
  const server = http.createServer((req, res) => {
    log.push({ url: req.url, host: req.headers.host });
    res.writeHead(200, {
      'Content-Type': contentType,
      'Content-Length': Buffer.byteLength(body).toString(),
    });
    res.end(body);
  });
  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address();
      resolve({
        host: '127.0.0.1',
        port,
        url: `http://127.0.0.1:${port}/`,
        log,
        clearLog: () => { log.length = 0; },
        close: () => new Promise((r) => server.close(r)),
      });
    });
  });
}

module.exports = { startProxy, startOrigin };
