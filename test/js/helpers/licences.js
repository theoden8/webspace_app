// The licence policy (LICENSE-001) as data: which licences a shipped
// component may be under (openspec/specs/legal/licences.tsv), every
// third-party component a build file pulls in outside pub and Cargo
// (components.tsv), the places a build pulls one in, read from the build
// files themselves, and what the pub packages the app depends on ship.

const fs = require('node:fs');
const path = require('node:path');
const { fileURLToPath, pathToFileURL } = require('node:url');
const { abs, read, exists, files } = require('./source');

const LICENCES = 'openspec/specs/legal/licences.tsv';
const COMPONENTS = 'openspec/specs/legal/components.tsv';
const CASES = 'openspec/specs/legal/licence_cases.tsv';

/** The rows of a TSV, comments and blank lines left out. */
function rows(text) {
  return text.split('\n').filter((l) => l.trim() && !l.startsWith('#')).map((l) => l.split('\t'));
}

/** SPDX id -> { how: 'linked' | 'shared', only: Set of components or null }. */
function policy(text = read(LICENCES)) {
  const out = new Map();
  for (const [id, how, only] of rows(text)) {
    out.set(id.trim(), { how: how.trim(), only: only ? new Set(only.trim().split(/\s+/)) : null });
  }
  return out;
}

/** The ids, parentheses and operators of an SPDX expression; `/` is Cargo's old OR. */
function tokens(expression) {
  return expression.replace(/\//g, ' OR ').replace(/([()])/g, ' $1 ').trim().split(/\s+/).filter(Boolean);
}

/**
 * Whether [expression] lets [component] ship as [ships]: some alternative of
 * every OR whose terms are all allowed. A build tool ships nothing.
 */
function allows(expression, { ships, component, licences = policy() }) {
  if (ships === 'build') return true;
  const t = tokens(expression ?? '');
  if (t.length === 0) return false;
  let at = 0;
  const leaf = () => {
    let id = t[at++];
    if (t[at] === 'WITH') {
      id = `${id} WITH ${t[at + 1]}`;
      at += 2;
    }
    const row = licences.get(id);
    if (!row || (row.only && !row.only.has(component))) return false;
    return row.how === 'linked' || ships === 'shared';
  };
  const factor = () => {
    if (t[at] === '(') {
      at++;
      const v = or();
      at++;
      return v;
    }
    return leaf();
  };
  const and = () => {
    let v = factor();
    while (t[at] === 'AND') {
      at++;
      v = factor() && v;
    }
    return v;
  };
  const or = () => {
    let v = and();
    while (t[at] === 'OR') {
      at++;
      v = and() || v;
    }
    return v;
  };
  const v = or();
  return at === t.length && v;
}

/** source -> { licence, ships, note } from components.tsv. */
function registry(text = read(COMPONENTS)) {
  return new Map(rows(text).map(([source, licence, ships, pin, note]) => [source.trim(), {
    licence: licence.trim(), ships: ships.trim(), pin: (pin ?? '').trim(), note: (note ?? '').trim(),
  }]));
}

/**
 * source -> the version a build takes it at, from the build files [inputs]
 * name (as buildFiles() reads them) and the pub [packages]: a pod's locked
 * version, a URL's ${VAR}s expanded from the CMake set() beside it, the
 * commit a git URL fetches, a pub file's package version. A source whose own
 * text names its version has none.
 */
function pinsOf({ files = buildFiles().map(([rel]) => rel), packages = null } = {}) {
  const out = new Map();
  for (const rel of files) {
    const text = read(rel);
    if (rel.endsWith('Podfile.lock')) {
      const locked = text.match(/^PODS:\n((?: {2}.*\n?)*)/m)?.[1] ?? '';
      for (const m of locked.matchAll(/^ {2}- "?([^\s/"(]+)(?:\/[^\s(]+)? \(([^)]+)\)/gm)) out.set(`pod:${m[1]}`, m[2]);
      continue;
    }
    const vars = new Map([...text.matchAll(/^\s*set\(\s*(\w+)\s+"?([^"\s)]+)"?\s*\)/gm)].map((m) => [m[1], m[2]]));
    for (const source of urls(text)) {
      const url = source.slice(4);
      if (/\$\{\w+\}/.test(url)) {
        out.set(source, url.replace(/\$\{(\w+)\}/g, (all, v) => vars.get(v) ?? all));
      } else if (url.endsWith('.git')) {
        const after = text.slice(text.indexOf(url)).split('\n').slice(0, 20).join('\n');
        const sha = after.match(/\b[0-9a-f]{40}\b/)?.[0];
        if (sha) out.set(source, sha);
      }
    }
  }
  for (const [name, { dir }] of packages ?? []) {
    const version = path.basename(dir.replace(/\/$/, '')).replace(`${name}-`, '');
    out.set(`pub:${name}`, version);
  }
  return out;
}

/**
 * Each row of [components] whose pin is not the build's ([pins]): a pub
 * file's row is pinned to its package's version.
 */
function staleReads(components, { pins }) {
  const out = [];
  for (const [source, { pin }] of components) {
    const key = source.startsWith('pub:') ? source.split('/')[0] : source;
    if (source.startsWith('gradle:')) continue;
    const want = pins.get(key) ?? '';
    if (pin !== want) out.push(`${source}: read at ${pin || '(no pin)'}, built at ${want || '(no pin)'}`);
  }
  return out;
}

/** The pods a Podfile.lock resolves that no plugin's or local path names. */
function pods(lock) {
  const section = (name) => {
    const m = lock.match(new RegExp(`^${name}:\\n((?:  .*\\n?)*)`, 'm'));
    return m ? m[1] : '';
  };
  const external = new Set([...section('EXTERNAL SOURCES').matchAll(/^ {2}([^\s:]+):$/gm)].map((m) => m[1]));
  const sdk = new Set(['Flutter', 'FlutterMacOS']);
  const names = [...section('PODS').matchAll(/^ {2}- "?([^\s/"(]+)/gm)].map((m) => m[1]);
  return [...new Set(names)].filter((n) => !external.has(n) && !sdk.has(n)).map((n) => `pod:${n}`);
}

