#!/usr/bin/env node
// Serves sw_blocker_probe.html, which checks by hand whether a site's
// service worker meets the site's blockers (CB-022, the Experimental
// "Service workers through blockers" switch, DEVTOOLS-011).
//
//   node test/fixtures/diagnostics/sw_blocker_probe_server.js [--port 8766]
//   adb reverse tcp:8766 tcp:8766
//
// Then add http://localhost:8766/ as a site. A service worker needs a secure
// context, and plain http is one only on localhost, so the server listens on
// loopback alone and the phone reaches it through `adb reverse` (or run it in
// Termux on the phone itself).
//
// Every request to a probe target is recorded with who made it (`via`: page,
// worker, proxied) and the run it belongs to; the page reads the record back,
// so a cell says what left the device, not what the page was answered.

const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');

function arg(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  return i === -1 ? fallback : process.argv[i + 1];
}

const port = Number(arg('port', '8766'));

const FILES = {
  '/': ['sw_blocker_probe.html', 'text/html; charset=utf-8'],
  '/sw/frame.html': ['sw_blocker_probe_frame.html', 'text/html; charset=utf-8'],
  '/sw/sw.js': ['sw_blocker_probe_sw.js', 'text/javascript; charset=utf-8'],
};

// The targets on this host. `control` no list names; the others are
// EasyPrivacy rules that match a first-party request: `/beacon.js`,
// `/collect?v=` and `/matomo.js$domain=~github.com`.
const TARGETS = {
  '/control.json': ['control', 'application/json', '{"reached":"control"}'],
  '/beacon.js': ['beacon', 'text/javascript', '/* reached:beacon */'],
  '/collect': ['collect', 'text/plain', 'reached:collect'],
  '/matomo.js': ['matomo', 'text/javascript', '/* reached:matomo */'],
};

const VIAS = new Set(['page', 'worker', 'proxied']);
const MAX_RUNS = 50;
const runs = new Map();

function record(run, target, via) {
  if (!runs.has(run)) {
    runs.set(run, new Set());
    if (runs.size > MAX_RUNS) runs.delete(runs.keys().next().value);
  }
  runs.get(run).add(`${target}|${via}`);
}

function log(req, status, why) {
  const t = new Date().toISOString().slice(11, 23);
  console.log(`${t} ${req.method} ${req.url} -> ${status} ${why}`);
}

function send(res, status, type, body) {
  res.writeHead(status, { 'Content-Type': type, 'Cache-Control': 'no-store' });
  res.end(body);
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://probe');
  const file = FILES[url.pathname];
  if (file) {
    log(req, 200, file[0]);
    return send(res, 200, file[1], fs.readFileSync(path.join(__dirname, file[0])));
  }
  const target = TARGETS[url.pathname];
  if (target) {
    const [name, type, body] = target;
    const run = url.searchParams.get('run') ?? '';
    const via = url.searchParams.get('via') ?? '';
    if (run && VIAS.has(via)) record(run, name, via);
    log(req, 200, `REACHED ${name} via ${via || '?'}`);
    return send(res, 200, type, body);
  }
  if (url.pathname === '/report') {
    const run = url.searchParams.get('run') ?? '';
    const reached = [...(runs.get(run) ?? [])].map((key) => {
      const [name, via] = key.split('|');
      return { target: name, via };
    });
    log(req, 200, `report for ${run}: ${reached.length} reached`);
    return send(res, 200, 'application/json', JSON.stringify({ run, reached }));
  }
  log(req, 404, 'not found');
  return send(res, 404, 'text/plain', 'not found');
});

server.listen(port, '127.0.0.1', () => {
  console.log('Service worker blocker probe (CB-022)');
  console.log(`  this machine: http://localhost:${port}/`);
  console.log(`  a phone over USB: adb reverse tcp:${port} tcp:${port}, then the same URL`);
});
