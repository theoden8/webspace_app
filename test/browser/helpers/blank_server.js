// Page servers on 127.0.0.1, on a free port. Loopback over plain HTTP is a
// secure context, which getUserMedia, geolocation and WebAuthn require.

const http = require('node:http');

const BLANK_PAGE = '<!doctype html><html><head></head><body></body></html>';

function listen(handler) {
  const server = http.createServer(handler);
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve(server)));
}

const originOf = (server) => `http://127.0.0.1:${server.address().port}`;

// Chromium keeps a page's connection alive, so server.close() never fires its
// callback until that socket times out; a test that awaits the close before the
// browser is gone deadlocks and hangs the whole tier (seen on CI for hours).
// Force the sockets shut first. closeAllConnections() is a no-op with none open,
// so this is the one safe way any browser test tears a server down.
const closeServer = (server) => {
  server.closeAllConnections();
  return new Promise((resolve) => server.close(resolve));
};

/** Serves `html` at every path. */
const startBlankServer = (html = BLANK_PAGE, type = 'text/html') =>
  listen((_req, res) => {
    res.writeHead(200, { 'Content-Type': type });
    res.end(html);
  });

module.exports = { BLANK_PAGE, listen, originOf, startBlankServer, closeServer };