/** The Maven coordinates an app build.gradle depends on, group:artifact. */
function gradle(text) {
  const re = /^\s*(?:implementation|api|runtimeOnly|compileOnly|coreLibraryDesugaring)\s*\(?\s*['"]([^:'"]+):([^:'"]+):/gm;
  return [...text.matchAll(re)].map((m) => `gradle:${m[1]}:${m[2]}`);
}

/** Every http(s) URL outside a comment. */
function urls(text) {
  return [...text
    .split('\n')
    .map((l) => l.replace(/(?:^|\s)(?:#|\/\/)(?:\s.*)?$/, ''))
    .join('\n')
    .matchAll(/https?:\/\/[^\s"'`)\\]+/g)].map((m) => `url:${m[0]}`);
}

/** The app's build files a component can come in by, each with what it pulls in. */
function buildFiles() {
  const out = [];
  for (const rel of ['ios/Podfile.lock', 'macos/Podfile.lock']) {
    if (exists(rel)) out.push([rel, pods]);
  }
  out.push(['android/app/build.gradle', gradle]);
  for (const rel of files('linux', /\.(cmake|txt)$/)) {
    if (/CMakeLists\.txt$|\.cmake$/.test(rel) && !rel.includes('/flutter/')) out.push([rel, urls]);
  }
  for (const rel of ['snap/snapcraft.yaml', 'rust/webspace_adblock/build.rs']) {
    if (exists(rel)) out.push([rel, urls]);
  }
  if (exists('linux/flatpak')) {
    for (const rel of files('linux/flatpak', /\.ya?ml$/)) out.push([rel, urls]);
  }
  return out.map(([rel, readOf]) => [rel, readOf(read(rel))]);
}

// What pub builds of a package into the app: all of it but these
// directories, at any depth. No app build takes a package's tests or
// examples, and this app builds for no Windows.
const NOT_SHIPPED = new Set(['test', 'tests', 'example', 'examples', 'integration_test', 'benchmark', 'benchmarks', 'windows']);

// Paths from a package's root that no app build takes: a DevTools
// extension, which Flutter's DevTools loads beside the app, never into it.
const NOT_SHIPPED_PATHS = new Set(['extension/devtools']);

function shippedFiles(dir, rel = '') {
  const out = [];
  for (const e of fs.readdirSync(path.join(dir, rel), { withFileTypes: true })) {
    const at = rel ? `${rel}/${e.name}` : e.name;
    if (e.isDirectory() && !NOT_SHIPPED.has(e.name) && !NOT_SHIPPED_PATHS.has(at) && !e.name.startsWith('.')) out.push(...shippedFiles(dir, at));
    else if (e.isFile()) out.push(at);
  }
  return out;
}

/**
 * The pub packages the app's dependencies reach, its dev dependencies left
 * out: name -> { dir, files } with every file pub builds of it. The Flutter
 * SDK's own packages are left out too: their notices are the engine's, which
 * LicenseRegistry shows, and its row is url:https://github.com/flutter/flutter.git.
 * Null before `flutter pub get`.
 */
function pubPackages(tool = abs('.dart_tool')) {
  const graphAt = path.join(tool, 'package_graph.json');
  const configAt = path.join(tool, 'package_config.json');
  if (!fs.existsSync(graphAt) || !fs.existsSync(configAt)) return null;
  const graph = JSON.parse(fs.readFileSync(graphAt, 'utf8'));
  const config = JSON.parse(fs.readFileSync(configAt, 'utf8'));
  const sdk = fileURLToPath(config.flutterRoot) + path.sep;
  const dirOf = new Map(config.packages.map((p) => [p.name, fileURLToPath(new URL(p.rootUri, pathToFileURL(configAt)))]));
  const deps = new Map(graph.packages.map((p) => [p.name, p.dependencies ?? []]));
  const reached = new Set();
  const stack = [...deps.get(graph.roots[0])];
  while (stack.length) {
    const name = stack.pop();
    if (reached.has(name)) continue;
    reached.add(name);
    stack.push(...deps.get(name));
  }
  const out = new Map();
  for (const name of [...reached].sort()) {
    const dir = dirOf.get(name);
    if (!dir.startsWith(sdk)) out.set(name, { dir, files: shippedFiles(dir) });
  }
  return out;
}

/** The build files of [packages] that can pull a component in: a plugin's Gradle file, its CMake files. */
function pluginBuildFiles(packages) {
  const out = [];
  for (const [name, { dir, files: shipped }] of packages) {
    for (const rel of shipped) {
      const readOf = /^android\/build\.gradle(?:\.kts)?$/.test(rel) ? gradle
        : /(?:^|\/)CMakeLists\.txt$|\.cmake$/.test(rel) ? urls : null;
      if (readOf) out.push([`pub:${name}/${rel}`, readOf(fs.readFileSync(path.join(dir, rel), 'utf8'))]);
    }
  }
  return out;
}

// A licence file by its name, wherever the word sits in it
// (UNICODE_LICENSE.txt, FMDB_LICENSE.txt), and not a source file.
const LICENCE_FILE = /(?:^|[^a-z])(?:licen[cs]e|copying)(?![a-z])[^/]*$/i;
const CODE = /\.(?:dart|c|cc|cpp|h|hpp|m|mm|swift|kt|java|js|py|rs|go)$/i;
const isLicenceFile = (rel) => LICENCE_FILE.test(path.basename(rel)) && !CODE.test(rel);
const GNU_HEADING = /^\s*GNU (?:LESSER |LIBRARY |AFFERO )?GENERAL PUBLIC LICENSE\s*$/im;
// A notice read as letters and digits only, so one split across comment
// lines (`//`, ` *`, `#`) reads as one sentence, as build.rs reads a crate's.
const GNU_NOTICE = /general public license.*as published by the free software foundation/;
const GNU_DATED = [
  'gnu general public license version 2 june 1991',
  'gnu general public license version 3 29 june 2007',
  'gnu library general public license version 2 june 1991',
  'gnu lesser general public license version 2 1 february 1999',
  'gnu lesser general public license version 3 29 june 2007',
  'gnu affero general public license version 3 19 november 2007',
];
const SPDX_TAG = /SPDX-License-Identifier:\s*([^\r\n*]+)/g;

const RESTRICTED = [
  ['CC-BY-SA', /attribution[- ]sharealike/],
  ['CC-BY-NC', /attribution[- ]noncommercial|non[- ]commercial use only/],
  ['CC-BY-ND', /attribution[- ]no ?derivatives/],
  ['EPL', /eclipse public license/],
  ['CDDL', /common development and distribution license/],
  ['EUPL', /european union public licen[cs]e/],
  ['SSPL', /server side public license/],
  ['OSL', /open software license/],
  ['BUSL', /business source license/],
  ['Commons-Clause', /commons clause/],
  ['Elastic', /elastic license/],
];

/**
 * The licences a licence file grants, by the sentences each is known by, and
 * the copyleft and restricted families it names; the GNU licences are read
 * apart, from every file, by their heading or notice.
 */
function licencesIn(text) {
  const t = text.toLowerCase().replace(/\s+/g, ' ');
  const out = new Set();
  if (t.includes('permission is hereby granted, free of charge, to any person obtaining a copy')) out.add('MIT');
  if (t.includes('redistribution and use in source and binary forms')) {
    if (t.includes('all advertising materials mentioning')) out.add('BSD-4-Clause');
    else if (/neither the names? of|names of its contributors may be used|name of the copyright holder nor/.test(t)) out.add('BSD-3-Clause');
    else out.add('BSD-2-Clause');
  }
  if (t.includes('apache license') && t.includes('version 2.0')) out.add('Apache-2.0');
  if (t.includes('mozilla public license') && /version 2\.0|v\. 2\.0/.test(t)) out.add('MPL-2.0');
  if (t.includes('boost software license')) out.add('BSL-1.0');
  if (t.includes('free and unencumbered software released into the public domain')) out.add('Unlicense');
  if (t.includes("this software is provided 'as-is', without any express or implied")) out.add('Zlib');
  if (t.includes('permission to use, copy, modify, and/or distribute this software for any purpose with or without fee')) out.add('ISC');
  // Licences beside a permissive one that would otherwise pass unread: each
  // is an id licences.tsv does not list, so the file needs a row read by hand.
  for (const [id, re] of RESTRICTED) if (re.test(t)) out.add(id);
  return out;
}

/** The head of a file, or null for a binary one. */
function textOf(file, { whole }) {
  const fd = fs.openSync(file, 'r');
  try {
    const size = whole ? fs.fstatSync(fd).size : Math.min(fs.fstatSync(fd).size, 1 << 18);
    const buf = Buffer.alloc(size);
    fs.readSync(fd, buf, 0, size, 0);
    return buf.subarray(0, 8000).includes(0) ? null : buf.toString('utf8');
  } finally {
    fs.closeSync(fd);
  }
}

/**
 * What a file of a pub package says it may ship under, if anything: the
 * GNU licences by their heading or notice, SPDX tags, and a licence file's
 * licences. A registry row for the file, `pub:<package>/<path>`, is the
 * licence read by hand and replaces these readings.
 */
function readingOf(file, { licenceFile }) {
  const text = textOf(file, { whole: licenceFile });
  if (text === null) return [];
  const out = [];
  const words = text.toLowerCase().replace(/[^a-z0-9]+/g, ' ');
  if (GNU_HEADING.test(text) || GNU_NOTICE.test(words) || GNU_DATED.some((h) => words.includes(h))) {
    out.push('a GNU licence');
  }
  for (const m of text.matchAll(SPDX_TAG)) out.push(m[1].replace(/\s*-->.*$/, '').trim());
  if (licenceFile) {
    const known = [...licencesIn(text)];
    out.push(known.length ? known.join(' AND ') : '');
  }
  return out;
}

/**
 * Every shipped file of [packages] whose licence does not let it link, as
 * `pub:<package>/<path>: <licence>`; an unknown licence reads as empty.
 */
function pubRefusals(packages, components) {
  const out = [];
  for (const [name, { dir, files: shipped }] of packages) {
    for (const rel of shipped) {
      const key = `pub:${name}/${rel}`;
      const row = components.get(key);
      const licences = row ? [row.licence] : readingOf(path.join(dir, rel), { licenceFile: isLicenceFile(rel) });
      const ships = row ? row.ships : 'linked';
      for (const l of licences) {
        if (!allows(l, { ships, component: key })) out.push(`${key}: ${l || '(no licence it knows)'}`);
      }
    }
  }
  return out;
}

const ATTRIBUTIONS = 'openspec/specs/legal/attributions.tsv';

/** notice -> the assets/licenses texts that carry it, from attributions.tsv. */
function attributions(text = read(ATTRIBUTIONS)) {
  return new Map(rows(text).map(([source, assets]) => [source.trim(), assets.trim().split(/\s+/)]));
}

const words = (text) => text.toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();

/** The SPDX ids an expression names, its operators left out. */
const idsOf = (expression) => tokens(expression).filter((t) => !/^(AND|OR|WITH|\(|\))$/.test(t));

/**
 * The notices [packages] ship that Flutter's collection of each root LICENSE
 * leaves out: a licence file elsewhere in a package, and a package whose
 * SPDX tags name licences its root LICENSE does not grant.
 */
function pubNotices(packages) {
  const out = [];
  for (const [name, { dir, files }] of packages) {
    const root = files.includes('LICENSE') ? licencesIn(fs.readFileSync(path.join(dir, 'LICENSE'), 'utf8')) : new Set();
    const tagged = new Set();
    for (const rel of files) {
      const file = path.join(dir, rel);
      if (rel !== 'LICENSE' && isLicenceFile(rel)) out.push({ key: `pub:${name}/${rel}`, file });
      const text = textOf(file, { whole: false });
      if (text === null) continue;
      for (const m of text.matchAll(SPDX_TAG)) {
        for (const id of idsOf(m[1].replace(/\s*-->.*$/, '').trim())) tagged.add(id);
      }
    }
    const uncovered = [...tagged].filter((id) => !root.has(id)).sort();
    if (uncovered.length) out.push({ key: `pub:${name}`, ids: uncovered });
  }
  return out;
}

/**
 * Each notice of [packages] the licences page would not show, as one line: a
 * notice with neither a row in attributions.tsv nor a `build` row in
 * [components], an asset a row names that does not exist, a licence file
 * whose text is in none of its assets, a package's SPDX licence none of its
 * assets grants, and a row for a notice nothing ships.
 */
function attributionGaps(packages, { components, attributed = attributions() }) {
  const out = [];
  const notices = pubNotices(packages);
  for (const n of notices) {
    if (components.get(n.key)?.ships === 'build') continue;
    const assets = attributed.get(n.key);
    if (!assets) {
      out.push(`${n.key}: no row in ${ATTRIBUTIONS}`);
      continue;
    }
    const texts = assets.filter((a) => {
      if (!exists(a)) out.push(`${n.key}: ${a} does not exist`);
      return exists(a);
    }).map((a) => read(a));
    if (n.file) {
      const want = words(fs.readFileSync(n.file, 'utf8'));
      if (!texts.some((t) => words(t).includes(want))) out.push(`${n.key}: its text is in none of ${assets.join(', ')}`);
    }
    if (n.ids) {
      const granted = new Set(texts.flatMap((t) => [...licencesIn(t)]));
      const missing = n.ids.filter((id) => !granted.has(id));
      if (missing.length) out.push(`${n.key}: ${missing.join(', ')} granted by none of ${assets.join(', ')}`);
    }
  }
  const keys = new Set(notices.map((n) => n.key));
  for (const key of attributed.keys()) {
    if (key.startsWith('pub:') && !keys.has(key)) out.push(`${key}: no package ships it`);
  }
  return out;
}

/**
 * The pods [components] lists whose licence is more than their own (the
 * libraries they compile in beside it) with no row in attributions.tsv
 * naming texts that exist, and pod rows for no pod in [components].
 */
function podAttributionGaps({ components, attributed = attributions() }) {
  const out = [];
  for (const [source, { licence }] of components) {
    if (!source.startsWith('pod:') || !/ AND /.test(licence)) continue;
    const assets = attributed.get(source);
    if (!assets) out.push(`${source}: ${licence}, and no row in ${ATTRIBUTIONS}`);
    else for (const a of assets) if (!exists(a)) out.push(`${source}: ${a} does not exist`);
  }
  for (const key of attributed.keys()) {
    if (key.startsWith('pod:') && !components.has(key)) out.push(`${key}: no pod in ${COMPONENTS}`);
  }
  return out;
}

/** source -> the build files that pull it in. */
function pullSites(inputs = buildFiles()) {
  const out = new Map();
  for (const [rel, sources] of inputs) {
    for (const s of sources) {
      const at = out.get(s) ?? new Set();
      at.add(rel);
      out.set(s, at);
    }
  }
  return out;
}

module.exports = {
  LICENCES, COMPONENTS, CASES, rows, policy, allows, registry, pinsOf, staleReads, pods, gradle, urls, pullSites,
  buildFiles, shippedFiles, pubPackages, pluginBuildFiles, pubRefusals, licencesIn, readingOf,
  ATTRIBUTIONS, attributions, pubNotices, attributionGaps, podAttributionGaps,
};
