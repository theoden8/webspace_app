// Page servers on 127.0.0.1, on a free port. Loopback over plain HTTP is a
// secure context, which getUserMedia, geolocation and WebAuthn require.

const http = require('node:http');

const BLANK_PAGE = '<!doctype html><html><head></head><body></body></html>';

function listen(handler) {
  const server = http.createServer(handler);
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve(server)));
}

const originOf = (server) => `http://127.0.0.1:${server.address().port}`;

/** Serves `html` at every path. */
const startBlankServer = (html = BLANK_PAGE, type = 'text/html') =>
  listen((_req, res) => {
    res.writeHead(200, { 'Content-Type': type });
    res.end(html);
  });

module.exports = { BLANK_PAGE, listen, originOf, startBlankServer };
