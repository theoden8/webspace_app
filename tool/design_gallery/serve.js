// Serves a built design target for a human or an agent to interact with.
//
//   npm run design:app            # build/web
//   npm run design:serve          # http://127.0.0.1:8110
//   npm run design:serve -- --root build/design_gallery --port 8111

const path = require('node:path');
const { serve, requireBuild } = require('./static_server');

function arg(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  return i === -1 ? fallback : process.argv[i + 1];
}

(async () => {
  const root = path.resolve(arg('root', 'build/web'));
  const port = Number(arg('port', 8110));
  const host = arg('host', '127.0.0.1');
  const which = root.endsWith('design_gallery') ? 'gallery' : 'app';
  await requireBuild(root, `scripts/design_web.sh ${which}`);
  await serve(root, port, host);
  console.log(`${path.relative(process.cwd(), root)} -> http://${host}:${port}`);
})();
