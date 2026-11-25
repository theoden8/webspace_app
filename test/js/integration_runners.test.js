// The desktop integration runners (openspec/specs/integration-tests): the
// Linux session's Secret Service (INTEG-001) and the macOS run through the
// bundle script (INTEG-009).
//
// Rung 5: these are shell scripts a person runs on a desktop, and a session
// that prompts for a keyring or an app that never builds shows up only there;
// their shape is read here so every PR holds it.
const test = require('node:test');
const assert = require('node:assert/strict');
const { read } = require('./helpers/source');

const SESSION = 'scripts/linux_test_session.sh';
const TOOLCHAIN = '.github/actions/linux-toolchain/action.yml';
const BUNDLE = 'scripts/integration_bundle.sh';
const PREPARE = 'scripts/prepare_macos_ci_debug.sh';

/** The `bash -c '...'` body the session runs under `dbus-run-session`. */
function busBody(session) {
  const m = /dbus-run-session -- bash -c '\n([\s\S]*?)\n {2}' bash "\$@"/.exec(session);
  return m ? m[1] : '';
}

/** What is wrong with the session's Secret Service (INTEG-001). */
function secretServiceProblems(session) {
  const problems = [];
  const body = busBody(session);
  const started = body.indexOf('pass_secret_service');
  const unlocked = body.indexOf('coll.unlock()');
  const command = body.indexOf('"$@"');
  if (command === -1) problems.push('the command does not run on the session bus');
  if (started === -1 || started > command) {
    problems.push('pass_secret_service is not on the bus before the command');
  }
  if (unlocked === -1 || unlocked > command) {
    problems.push('the default collection is not unlocked before the command');
  }
  if (!/print\(f\\"keyring: locked=\{coll\.is_locked\(\)\}/.test(body)) {
    problems.push('the keyring state is not logged');
  }
  if (/gnome-keyring-daemon/.test(session.replace(/^\s*#.*$/gm, ''))) {
    problems.push('gnome-keyring-daemon is started');
  }
  if (!/%no-protection/.test(session) || !/pass init "\$GPGID"/.test(session)) {
    problems.push('the pass store has no passphrase-less key');
  }
  return problems;
}

test('the Linux session claims the Secret Service and unlocks it before '
    + 'the command (INTEG-001)', () => {
  const session = read(SESSION);
  assert.deepEqual(secretServiceProblems(session), []);
  assert.match(read(TOOLCHAIN), /- name: Install pass-secret-service\n/,
    'the toolchain no longer installs pass-secret-service');

  const late = session.replace(
    /( {4}pass_secret_service > \/tmp\/pss\.log 2>&1 &\n)([\s\S]*?)( {4}"\$@" \|\| rc=\$\?\n)/,
    '$2$3$1');
  assert.notEqual(late, session, 'the plant changed nothing');
  assert.deepEqual(secretServiceProblems(late),
    ['pass_secret_service is not on the bus before the command']);
  const locked = session.replace(/\n {4}coll\.unlock\(\)/, '\n    pass');
  assert.deepEqual(secretServiceProblems(locked),
    ['the default collection is not unlocked before the command']);
});

/** A `case` arm's body for [label] in the function [name] of [script]. */
function caseArm(script, { name, label }) {
  const fn = new RegExp(`\\n${name}\\(\\) \\{\\n([\\s\\S]*?)\\n\\}\\n`).exec(script)?.[1] ?? '';
  const arm = new RegExp(`\\n\\s*${label}\\) ([^\\n]*;;)`).exec(fn);
  return arm ? arm[1] : null;
}

/** What is wrong with the macOS run through the bundle script (INTEG-009). */
function macRunProblems({ bundle, prepare }) {
  const problems = [];
  if (!/echo --ci/.test(caseArm(bundle, { name: 'device_flags', label: 'macos' }) ?? '')) {
    problems.push('macOS builds and tests without --ci');
  }
  if (!/macos\|linux\) echo "\$1"/.test(bundle)) problems.push('there is no macOS build target');
  if (!/fvm flutter build \$target --debug --no-pub[\s\S]*?\$\(device_flags "\$device"\) -t "\$entry"/.test(bundle)) {
    problems.push('the build is not one debug build of the entrypoint');
  }
  if (!/for f in "\$@"; do\n\s+echo "import '\.\.\/\.\.\/\$f' as/.test(bundle)) {
    problems.push('the entrypoint does not import every file');
  }
  const run = bundle.slice(bundle.indexOf('\n  run)'));
  if (!/WEBSPACE_INTEGRATION_LAUNCH="\$launch" fvm flutter drive[\s\S]*?--use-application-binary=/.test(run)) {
    problems.push('a file does not run in the built app');
  }
  if (!/fvm flutter test --no-pub "\$file" -d "\$device_id" \$\(device_flags "\$device"\)/.test(run)) {
    problems.push('a file the app cannot run has no flutter test of its own');
  }
  const unlock = prepare.indexOf('security unlock-keychain');
  const entitlements = prepare.indexOf('> macos/Runner/DebugProfile.entitlements');
  if (unlock === -1 || unlock > entitlements) problems.push('the login keychain is not unlocked first');
  const plist = prepare.slice(entitlements);
  for (const key of ['app-sandbox', 'cs.allow-jit', 'network.server', 'network.client']) {
    if (!plist.includes(`com.apple.security.${key}`)) problems.push(`the debug entitlements lack ${key}`);
  }
  for (const key of ['application-groups', 'keychain-access-groups']) {
    if (plist.includes(key)) problems.push(`the debug entitlements keep ${key}, which ad-hoc signing cannot back`);
  }
  return problems;
}

test('macOS runs every file through one --ci build, each in its own app '
    + 'process, after the keychain is unlocked (INTEG-009)', () => {
  const sources = { bundle: read(BUNDLE), prepare: read(PREPARE) };
  assert.deepEqual(macRunProblems(sources), []);

  const noCi = { ...sources, bundle: sources.bundle.replace('macos) echo --ci ;;', 'macos) ;;') };
  assert.notEqual(noCi.bundle, sources.bundle, 'the plant changed nothing');
  assert.deepEqual(macRunProblems(noCi), ['macOS builds and tests without --ci']);
  const signed = {
    ...sources,
    prepare: sources.prepare.replace('\t<key>com.apple.security.app-sandbox</key>',
      '\t<key>com.apple.security.application-groups</key>\n\t<array/>\n'
      + '\t<key>com.apple.security.app-sandbox</key>'),
  };
  assert.deepEqual(macRunProblems(signed),
    ['the debug entitlements keep application-groups, which ad-hoc signing cannot back']);
});
