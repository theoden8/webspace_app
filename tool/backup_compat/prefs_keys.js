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
const CALL = /\.(set|get)(Bool|Int|Double|StringList|String)\(\s*(?:'([^'$]+)'|([A-Za-z_]\w*))/g;
const READ_PREF_AS = /readPrefAs<(bool|int|double|String)>\(\s*\w+\s*,\s*(?:'([^'$]+)'|([A-Za-z_]\w*))/g;
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

/// The registry of backup-exported prefs, `key -> type`. Those keys are read
/// and written through `_readTypedPref` / `_writeTypedPref` with a runtime
/// key, so the call scan cannot see them.
function scanRegistry(sources, globals) {
  const app = Object.entries(sources).find(([f]) =>
    f.endsWith(path.join('settings', 'app_prefs.dart')));
  if (!app) return {};
  const src = app[1];
  const start = src.indexOf('kExportedAppPrefs = <String, Object>{');
  if (start < 0) return {};
  const end = src.indexOf('\n};', start);
  const block = src.slice(start, end);
  const declTypes = {};
  for (const s of Object.values(sources)) {
    for (const m of s.matchAll(TYPED_DECL)) declTypes[m[2]] = GETTER_TYPES[m[1]];
  }
  const out = {};
  const entry = /^\s*(?:'([^']+)'|([A-Za-z_]\w*))\s*:\s*(.+?),\s*(?:\/\/.*)?$/gm;
  for (const m of block.matchAll(entry)) {
    const key = m[1] ?? globals[m[2]];
    if (!key) continue;
    const value = m[3].trim();
    let type = null;
    if (/^(true|false)$/.test(value)) type = 'Bool';
    else if (/^-?\d+$/.test(value)) type = 'Int';
    else if (/^-?\d+\.\d+$/.test(value)) type = 'Double';
    else if (/^'.*'$/.test(value)) type = 'String';
    else if (/^<String>\[/.test(value)) type = 'StringList';
    else if (/^[A-Za-z_]\w*$/.test(value)) type = declTypes[value] ?? null;
    if (type) out[key] = type;
  }
  return out;
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
  const reads = {};
  const writes = {};
  const typedReads = [];
  for (const [file, src] of Object.entries(sources)) {
    const local = {};
    for (const m of src.matchAll(CONST)) local[m[1]] = m[2];
    const resolve = (literal, ident) => literal ?? local[ident] ?? globals[ident];
    for (const m of src.matchAll(CALL)) {
      const key = resolve(m[3], m[4]);
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
      const key = resolve(m[2], m[3]);
      if (key) add(reads, key, GETTER_TYPES[m[1]]);
    }
  }
  const registry = scanRegistry(sources, globals);
  for (const [key, type] of Object.entries(registry)) {
    add(reads, key, type);
    add(writes, key, type);
  }
  return { reads, writes, typedReads, registry };
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
