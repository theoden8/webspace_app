// Static file server shared by shoot.js (screenshots) and serve.js (the
// designer's browser). Flutter web needs correct content types for .wasm and
// .json or the engine refuses to boot, which is the only reason this is not
// two lines of http.createServer at each call site.

const fs = require('node:fs/promises');
const path = require('node:path');
const http = require('node:http');

const TYPES = {
  '.html': 'text/html',
  '.js': 'text/javascript',
  '.mjs': 'text/javascript',
  '.json': 'application/json',
  '.wasm': 'application/wasm',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.svg': 'image/svg+xml',
  '.ttf': 'font/ttf',
  '.otf': 'font/otf',
  '.woff2': 'font/woff2',
  '.symbols': 'text/plain',
  '.map': 'application/json',
};

async function serve(root, port, host = '127.0.0.1') {
  const server = http.createServer(async (req, res) => {
    const rel = decodeURIComponent(new URL(req.url, 'http://x').pathname);
    const file = path.join(root, rel === '/' ? '/index.html' : rel);
    try {
      const body = await fs.readFile(file);
      res.writeHead(200, { 'content-type': TYPES[path.extname(file)] || 'application/octet-stream' });
      res.end(body);
    } catch {
      res.writeHead(404).end('not found');
    }
  });
  await new Promise((r) => server.listen(port, host, r));
  return server;
}

// A missing build is the common failure for anyone who did not run the build
// step, so say which command produces it rather than 404ing every request.
async function requireBuild(root, hint) {
  try {
    await fs.access(path.join(root, 'index.html'));
  } catch {
    console.error(`no build at ${path.relative(process.cwd(), root)}/index.html`);
    console.error(`  run: ${hint}`);
    process.exit(1);
  }
}

module.exports = { serve, requireBuild };
