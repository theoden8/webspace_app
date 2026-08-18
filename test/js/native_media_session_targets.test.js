// iOS media-session target gate (BGAUDIO-010, native concurrency).
//
// `MPRemoteCommandCenter` is a process-wide singleton and its targets outlive
// nothing on their own: a handler added twice fires twice, and one never
// removed keeps a dead plugin on the hook. The plugin therefore keeps every
// target it added in `commandTargets`, adds only when that list is empty, and
// removes exactly those on teardown. The handler body also hops onto the main
// queue — the command centre documents no queue, and a Flutter channel must be
// spoken to from the platform thread.
//
// No iOS SDK/Xcode in this repo's Dart+JS tiers, so this is a structural guard
// (same shape as native_bgtask_completion_funnel).

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const repoRoot = path.resolve(__dirname, '..', '..');
const rel = 'ios/Runner/MediaSessionPlugin.swift';
const src = fs.readFileSync(path.join(repoRoot, rel), 'utf8');
// Comments explain why the forbidden shapes are forbidden, so match on code.
const code = src
  .split('\n')
  .filter((l) => !l.trim().startsWith('//') && !l.trim().startsWith('///'))
  .join('\n');

test('every added target is retained for removal', () => {
  assert.match(src, /private var commandTargets: \[\(MPRemoteCommand, Any\)\] = \[\]/,
    `${rel} must keep the handles addTarget returns`);
  assert.match(src, /commandTargets\.append\(\(command, target\)\)/,
    'each addTarget result must be appended to commandTargets');
  assert.match(src, /command\.removeTarget\(target\)/,
    'teardown must remove the retained handles, not guess at them');
});

test('registration is idempotent', () => {
  // Reports arrive on every play/pause; without this a long listening session
  // stacks one handler per report and a single tap fires all of them.
  assert.match(src, /guard commandTargets\.isEmpty else \{ return \}/,
    'registerCommands must no-op while targets are already registered');
});

test('the transport callback hops onto the main queue', () => {
  const addTarget = src.slice(src.indexOf('command.addTarget'));
  const body = addTarget.slice(0, addTarget.indexOf('commandTargets.append'));
  assert.match(body, /DispatchQueue\.main\.async/,
    'the remote-command handler must hop to main before invoking the channel');
  assert.ok(
    body.indexOf('DispatchQueue.main.async') < body.indexOf('invokeMethod'),
    'the channel call must be inside the main-queue hop, not before it',
  );
});

test('the play command activates the session before the page is asked', () => {
  // WebKit cannot start playback against an inactive session, and the tap that
  // gets here is usually the one meant to bring the app back from suspension.
  const hop = code.slice(code.indexOf('DispatchQueue.main.async'));
  const body = hop.slice(0, hop.indexOf('return .success'));
  assert.match(body, /if action == "play" \{\s*self\.activateSession\(\)/,
    'a play command must activate the audio session');
  assert.ok(
    body.indexOf('activateSession()') < body.indexOf('invokeMethod'),
    'activation must precede handing the command to the page',
  );
  assert.match(code, /try session\.setActive\(true\)/,
    'setting only the category leaves the process suspendable');
});

test('only play / pause / stop are registered', () => {
  // Dead buttons are worse than absent ones: next/previous have no universal
  // web mechanism, and togglePlayPause handled twice (ours + WebKit's own
  // targets) cancels itself out.
  const registered = [...src.matchAll(/\(center\.(\w+Command), "(\w+)"\)/g)]
    .map((m) => m[1]);
  assert.deepEqual(registered, ['playCommand', 'pauseCommand', 'stopCommand']);
  assert.ok(!/togglePlayPauseCommand/.test(code),
    'togglePlayPause is deliberately left to WebKit');
});

test('an interruption is observed and recovered from (BGAUDIO-011)', () => {
  // Nothing re-activates a session iOS deactivated for a call / Siri / another
  // app. Without this the audio never returns and every later transport tap
  // reaches an engine with no session to play into.
  assert.match(code, /AVAudioSession\.interruptionNotification/,
    'the plugin must observe interruptions');
  assert.match(code, /AVAudioSession\.mediaServicesWereResetNotification/,
    'a media-server restart takes the session and the Now Playing entry with it');
  const handler = code.slice(code.indexOf('func handleInterruption'));
  const body = handler.slice(0, handler.indexOf('func handleMediaServicesReset'));
  assert.match(body, /DispatchQueue\.main\.async/,
    'AVAudioSession posts on an arbitrary queue; plugin state lives on main');
  assert.match(body, /guard self\.publishing else/,
    'recovery must not activate a session or ask a page to play when we own nothing');
  assert.match(body, /options\.contains\(\.shouldResume\)/,
    'resume only when the system says the user expects playback back');
});

test('teardown clears the now-playing info, not just the targets', () => {
  const stop = src.slice(src.indexOf('private func stop(deactivate'));
  assert.match(stop, /unregisterCommands\(\)/);
  assert.match(stop, /center\.nowPlayingInfo = nil/,
    'stale Now Playing controls whose buttons reach nothing are the bug');
  // Ordinary teardown keeps the session: another loaded site may still be
  // sounding in the foreground. Giving it up is reserved for the explicit
  // `deactivate` call, which only arrives once every page has been paused.
  assert.match(stop, /guard deactivate else \{ return \}/,
    'the session release must sit behind the deactivate flag');
  const releases = (code.match(/setActive\(false/g) || []).length;
  assert.equal(releases, 1, 'exactly one place may release the session');
  assert.match(stop, /options: \.notifyOthersOnDeactivation/,
    'let whatever we interrupted resume');
});
