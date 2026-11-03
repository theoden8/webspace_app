// LICENSE-001 and TOR-016 gate over go/iptproxy, the build of the bridge
// transports the Apple app links. lyrebird's two GPL parts are deleted before
// anything reads its tree and nothing brings them back, meek_lite is not
// registered, every source is pinned by commit and SHA-256, and CI builds
// and checks what the Podfiles link.
//
// Rung 5: a shell script and a patch have no type, and the build runs only on
// a macOS runner. What Go actually compiles is held by `build.sh check`
// (go list over every target), which CI runs after the build.

const test = require('node:test');
const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const { REPO, read } = require('./helpers/source');

const BUILD = 'go/iptproxy/build.sh';
const PATCH = 'go/iptproxy/iptproxy.patch';
const ACTION = '.github/actions/apple-toolchain/action.yml';
const WORKFLOW = '.github/workflows/build-and-test.yml';
const PODFILES = ['ios/Podfile', 'macos/Podfile'];
const SOURCES = ['IPTPROXY', 'LYREBIRD', 'DNSTT'];
const GPL = ['internal/x25519ell2', 'transports/meeklite'];
const MODULE = 'gitlab.torproject.org/tpo/anti-censorship/pluggable-transports/lyrebird';

/** The body of shell function `name`, from its header to the closing brace. */
function fn(sh, name) {
  const start = sh.indexOf(`\n${name}() {\n`);
  if (start < 0) return '';
  const end = sh.indexOf('\n}\n', start);
  return sh.slice(start, end < 0 ? sh.length : end);
}

/** The script's lines with each backslash continuation joined. */
const joined = (sh) => sh.replace(/\\\n\s*/g, ' ');

/** The single-quoted value the script assigns to `name`, or ''. */
const quoted = (sh, name) => sh.match(new RegExp(`^${name}='([^']*)'$`, 'm'))?.[1] ?? '';

function buildProblems(sh) {
  const out = [];
  const one = joined(sh);
  for (const s of SOURCES) {
    if (!new RegExp(`^${s}_URL=https://\\S+\\.git$`, 'm').test(sh)) out.push(`${s}_URL is no https git URL`);
    if (!new RegExp(`^${s}_COMMIT=[0-9a-f]{40}$`, 'm').test(sh)) out.push(`${s}_COMMIT is no full commit id`);
    if (!new RegExp(`^${s}_SHA256=[0-9a-f]{64}$`, 'm').test(sh)) out.push(`${s}_SHA256 is no SHA-256`);
    if (!new RegExp(`\\bfetch [^\\n]*"\\$${s}_COMMIT"\\s+"\\$${s}_SHA256"`).test(one)) {
      out.push(`no fetch checks ${s} against its commit and SHA-256`);
    }
  }
  const fetch = fn(sh, 'fetch');
  const checkout = fetch.indexOf('checkout');
  const commit = fetch.indexOf('[ "$got" = "$commit" ] || die');
  const tree = fetch.indexOf('[ "$got" = "$want" ] || die');
  if (commit < 0 || commit > checkout) out.push('fetch does not refuse another commit before its checkout');
  if (tree < checkout) out.push('fetch does not refuse files of another SHA-256 after its checkout');

  const paths = quoted(sh, 'GPL_PATHS').split(/\s+/);
  const packages = quoted(sh, 'GPL_PACKAGES').split('|');
  for (const p of GPL) {
    if (!paths.includes(p)) out.push(`GPL_PATHS leaves ${p} in the tree`);
    if (!packages.includes(`lyrebird/${p}`)) out.push(`GPL_PACKAGES does not refuse lyrebird/${p}`);
  }
  const prepare = fn(sh, 'prepare');
  const deletion = prepare.search(/for p in \$GPL_PATHS; do[^]*?rm -rf "\$\{src:\?\}\/lyrebird\/\$p"/);
  const lastFetch = prepare.lastIndexOf('\tfetch ');
  const patch = prepare.indexOf('patch -d "$src"');
  if (deletion < 0) out.push('prepare does not delete GPL_PATHS');
  else if (deletion < lastFetch || deletion > patch) out.push('prepare deletes GPL_PATHS after the patch or before the fetch');
  if (/\bgo (build|list|install|run|test)\b/.test(prepare)) out.push('prepare runs go before its checks are done');
  if (!/grep -rlE "\$GPL_PACKAGES" "\$src"/.test(prepare.slice(patch))) {
    out.push('prepare does not refuse a tree that still imports a GPL package');
  }
  if (!/grep -rliE "\$GPL_TEXT" "\$src"/.test(prepare.slice(patch))) {
    out.push('prepare does not refuse a tree with a file naming a GNU licence');
  }

  const check = fn(sh, 'check');
  if (!/grep -E "\$GPL_PACKAGES"/.test(check)) out.push('check does not refuse a compiled GPL package');
  if (!/grep -qE "\$GPL_PACKAGES" "\$bin"/.test(check)) out.push('check does not scan the built framework');
  const targets = quoted(sh, 'TARGETS').split(/\s+/);
  for (const t of ['ios/arm64/ios', 'ios/amd64/ios', 'darwin/arm64/macos', 'darwin/amd64/macos']) {
    if (!targets.includes(t)) out.push(`check does not list ${t}`);
  }
  const bind = fn(sh, 'bind');
  if (bind.indexOf('check') < 0 || bind.indexOf('check') > bind.indexOf('gomobile bind')) {
    out.push('bind does not check before it binds');
  }
  if (/@latest|go run golang\.org\/x\/mobile/.test(sh)) out.push('gomobile is not the one go.sum pins');
  if (!/go install \S* ?golang\.org\/x\/mobile\/cmd\/gomobile golang\.org\/x\/mobile\/cmd\/gobind/.test(one)) {
    out.push('gomobile and gobind are not installed from the module');
  }
  if (!/^export GOFLAGS=-mod=readonly$/m.test(sh)) out.push('Go may change go.mod or go.sum');
  if (!/^: "\$\{GOTOOLCHAIN:=go\$\(cat "\$here\/\.go-version"\)\}"$/m.test(sh)) out.push('the Go is not .go-version');
  return out;
}

