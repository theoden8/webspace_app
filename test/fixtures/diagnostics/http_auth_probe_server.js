#!/usr/bin/env node
// Serves http_auth_probe.html behind HTTP Basic authentication, the way an
// nginx `auth_basic` / htpasswd folder does, so the sign-in prompt
// (HTTPAUTH-001..007) can be exercised by hand from a phone or desktop.
//
//   node test/fixtures/diagnostics/http_auth_probe_server.js \
//     [--port 8765] [--user alice] [--pass s3cret]
//
// Add http://<printed address>/protected/ as a site in the app. Every
// request is logged with its outcome; passwords are never printed.

const http = require('node:http');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

function arg(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  return i === -1 ? fallback : process.argv[i + 1];
}

const port = Number(arg('port', '8765'));
const user = arg('user', 'alice');
const pass = arg('pass', 's3cret');
const expected = `Basic ${Buffer.from(`${user}:${pass}`).toString('base64')}`;

// Two folders with two realms: a protection space is (host, realm), so the
// second folder must prompt again even after the first is signed in.
const REALMS = {
  '/protected/': 'WebSpace probe',
  '/protected2/': 'WebSpace probe (second realm)',
};
const stats = {};
for (const realm of Object.values(REALMS)) {
  stats[realm] = { challenged: 0, refused: 0, served: 0 };
}

const probePath = path.join(__dirname, 'http_auth_probe.html');

const BADGE = `<svg xmlns="http://www.w3.org/2000/svg" width="48" height="48" viewBox="0 0 48 48">
<rect width="48" height="48" rx="8" fill="#1b873f"/>
<path d="M13 25l7 7 15-16" stroke="#fff" stroke-width="5" fill="none" stroke-linecap="round" stroke-linejoin="round"/>
</svg>`;

const FRAME = `<!doctype html><meta charset="utf-8">
<body style="margin:0;font:13px system-ui;background:#e8f5e9;color:#1b5e20;padding:6px">
iframe loaded behind the same password
<script>parent.postMessage({ probe: 'frame', ok: true }, '*');</script>`;

const UNAUTHORIZED = `<html><head><title>401 Authorization Required</title></head>
<body><center><h1>401 Authorization Required</h1></center><hr>
<center>http_auth_probe_server</center></body></html>`;

const INDEX = `<!doctype html><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>HTTP auth probe server</title>
<body style="font:15px/1.5 system-ui;padding:16px">
<h1>HTTP auth probe server</h1>
<p>This page is not protected. The probe lives at
<a href="/protected/">/protected/</a>, behind Basic authentication.</p>
<p>Add <code>/protected/</code> itself as the site's URL so the first load is
the challenge.</p>`;

function log(req, status, why) {
  const t = new Date().toISOString().slice(11, 23);
  console.log(`${t} ${req.method} ${req.url} -> ${status} ${why}`);
}

function usernameOf(header) {
  if (!header || !header.startsWith('Basic ')) return null;
  const decoded = Buffer.from(header.slice(6), 'base64').toString('utf8');
  const colon = decoded.indexOf(':');
  return colon === -1 ? decoded : decoded.slice(0, colon);
}

function send(res, status, type, body, extra = {}) {
  res.writeHead(status, {
    'Content-Type': type,
    'Cache-Control': 'no-store',
    ...extra,
  });
  res.end(body);
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://probe');
  if (url.pathname === '/') {
    log(req, 200, 'index');
    return send(res, 200, 'text/html; charset=utf-8', INDEX);
  }
  const prefix = Object.keys(REALMS).find((p) => url.pathname.startsWith(p));
  if (!prefix) {
    log(req, 404, 'not found');
    return send(res, 404, 'text/plain', 'not found');
  }
  const realm = REALMS[prefix];
  const auth = req.headers.authorization;
  if (auth !== expected) {
    const tried = usernameOf(auth);
    if (tried === null) {
      stats[realm].challenged++;
      log(req, 401, `challenge, realm="${realm}"`);
    } else {
      stats[realm].refused++;
      log(req, 401, `refused username "${tried}", realm="${realm}"`);
    }
    return send(res, 401, 'text/html; charset=utf-8', UNAUTHORIZED, {
      'WWW-Authenticate': `Basic realm="${realm}", charset="UTF-8"`,
    });
  }
  stats[realm].served++;
  const rest = url.pathname.slice(prefix.length);
  log(req, 200, `as "${user}", realm="${realm}"`);
  switch (rest) {
    case '':
    case 'index.html':
      return send(res, 200, 'text/html; charset=utf-8',
          fs.readFileSync(probePath, 'utf8'));
    case 'badge.svg':
      return send(res, 200, 'image/svg+xml', BADGE);
    case 'data.json':
      return send(res, 200, 'application/json',
          JSON.stringify({ ok: true, realm, user }));
    case 'frame.html':
      return send(res, 200, 'text/html; charset=utf-8', FRAME);
    case 'stats.json':
      return send(res, 200, 'application/json',
          JSON.stringify({ realm, stats: stats[realm] }));
    default:
      return send(res, 404, 'text/plain', 'not found');
  }
});

server.listen(port, '0.0.0.0', () => {
  console.log(`HTTP auth probe: user "${user}", password "${'*'.repeat(pass.length)}"`);
  const addrs = ['127.0.0.1'];
  for (const list of Object.values(os.networkInterfaces())) {
    for (const a of list || []) {
      if (a.family === 'IPv4' && !a.internal) addrs.push(a.address);
    }
  }
  for (const a of addrs) console.log(`  http://${a}:${port}/protected/`);
});
