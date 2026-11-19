// LICENSE-001 for the PDF.js WebKit compiles into the Linux packages: its
// Liberation Sans 1.07.4 fonts are GPL-2.0, and linux/pdfjs_fonts.sh replaces
// them with a 2.x release under the OFL before the build. The script is run
// here on a tree laid out as WebKit's, with stand-in fonts that carry the
// strings it reads; scripts/check_snap.sh reads the built library.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { REPO } = require('./helpers/source');

const STYLES = ['Regular', 'Bold', 'Italic', 'BoldItalic'];
const DEP5 = [
  'Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/',
  '',
  'Files: *',
  'Copyright:',
  ' Copyright (c) 2012 Red Hat, Inc. with Reserved Font Name Liberation.',
  'License: SIL-OFL-1.1',
  ' This Font Software is licensed under the SIL Open Font License,',
  ' Version 1.1.',
  ' .',
  ' SIL OPEN FONT LICENSE Version 1.1 - 26 February 2007',
  '',
  'Files: debian/*',
  'Copyright: someone',
  'License: GPL-2+',
  ' This package is free software under the GNU General Public License.',
  '',
].join('\n');

function tree(t, { font = (s) => `Version 2.1.5\0Licensed under the SIL Open Font License, Version 1.1\0${s}`, extra = {} } = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'pdfjs-fonts-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  fs.mkdirSync(path.join(root, 'src/Source/ThirdParty/pdfjs/web/standard_fonts'), { recursive: true });
  fs.mkdirSync(path.join(root, 'fonts'));
  for (const s of STYLES) {
    fs.writeFileSync(path.join(root, 'src/Source/ThirdParty/pdfjs/web/standard_fonts', `LiberationSans-${s}.ttf`), 'Version 1.07.4');
    if (font(s) !== null) fs.writeFileSync(path.join(root, 'fonts', `LiberationSans-${s}.ttf`), font(s));
  }
  fs.writeFileSync(path.join(root, 'src/Source/ThirdParty/pdfjs/web/standard_fonts/LICENSE_LIBERATION'),
    'licensed pursuant to the GNU General Public License v.2');
  for (const [rel, text] of Object.entries(extra)) fs.writeFileSync(path.join(root, 'src', rel), text);
  fs.writeFileSync(path.join(root, 'copyright'), DEP5);
  return { root };
}

// The fonts' LICENSE as the freedesktop SDK installs it, for the flatpak.
const LICENCE = [
  'Copyright (c) 2012 Red Hat, Inc.',
  '\twith Reserved Font Name Liberation.',
  '',
  'This Font Software is licensed under the SIL Open Font License,',
  'Version 1.1.',
  '',
  'SIL OPEN FONT LICENSE Version 1.1 - 26 February 2007',
  '',
].join('\n');

function run(root, notice = ['--copyright', path.join(root, 'copyright')]) {
  return spawnSync('bash', [path.join(REPO, 'linux/pdfjs_fonts.sh'), '--src', path.join(root, 'src'),
    '--fonts', path.join(root, 'fonts'), ...notice], { encoding: 'utf8' });
}

test('LICENSE-001 PDF.js ships Liberation Sans 2.x under the OFL, with its licence and holders', (t) => {
  const { root } = tree(t);
  const r = run(root);
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.stdout.trim(), 'Source/ThirdParty/pdfjs/web/standard_fonts/LiberationSans-*.ttf and LICENSE_LIBERATION'
    + ' replaced by Liberation Sans 2.1.5 (OFL-1.1) by linux/pdfjs_fonts.sh');
  const dir = path.join(root, 'src/Source/ThirdParty/pdfjs/web/standard_fonts');
  for (const s of STYLES) assert.match(fs.readFileSync(path.join(dir, `LiberationSans-${s}.ttf`), 'utf8'), /^Version 2\.1\.5/);
  assert.equal(fs.readFileSync(path.join(dir, 'LICENSE_LIBERATION'), 'utf8'), [
    'Copyright (c) 2012 Red Hat, Inc. with Reserved Font Name Liberation.',
    '',
    'This Font Software is licensed under the SIL Open Font License,',
    'Version 1.1.',
    '',
    'SIL OPEN FONT LICENSE Version 1.1 - 26 February 2007',
    '',
  ].join('\n'), 'the OFL stanza alone, not the packaging scripts\' GPL');
});

test('LICENSE-001 the swap refuses a font it cannot vouch for, and GNU text left in PDF.js', (t) => {
  const refused = (opts, why) => {
    const r = run(tree(t, opts).root);
    assert.equal(r.status, 1, `${why}: exit ${r.status}`);
    return r.stderr;
  };
  assert.match(refused({ font: () => 'Version 1.07.4\0Licensed under the Liberation Fonts license' }, 'a 1.x release'),
    /is Version 1\.07\.4, not a 2\.x release/);
  assert.match(refused({ font: () => 'Version 2.1.5\0Licensed under some other terms' }, 'a font not under the OFL'),
    /does not say it is under the SIL Open Font License/);
  assert.match(refused({ font: (s) => (s === 'Italic' ? null : 'Version 2.1.5\0Licensed under the SIL Open Font License') },
    'a style missing'), /no .*LiberationSans-Italic\.ttf/);
  assert.match(refused({ extra: { 'Source/ThirdParty/pdfjs/web/NOTES': 'GNU General Public License' } }, 'GNU text elsewhere'),
    /a GNU licence is still under PDF\.js: .*web\/NOTES/);
});

test('LICENSE-001 the fonts\' licence file is taken as it is where no Debian copyright file names it', (t) => {
  const { root } = tree(t);
  fs.writeFileSync(path.join(root, 'LICENSE'), LICENCE);
  const r = run(root, ['--licence', path.join(root, 'LICENSE')]);
  assert.equal(r.status, 0, r.stderr);
  assert.equal(fs.readFileSync(path.join(root, 'src/Source/ThirdParty/pdfjs/web/standard_fonts/LICENSE_LIBERATION'), 'utf8'),
    LICENCE);
  fs.writeFileSync(path.join(root, 'GPL'), 'GNU GENERAL PUBLIC LICENSE Version 2');
  assert.equal(run(tree(t).root, ['--licence', path.join(root, 'GPL')]).status, 1, 'a licence file that is not the OFL');
  assert.equal(run(root, []).status, 2, 'neither --copyright nor --licence');
  assert.equal(run(root, ['--copyright', path.join(root, 'copyright'), '--licence', path.join(root, 'LICENSE')]).status, 2,
    'both');
});
