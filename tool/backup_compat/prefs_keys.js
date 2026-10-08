// Static map of the SharedPreferences keys a Dart tree reads and writes, and
// the type each is read or written as. Keys given as a string literal or as a
// `const String` in scope are resolved; keys built at runtime are not seen.
//
//   node tool/backup_compat/prefs_keys.js <lib dir>   prints what the tree writes
//
// generate.sh stores that output per release; test/js/prefs_key_history.test.js
// holds every release's writes against what lib/ reads today.
'use strict';

const fs = require('node:fs');
const path = require('node:path');

const GETTER_TYPES = { bool: 'Bool', int: 'Int', double: 'Double', String: 'String' };
// A key is a literal, `AppPref.<name>.key`, or an identifier.
const KEY = String.raw`(?:'([^'$]+)'|AppPref\.(\w+)\.key|([A-Za-z_]\w*))`;
const CALL = new RegExp(String.raw`\.(set|get)(Bool|Int|Double|StringList|String)\(\s*${KEY}`, 'g');
const READ_PREF_AS = new RegExp(String.raw`readPrefAs<(bool|int|double|String)>\(\s*\w+\s*,\s*(?:key:\s*)?${KEY}`, 'g');
const CONST = /(?:static\s+)?const\s+String\s+([A-Za-z_]\w*)\s*=\s*'([^'$]+)'/g;
const TYPED_DECL = /(?:const|final)\s+(String|bool|int|double)\s+([A-Za-z_]\w*)\s*=/g;

function dartFiles(dir) {
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      // gen_l10n output; never touches prefs.
      if (entry.name === 'gen') continue;
      out.push(...dartFiles(full));
    } else if (entry.name.endsWith('.dart')) {
      out.push(full);
    }
  }
  return out;
}

function lineOf(source, index) {
  return source.slice(0, index).split('\n').length;
}

function add(map, key, type) {
  (map[key] ??= new Set()).add(type);
}

function literalType(value) {
  if (/^(true|false)$/.test(value)) return 'Bool';
  if (/^-?\d+$/.test(value)) return 'Int';
  if (/^-?\d+\.\d+$/.test(value)) return 'Double';
  if (/^'.*'$/.test(value)) return 'String';
  if (/^<String>\[/.test(value)) return 'StringList';
  return null;
}

/// The registry of backup-exported prefs. Those keys are read and written
/// with a runtime key, so the call scan cannot see them. `types` is
/// `key -> type`, `names` the Dart name of each entry (`AppPref.<name>`), and
/// `legacy` the old keys an entry still reads, `key -> type`.
///
/// Since the `AppPref` enum each entry is `name('key', default)`, with an
/// optional `legacyKey: 'old'`; before it, an entry of the
/// `kExportedAppPrefs` map literal, which release trees still have.
function scanRegistry(sources, globals) {
  const none = { types: {}, names: {}, legacy: {} };
  const app = Object.entries(sources).find(([f]) =>
    f.endsWith(path.join('settings', 'app_prefs.dart')));
  if (!app) return none;
  const src = app[1];
  const enumStart = src.indexOf('enum AppPref<');
  if (enumStart >= 0) {
    const block = src.slice(enumStart, src.indexOf('const AppPref(', enumStart));
    const entry = /^\s*(\w+)\(\s*'([^']+)'\s*,\s*(?:fallback:\s*)?(true|false|-?\d+(?:\.\d+)?|'[^']*')\s*(?:,\s*legacyKey:\s*'([^']+)'\s*)?,?\s*\)\s*[,;]/gm;
    const out = { types: {}, names: {}, legacy: {} };
    for (const m of block.matchAll(entry)) {
      const type = literalType(m[3]);
      if (!type) continue;
      out.types[m[2]] = type;
      out.names[m[1]] = m[2];
      if (m[4]) out.legacy[m[4]] = type;
    }
    return out;
  }
  const start = src.indexOf('kExportedAppPrefs = <String, Object>{');
  if (start < 0) return none;
  const end = src.indexOf('\n};', start);
  const block = src.slice(start, end);
  const declTypes = {};
  for (const s of Object.values(sources)) {
    for (const m of s.matchAll(TYPED_DECL)) declTypes[m[2]] = GETTER_TYPES[m[1]];
  }
  const types = {};
  const entry = /^\s*(?:'([^']+)'|([A-Za-z_]\w*))\s*:\s*(.+?),\s*(?:\/\/.*)?$/gm;
  for (const m of block.matchAll(entry)) {
    const key = m[1] ?? globals[m[2]];
    if (!key) continue;
    const value = m[3].trim();
    const type = literalType(value)
      ?? (/^[A-Za-z_]\w*$/.test(value) ? declTypes[value] ?? null : null);
    if (type) types[key] = type;
  }
  return { ...none, types };
}

function scan(libDir) {
  const sources = {};
  for (const file of dartFiles(libDir)) sources[file] = fs.readFileSync(file, 'utf8');
  const globals = {};
  for (const src of Object.values(sources)) {
    for (const m of src.matchAll(CONST)) {
      if (!m[1].startsWith('_')) globals[m[1]] = m[2];
    }
  }
  const registry = scanRegistry(sources, globals);
  const reads = {};
  const writes = {};
  const typedReads = [];
  for (const [file, src] of Object.entries(sources)) {
    const local = {};
    for (const m of src.matchAll(CONST)) local[m[1]] = m[2];
    const resolve = (literal, pref, ident) =>
      literal ?? registry.names[pref] ?? local[ident] ?? globals[ident];
    for (const m of src.matchAll(CALL)) {
      const key = resolve(m[3], m[4], m[5]);
      if (!key) continue;
      if (m[1] === 'set') {
        add(writes, key, m[2]);
      } else {
        add(reads, key, m[2]);
        typedReads.push({
          key,
          type: m[2],
          at: `${path.relative(path.dirname(libDir), file)}:${lineOf(src, m.index)}`,
        });
      }
    }
    for (const m of src.matchAll(READ_PREF_AS)) {
      const key = resolve(m[2], m[3], m[4]);
      if (key) add(reads, key, GETTER_TYPES[m[1]]);
    }
  }
  for (const [key, type] of Object.entries(registry.types)) {
    add(reads, key, type);
    add(writes, key, type);
  }
  for (const [key, type] of Object.entries(registry.legacy)) add(reads, key, type);
  return { reads, writes, typedReads, registry: registry.types };
}

function sorted(map) {
  return Object.fromEntries(
    Object.keys(map).sort().map((k) => [k, [...map[k]].sort()]));
}

module.exports = { scan, sorted };

if (require.main === module) {
  const dir = process.argv[2];
  if (!dir) {
    console.error('usage: prefs_keys.js <lib dir>');
    process.exit(2);
  }
  process.stdout.write(`${JSON.stringify(sorted(scan(dir).writes), null, 2)}\n`);
}
