// Relay reachability probe must not run on the caller's thread.
//
// `start`/`startRouter` are reached from the method channel, which Flutter
// dispatches on the Android main thread. Binding a ServerSocket there is
// permitted; connecting a Socket is not -- Android throws
// NetworkOnMainThreadException. The probe catches every exception and reads
// the failure as "this address does not serve the device", so an inline
// connect makes each candidate address fail, takes the 127.0.0.1 fallback
// down with it, and the relay never binds: no credentialed proxy, and no
// router mode, on any device.
//
// The JVM tests cannot see this -- there is no BlockGuard off Android -- and
// the emulator tier costs ~50 minutes to say "failed to bind" with no
// reason, so this is a structural guard like native_bgtask_completion_funnel.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const repoRoot = path.resolve(__dirname, '..', '..');
const rel = 'android/app/src/main/kotlin/org/codeberg/theoden8/webspace/proxy/ProxyRelay.kt';
const src = fs.readFileSync(path.join(repoRoot, rel), 'utf8');

function selfConnectsBody() {
  const start = src.indexOf('private fun selfConnects(');
  assert.notStrictEqual(start, -1, 'selfConnects should still exist');
  // Balance braces from the opening one so the body is exact.
  let i = src.indexOf('{', start);
  let depth = 0;
  for (let j = i; j < src.length; j++) {
    if (src[j] === '{') depth++;
    else if (src[j] === '}' && --depth === 0) return src.slice(start, j + 1);
  }
  throw new Error('unbalanced selfConnects body');
}

test('the probe connects on a thread it spawns', () => {
  const body = selfConnectsBody();
  assert.match(
    body,
    /Thread\(/,
    'selfConnects must hand the connect to a Thread it starts; an inline '
      + 'connect throws NetworkOnMainThreadException and reads as unreachable',
  );
  assert.match(body, /\.start\(\)/, 'the probe thread must be started');
  assert.match(body, /\.join\(/, 'the caller must wait for the probe verdict');
});

test('the connect is inside the spawned thread, not before it', () => {
  const body = selfConnectsBody();
  const threadAt = body.indexOf('Thread(');
  const connectAt = body.indexOf('.connect(');
  assert.ok(connectAt > threadAt,
    'a connect() ahead of the Thread( would run on the caller again');
});

test('the guard is not vacuous', () => {
  // The pre-fix shape: a bare Socket().use { it.connect(...) } in the body
  // with no thread around it. Prove this file would reject that.
  const inlined = `
    private fun selfConnects(socket: ServerSocket): Boolean {
        val addr = InetSocketAddress(socket.inetAddress, socket.localPort)
        return try {
            Socket().use { probe ->
                probe.connect(addr, SELF_TEST_TIMEOUT_MS)
                true
            }
        } catch (e: Exception) {
            false
        }
    }`;
  assert.doesNotMatch(inlined, /Thread\(/);
});

test('binding itself stays on the calling thread', () => {
  // Only the probe moves. A bind is legal on the main thread, and doing it
  // off-thread would hand the caller a port before the socket exists.
  const start = src.indexOf('private fun bindLoopback(ip: String)');
  assert.notStrictEqual(start, -1);
  const body = src.slice(start, src.indexOf('private fun selfConnects(', start));
  assert.doesNotMatch(
    body,
    /Thread\(/,
    'bindLoopback should bind inline and delegate only the probe',
  );
});
