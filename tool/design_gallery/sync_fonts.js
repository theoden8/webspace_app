// Copies Roboto into web/fonts/ for the design gallery.
//
// CanvasKit fetches Roboto from fonts.gstatic.com at runtime; where that is
// unreachable (CI, restricted egress) text renders as nothing at all, not as
// a fallback face. The gallery registers these files itself instead.
//
//   node tool/design_gallery/sync_fonts.js

const fs = require('node:fs');
const path = require('node:path');

const FACES = ['400Regular', '500Medium', '700Bold'];
const dest = path.resolve('web/fonts');

fs.mkdirSync(dest, { recursive: true });
for (const face of FACES) {
  const src = require.resolve(`@expo-google-fonts/roboto/${face}/Roboto_${face}.ttf`);
  fs.copyFileSync(src, path.join(dest, `Roboto_${face}.ttf`));
  console.log(`web/fonts/Roboto_${face}.ttf`);
}