/** A unified diff as {path: {added, removed}}. */
function hunks(diff) {
  const files = {};
  let at = null;
  for (const line of diff.split('\n')) {
    const header = line.match(/^\+\+\+ b\/(\S+)/);
    if (header) {
      at = files[header[1]] = { added: [], removed: [] };
    } else if (at && line.startsWith('+')) {
      at.added.push(line.slice(1));
    } else if (at && line.startsWith('-') && !line.startsWith('--- ')) {
      at.removed.push(line.slice(1));
    }
  }
  return files;
}

function patchProblems(diff) {
  const out = [];
  const files = hunks(diff);
  const has = (path, side, re) => (files[path]?.[side] ?? []).some((l) => re.test(l));
  if (!has('lyrebird/common/ntor/ntor.go', 'removed', new RegExp(`"${MODULE}/internal/x25519ell2"`))
      || !has('lyrebird/common/ntor/ntor.go', 'added', /^\tx25519ell2 "webspace\.local\/hiddenkey"$/)) {
    out.push('the ntor handshake does not import hiddenkey in place of x25519ell2');
  }
  if (!has('lyrebird/transports/transports.go', 'removed', /^\t\tnew\(meeklite\.Transport\),$/)
      || !has('lyrebird/transports/transports.go', 'removed', new RegExp(`"${MODULE}/transports/meeklite"`))) {
    out.push('meeklite is still registered in lyrebird');
  }
  if (!has('IPtProxy.go/controller.go', 'removed', /^\tMeekLite = "meek_lite"$/)) {
    out.push('IPtProxy still names MeekLite');
  }
  for (const [module, dir] of [[MODULE, '../lyrebird'], ['webspace.local/hiddenkey', '../hiddenkey']]) {
    if (!has('IPtProxy.go/go.mod', 'added', new RegExp(`^replace ${module.replace(/\./g, '\\.')} => ${dir.replace(/\./g, '\\.')}$`))) {
      out.push(`IPtProxy's go.mod does not take ${module} from ${dir}`);
    }
  }
  for (const [path, { added }] of Object.entries(files)) {
    for (const line of added) {
      if (/x25519ell2"|meeklite|MeekLite|meek_lite/.test(line)) out.push(`${path} adds ${line.trim()}`);
    }
  }
  return out;
}

/** The repo paths the shell function `inputs` hashes. */
function buildInputs(sh) {
  return [...joined(fn(sh, 'inputs')).matchAll(/"\$(here|hiddenkey)\/([^"]+)"/g)]
    .map(([, dir, file]) => `go/${dir === 'here' ? 'iptproxy' : 'hiddenkey'}/${file}`)
    .sort();
}

function ciProblems({ sh, action, workflow, podfiles }) {
  const out = [];
  if (!/uses: actions\/setup-go@v\d+\s+with:\s+go-version-file: go\/iptproxy\/\.go-version/.test(action)) {
    out.push('the Apple toolchain does not take its Go from go/iptproxy/.go-version');
  }
  const build = action.indexOf('run: sh go/iptproxy/build.sh\n');
  const check = action.indexOf('sh go/iptproxy/build.sh check');
  if (build < 0) out.push('the Apple toolchain does not build IPtProxy');
  if (check < build) out.push('the Apple toolchain does not check IPtProxy after building it');
  const key = action.match(/key: iptproxy-\$\{\{ runner\.os \}\}-\$\{\{ hashFiles\(([^)]*)\) \}\}/);
  const keyed = key ? [...key[1].matchAll(/'([^']+)'/g)].map((m) => m[1]).sort() : [];
  if (JSON.stringify(keyed) !== JSON.stringify(buildInputs(sh))) {
    out.push(`the cache is keyed on ${keyed.join(', ')}, the build on ${buildInputs(sh).join(', ')}`);
  }
  const job = workflow.slice(workflow.indexOf('\n  bridge-transports:\n'));
  const body = job.slice(0, job.slice(1).search(/\n {2}[a-z][a-z-]*:\n/) + 1);
  for (const step of ['sh go/iptproxy/build.sh check', 'sh go/iptproxy/build.sh upstream', 'go test -count=1']) {
    if (!body.includes(step)) out.push(`the bridge-transports job does not run ${step}`);
  }
  if (!/LYREBIRD_UPSTREAM: .*\/go\/iptproxy\/build\/bin\/lyrebird-upstream\n/.test(body)) {
    out.push('the interop test is not given the upstream server');
  }
  for (const [rel, podfile] of Object.entries(podfiles)) {
    if (!/^ {2}pod 'IPtProxy', :path => '\.\.\/go\/iptproxy'$/m.test(podfile)) out.push(`${rel} does not link go/iptproxy`);
    if (/pod 'IPtProxy', '/.test(podfile)) out.push(`${rel} takes IPtProxy from trunk, whose framework is GPL`);
    const ensure = podfile.indexOf('\nensure_iptproxy_built\n');
    if (ensure < 0 || ensure > podfile.indexOf("\ntarget 'Runner' do")) out.push(`${rel} installs before it builds IPtProxy`);
  }
  return out;
}

const sh = read(BUILD);
const diff = read(PATCH);
const ci = {
  sh,
  action: read(ACTION),
  workflow: read(WORKFLOW),
  podfiles: Object.fromEntries(PODFILES.map((rel) => [rel, read(rel)])),
};

test('LICENSE-001 lyrebird\'s GPL parts are deleted before anything reads its tree', () => {
  assert.deepEqual(buildProblems(sh), []);
});

test('LICENSE-001 the patch takes the handshake to hiddenkey and meek out (TOR-016)', () => {
  assert.deepEqual(patchProblems(diff), []);
});

test('TOR-016 CI builds and checks the framework both Podfiles link', () => {
  assert.deepEqual(ciProblems(ci), []);
});

test('nothing fetched or built under go/iptproxy is committed', () => {
  const kept = execFileSync('git', ['ls-files', '--cached', '--others', '--exclude-standard', 'go/iptproxy'],
    { cwd: REPO, encoding: 'utf8' }).split('\n').filter(Boolean).sort();
  assert.deepEqual(kept, [
    'go/iptproxy/.gitignore',
    'go/iptproxy/.go-version',
    'go/iptproxy/IPtProxy.podspec',
    BUILD,
    'go/iptproxy/interop/go.mod',
    'go/iptproxy/interop/go.sum',
    'go/iptproxy/interop/obfs4_interop_test.go',
    PATCH,
    'go/iptproxy/licences.tsv',
  ].sort(), 'a file here other than the inputs: a fetched tree or a build output is a derivative');
  assert.match(read('go/iptproxy/.go-version'), /^\d+\.\d+\.\d+\n$/, 'the Go is an exact release');
});

test('each rule catches the mistake it is for', () => {
  const swap = (text, from, to) => {
    assert.ok(text.includes(from), `the planted mistake no longer applies: ${from}`);
    return text.replace(from, to);
  };
  const caught = (problems, what) => assert.ok(problems.length > 0, `${what} went uncaught`);

  caught(buildProblems(swap(sh, ' transports/meeklite ', ' ')), 'meeklite kept');
  caught(buildProblems(swap(sh, "|lyrebird/transports/meeklite'", "'")), 'meeklite compiled unrefused');
  caught(buildProblems(sh.replace(/^LYREBIRD_SHA256=\S+$/m, 'LYREBIRD_SHA256=')), 'an unpinned lyrebird');
  caught(buildProblems(sh.replace(/^DNSTT_COMMIT=\S+$/m, 'DNSTT_COMMIT=master')), 'dnstt by branch');
  caught(buildProblems(swap(sh, '"$DNSTT_COMMIT" "$DNSTT_SHA256"', '"$DNSTT_COMMIT" ""')), 'dnstt fetched unchecked');
  caught(buildProblems(swap(sh, '\t\trm -rf "${src:?}/lyrebird/$p"\n', '')), 'no deletion');
  caught(buildProblems(swap(sh, '[ "$got" = "$want" ] || die', ':')), 'a tree never hashed');
  caught(buildProblems(swap(sh, 'go install', 'go run golang.org/x/mobile/cmd/gomobile@latest; go install')),
    'gomobile@latest');
  caught(buildProblems(swap(sh, 'export GOFLAGS=-mod=readonly', 'export GOFLAGS=-mod=mod')), 'go.sum rewritten');
  const prepare = fn(sh, 'prepare');
  caught(buildProblems(swap(sh, prepare, prepare.replace('\tpatch -d', '\t(cd "$src/IPtProxy.go" && go list ./...)\n\tpatch -d'))),
    'go before the checks');

  caught(patchProblems(swap(diff, '-\t\tnew(meeklite.Transport),\n', ' \t\tnew(meeklite.Transport),\n')),
    'meek still registered');
  caught(patchProblems(swap(diff, '+\tx25519ell2 "webspace.local/hiddenkey"\n', '')), 'no hiddenkey import');
  caught(patchProblems(`${diff}+\t"${MODULE}/transports/meeklite"\n`), 'meeklite added back');
  caught(patchProblems(swap(diff, '-\tMeekLite = "meek_lite"\n', ' \tMeekLite = "meek_lite"\n')), 'MeekLite kept');

  caught(ciProblems({ ...ci, action: swap(ci.action, "'go/iptproxy/iptproxy.patch', ", '') }), 'a cache key short of an input');
  caught(ciProblems({ ...ci, action: swap(ci.action, 'run: |\n        sh go/iptproxy/build.sh check', 'run: |\n        true') }),
    'no check after the build');
  caught(ciProblems({ ...ci, podfiles: { ...ci.podfiles, 'ios/Podfile': swap(ci.podfiles['ios/Podfile'],
    "pod 'IPtProxy', :path => '../go/iptproxy'", "pod 'IPtProxy', '5.5.1'") } }), 'the trunk pod');
});
