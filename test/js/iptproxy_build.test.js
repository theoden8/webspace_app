// LICENSE-001 and TOR-016 gate over go/iptproxy, the build of the bridge
// transports the Apple app links and of the lyrebird the Linux bundle ships
// beside tor (TOR-027). lyrebird's GPL parts are deleted before anything reads
// its tree and nothing brings them back, meek_lite stays registered with
// go/meekutls's round tripper in its GPL file's place, every source is pinned
// by commit and SHA-256, both builds are checked as the framework is, and CI
// builds and checks what the Podfiles link.
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
const MEEKUTLS = 'go/meekutls/meekutls.go';
const SOURCES = ['IPTPROXY', 'LYREBIRD', 'DNSTT', 'MEEK'];
// What of lyrebird is GPL, and the packages among them.
const GPL = ['internal/x25519ell2', 'transports/meeklite/transport.go', 'LICENSE-GPL3.txt'];
const GPL_PACKAGES = ['lyrebird/internal/x25519ell2'];
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

function buildProblems(sh, meekutls = read(MEEKUTLS)) {
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
  }
  for (const p of GPL_PACKAGES) {
    if (!packages.includes(p)) out.push(`GPL_PACKAGES does not refuse ${p}`);
  }
  if (paths.includes('transports/meeklite') || packages.includes('lyrebird/transports/meeklite')) {
    out.push('all of meek_lite is deleted, where only transport.go is GPL');
  }

  // meek_lite: go/meekutls's file in transport.go's place, which check holds
  // the tree and the framework to.
  const placed = sh.match(/^MEEKUTLS=(\S+)$/m)?.[1];
  const symbol = quoted(sh, 'MEEKUTLS_SYMBOL');
  if (placed !== 'transports/meeklite/meekutls.go') out.push('go/meekutls/meekutls.go is not put in meeklite');
  const method = symbol.match(/^lyrebird\/transports\/meeklite\.\(\*(\w+)\)\.(\w+)$/);
  if (!method || !meekutls.includes(`\nfunc (rt *${method[1]}) ${method[2]}(`)) {
    out.push(`MEEKUTLS_SYMBOL ${symbol} names no method ${MEEKUTLS} declares`);
  }
  if (!/^package meeklite$/m.test(meekutls) || !/\nfunc newRoundTripper\(/.test(meekutls)) {
    out.push(`${MEEKUTLS} does not declare meeklite's newRoundTripper, which meek.go calls`);
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
  const copy = prepare.indexOf('cp "$meekutls/meekutls.go" "$src/lyrebird/$MEEKUTLS"');
  if (copy < 0 || (deletion >= 0 && copy < deletion) || copy > patch) {
    out.push('prepare does not put go/meekutls/meekutls.go in meeklite after the deletion');
  }

  const check = fn(sh, 'check');
  const scan = fn(sh, 'scan');
  if (!/grep -E "\$GPL_PACKAGES"/.test(check)) out.push('check does not refuse a compiled GPL package');
  if (!/grep -q 'webspace\.local\/hiddenkey' "\$bin" \|\|/.test(scan)) out.push('scan does not show it can see package paths');
  if (!/! grep -qE "\$GPL_PACKAGES" "\$bin" \|\| die/.test(scan)) out.push('scan does not refuse a GPL package in a binary');
  if (!/grep -qF "\$MEEKUTLS_SYMBOL" "\$bin" \|\|/.test(scan)) out.push('scan does not look for go/meekutls in a binary');
  if (!/for b in \$bins; do\n\t+scan "\$b"/.test(check)) out.push('check does not scan the built framework');
  if (!/\[ ! -e "\$meek\/transport\.go" \][^\n]*\n[^\n]*die "lyrebird's GPL transport\.go/.test(check)) {
    out.push('check does not refuse a meek_lite with lyrebird\'s transport.go');
  }
  if (!/grep -q "\/\$MEEKUTLS\\\$" "\$work\/files\.compiled" \|\|/.test(check)) {
    out.push('check does not refuse a meek_lite built without go/meekutls');
  }
  if (!/cmp -s "\$meekutls\/meekutls\.go" "\$src\/lyrebird\/\$MEEKUTLS" \|\|/.test(check)) {
    out.push('check does not hold the tree\'s meekutls.go to go/meekutls\'s');
  }
  if (!/for dir in "\$meekutls" "\$here\/interop"; do/.test(check)) {
    out.push('check does not hold go/meekutls and interop/ to the framework\'s module versions');
  }
  const targets = quoted(sh, 'TARGETS').split(/\s+/);
  for (const t of ['ios/arm64/ios', 'ios/amd64/ios', 'darwin/arm64/macos', 'darwin/amd64/macos']) {
    if (!targets.includes(t)) out.push(`check does not list ${t}`);
  }

  // lyrebird's own program for Linux: listed by check as the framework is,
  // built from the tree check passed, and held by check-lyrebird to the same
  // scan, licences.tsv and its notice.
  if (sh.match(/^LYREBIRD_CMD=(\S+)$/m)?.[1] !== `${MODULE}/cmd/lyrebird`) out.push('LYREBIRD_CMD is not lyrebird\'s program');
  const linux = quoted(sh, 'LINUX_TARGETS').split(/\s+/);
  for (const t of ['linux/amd64', 'linux/arm64']) {
    if (!linux.includes(t)) out.push(`check does not list lyrebird for ${t}`);
  }
  if (!/for t in \$LINUX_TARGETS; do[^]*?go list -deps -f "\$1" "\$LYREBIRD_CMD"/.test(fn(sh, 'list'))) {
    out.push('check does not list what lyrebird\'s program compiles');
  }
  const program = fn(sh, 'build_lyrebird');
  const built = program.search(/\(cd "\$src\/IPtProxy\.go" && CGO_ENABLED=1 go build -trimpath \\\n(\t*[^\n]*\\\n)*\t*-o "\$dest\/pluggable_transports\/lyrebird" "\$LYREBIRD_CMD"\)/);
  if (built < 0) out.push('build.sh lyrebird does not build LYREBIRD_CMD in IPtProxy\'s module');
  const before = program.slice(0, Math.max(built, 0));
  if (!/\n\tprepare\n\tcheck\n/.test(before)) out.push('build.sh lyrebird builds before prepare and check');
  if (!/notices "\$dest\/docs\/lyrebird\.txt" [^]*\$\(program_modules "\$dest\/pluggable_transports\/lyrebird"\)/.test(program)) {
    out.push('lyrebird\'s notice is not of the modules it compiled');
  }
  if (program.indexOf('check_lyrebird "$dest"') < built) out.push('build.sh lyrebird does not check what it built');
  const held = fn(sh, 'check_lyrebird');
  for (const [rule, why] of [
    [/awk '\$1 == "path" \{ print \$2 \}'\)" = "\$LYREBIRD_CMD" \] \|\|/, 'is lyrebird\'s program'],
    [/\n\tscan "\$bin"\n/, 'passes scan'],
    [/grep -qxF "\$module" \|\|\n\t+die/, 'compiles only modules licences.tsv names'],
    [/index\(\$0, m\) == 1[^\n]*"\$notice" \|\|\n\t+die/, 'carries each module\'s notice'],
    [/grep -q "\^Go \$version, " "\$notice" \|\| die/, 'carries Go\'s notice'],
    [/\[ "\$ran" = "lyrebird \$\{LYREBIRD_TAG#lyrebird-\}" \] \|\| die/, 'runs here as the pinned version'],
  ]) {
    if (!rule.test(held)) out.push(`check-lyrebird does not check that the program ${why}`);
  }
  const bind = fn(sh, 'bind');
  if (bind.indexOf('check') < 0 || bind.indexOf('check') > bind.indexOf('gomobile bind')) {
    out.push('bind does not check before it binds');
  }
  if (/@latest|go run golang\.org\/x\/mobile/.test(sh)) out.push('gomobile is not the one go.sum pins');
  if (!/go install \S* ?golang\.org\/x\/mobile\/cmd\/gomobile golang\.org\/x\/mobile\/cmd\/gobind/.test(one)) {
    out.push('gomobile and gobind are not installed from the module');
  }
  if (!/^export GOFLAGS='-mod=readonly -buildvcs=false'$/m.test(sh)) {
    out.push('Go may change go.mod or go.sum, or read the checkout\'s git state');
  }
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
  if (has('lyrebird/transports/transports.go', 'removed', /meeklite/)) {
    out.push('the patch takes meek_lite out of lyrebird\'s registry');
  }
  if (has('IPtProxy.go/controller.go', 'removed', /MeekLite/)) {
    out.push('the patch takes MeekLite out of IPtProxy');
  }
  for (const [module, dir] of [[MODULE, '../lyrebird'], ['webspace.local/hiddenkey', '../hiddenkey']]) {
    if (!has('IPtProxy.go/go.mod', 'added', new RegExp(`^replace ${module.replace(/\./g, '\\.')} => ${dir.replace(/\./g, '\\.')}$`))) {
      out.push(`IPtProxy's go.mod does not take ${module} from ${dir}`);
    }
  }
  for (const [path, { added }] of Object.entries(files)) {
    for (const line of added) {
      if (/x25519ell2"/.test(line)) out.push(`${path} adds ${line.trim()}`);
    }
  }
  return out;
}

/** The repo paths the shell function `inputs` hashes. */
function buildInputs(sh) {
  return [...joined(fn(sh, 'inputs')).matchAll(/"\$(here|hiddenkey|meekutls)\/([^"]+)"/g)]
    .map(([, dir, file]) => `go/${dir === 'here' ? 'iptproxy' : dir}/${file}`)
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
  if (!/working-directory: go\/meekutls\n\s+run: go test /.test(body)) {
    out.push('the bridge-transports job does not test go/meekutls');
  }
  if (!/LYREBIRD_UPSTREAM: .*\/go\/iptproxy\/build\/bin\/lyrebird-upstream\n/.test(body)) {
    out.push('the interop test is not given the upstream server');
  }
  if (!/MEEK_SERVER: .*\/go\/iptproxy\/build\/bin\/meek-server\n/.test(body)) {
    out.push('the interop test is not given meek-server');
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

test('LICENSE-001 the patch takes the handshake to hiddenkey and leaves meek_lite in (TOR-016)', () => {
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
    'go/iptproxy/interop/meek_interop_test.go',
    'go/iptproxy/interop/obfs4_interop_test.go',
    'go/iptproxy/interop/pt_server_test.go',
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

  caught(buildProblems(swap(sh, ' transports/meeklite/transport.go ', ' ')), 'transport.go kept');
  caught(buildProblems(swap(sh, ' transports/meeklite/transport.go ', ' transports/meeklite ')), 'all of meek_lite deleted');
  caught(buildProblems(swap(sh, "GPL_PACKAGES='lyrebird/internal/x25519ell2'", "GPL_PACKAGES=''")), 'x25519ell2 compiled unrefused');
  caught(buildProblems(swap(sh, '\tcp "$meekutls/meekutls.go" "$src/lyrebird/$MEEKUTLS"\n', '')), 'meekutls.go not copied');
  caught(buildProblems(swap(sh, '(*meekutlsRoundTripper).RoundTrip', '(*roundTripper).RoundTrip')), 'a symbol meekutls.go lacks');
  caught(buildProblems(sh, read(MEEKUTLS).replace('func newRoundTripper(', 'func newUTLSRoundTripper(')),
    'meekutls.go without what meek.go calls');
  caught(buildProblems(swap(sh, 'grep -qF "$MEEKUTLS_SYMBOL" "$bin"', 'true')), 'a framework without meekutls');
  caught(buildProblems(swap(sh, '! grep -qE "$GPL_PACKAGES" "$bin" || die', 'true || die')), 'a binary with x25519ell2');
  caught(buildProblems(swap(sh, '\t\tscan "$b"\n', '\t\t:\n')), 'the framework unscanned');
  caught(buildProblems(swap(sh, "LINUX_TARGETS='linux/amd64 linux/arm64'", "LINUX_TARGETS='linux/amd64'")),
    'lyrebird for arm64 unlisted');
  caught(buildProblems(swap(sh, 'go list -deps -f "$1" "$LYREBIRD_CMD"', 'true')), 'lyrebird\'s program unlisted');
  caught(buildProblems(swap(sh, '\tprepare\n\tcheck\n\trm -rf "$dest/', '\tprepare\n\trm -rf "$dest/')),
    'lyrebird built unchecked');
  caught(buildProblems(swap(sh, '-o "$dest/pluggable_transports/lyrebird" "$LYREBIRD_CMD"',
    '-o "$dest/pluggable_transports/lyrebird" ./cmd/lyrebird')), 'lyrebird built from its own module');
  caught(buildProblems(swap(sh, '$(program_modules "$dest/pluggable_transports/lyrebird")',
    '$(listed)')), 'a notice of other modules than it compiled');
  caught(buildProblems(swap(sh, '\tcheck_lyrebird "$dest"\n', '')), 'lyrebird shipped unchecked');
  caught(buildProblems(swap(sh, '[ "$ran" = "lyrebird ${LYREBIRD_TAG#lyrebird-}" ] || die', 'true || die')),
    'lyrebird never run');
  caught(buildProblems(swap(sh, '\tscan "$bin"\n\tmodules=', '\tmodules=')), 'lyrebird unscanned');
  caught(buildProblems(swap(sh, 'grep -qxF "$module" ||', 'true ||')), 'lyrebird with an unlisted module');
  caught(buildProblems(swap(sh, '"$notice" ||\n\t\t\tdie "$notice carries no notice for $module"',
    '"$notice" || true')), 'a module without its notice');
  caught(buildProblems(swap(sh, '[ ! -e "$meek/transport.go" ] && ', '')), 'transport.go in the tree unrefused');
  caught(buildProblems(swap(sh, 'for dir in "$meekutls" "$here/interop"; do', 'for dir in "$meekutls"; do')),
    'interop on other versions');
  caught(buildProblems(sh.replace(/^LYREBIRD_SHA256=\S+$/m, 'LYREBIRD_SHA256=')), 'an unpinned lyrebird');
  caught(buildProblems(sh.replace(/^DNSTT_COMMIT=\S+$/m, 'DNSTT_COMMIT=master')), 'dnstt by branch');
  caught(buildProblems(swap(sh, '"$DNSTT_COMMIT" "$DNSTT_SHA256"', '"$DNSTT_COMMIT" ""')), 'dnstt fetched unchecked');
  caught(buildProblems(swap(sh, '\t\trm -rf "${src:?}/lyrebird/$p"\n', '')), 'no deletion');
  caught(buildProblems(swap(sh, '[ "$got" = "$want" ] || die', ':')), 'a tree never hashed');
  caught(buildProblems(swap(sh, 'go install', 'go run golang.org/x/mobile/cmd/gomobile@latest; go install')),
    'gomobile@latest');
  caught(buildProblems(swap(sh, "export GOFLAGS='-mod=readonly", "export GOFLAGS='-mod=mod")), 'go.sum rewritten');
  caught(buildProblems(swap(sh, " -buildvcs=false'", "'")), 'Go reading the checkout\'s git state');
  const prepare = fn(sh, 'prepare');
  caught(buildProblems(swap(sh, prepare, prepare.replace('\tpatch -d', '\t(cd "$src/IPtProxy.go" && go list ./...)\n\tpatch -d'))),
    'go before the checks');

  caught(patchProblems(`${diff}--- a/lyrebird/transports/transports.go\n+++ b/lyrebird/transports/transports.go\n`
    + '@@ -91,1 +90,0 @@\n-\t\tnew(meeklite.Transport),\n'), 'meek taken out of the registry');
  caught(patchProblems(swap(diff, '+\tx25519ell2 "webspace.local/hiddenkey"\n', '')), 'no hiddenkey import');
  caught(patchProblems(`${diff}+\t"${MODULE}/internal/x25519ell2"\n`), 'x25519ell2 added back');
  caught(patchProblems(`${diff}--- a/IPtProxy.go/controller.go\n+++ b/IPtProxy.go/controller.go\n`
    + '@@ -101,1 +100,0 @@\n-\tMeekLite = "meek_lite"\n'), 'MeekLite dropped');

  caught(ciProblems({ ...ci, action: swap(ci.action, "'go/iptproxy/iptproxy.patch', ", '') }), 'a cache key short of an input');
  caught(ciProblems({ ...ci, action: swap(ci.action, 'run: |\n        sh go/iptproxy/build.sh check', 'run: |\n        true') }),
    'no check after the build');
  caught(ciProblems({ ...ci, action: swap(ci.action, ", 'go/meekutls/meekutls.go'", '') }), 'a cache key without meekutls.go');
  caught(ciProblems({ ...ci, workflow: swap(ci.workflow, '          MEEK_SERVER:', '          MEEK_SERVER_UNUSED:') }),
    'the meek interop without its server');
  caught(ciProblems({ ...ci, workflow: swap(ci.workflow, 'working-directory: go/meekutls\n', 'working-directory: go/hiddenkey\n') }),
    'meekutls untested');
  caught(ciProblems({ ...ci, podfiles: { ...ci.podfiles, 'ios/Podfile': swap(ci.podfiles['ios/Podfile'],
    "pod 'IPtProxy', :path => '../go/iptproxy'", "pod 'IPtProxy', '5.5.1'") } }), 'the trunk pod');
});
