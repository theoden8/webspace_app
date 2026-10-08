// A wake with no Flutter engine starts one (NOTIF-005-A, NOTIF-016).
//
// The worker used to return success when no engine was reachable, and the
// spec accepted it, so after Android reclaimed the process no notification
// site was checked until the user opened the app. The emulator tier's
// Scenario P2 drives the real leg; this pins the wiring it depends on, so a
// change that quietly restores the no-op fails without an emulator:
//
// - the worker starts WorkerFlutterEngine when dispatch finds no engine, and
//   destroys it when the wake ends;
// - the activity stops that engine before building its own, so two copies of
//   the app's Dart state never share the process;
// - the engine gets the plugins the app needs at startup, from the same list
//   the activity uses (without the container plugin the app falls back to
//   legacy isolation, one cookie jar for every site);
// - it tells `main` it runs for a wake, and startup then builds no site
//   webview, since Android's blockers could not find one with no activity;
// - the refresh waits for Dart to install its handler.

const test = require('node:test');
const assert = require('node:assert/strict');
const { read, blockAfter } = require('./helpers/source');

const kt = 'android/app/src/main/kotlin/org/codeberg/theoden8/webspace';

const worker = read(`${kt}/NotificationRefreshWorker.kt`);
const engine = read(`${kt}/WorkerFlutterEngine.kt`);
const plugins = read(`${kt}/EnginePlugins.kt`);
const activity = read(`${kt}/MainActivity.kt`);
const taskPlugin = read(`${kt}/BackgroundTaskAndroidPlugin.kt`);
const main = read('lib/main.dart');
const launch = read('lib/services/launch_context.dart');
const service = read('lib/services/background_task_service.dart');
const lifecycle = read('lib/controllers/app_lifecycle_controller.dart');
const background = read('lib/controllers/background_sites_controller.dart');

test('the worker starts an engine when none is reachable, and stops it after', () => {
  const miss = worker.indexOf('if (!NotificationRefreshDispatcher.dispatch(onComplete)) {');
  assert.notEqual(miss, -1, 'the worker must branch on a failed dispatch');
  const branch = worker.slice(miss, worker.indexOf('\n        }\n', miss));
  assert.match(branch, /WorkerFlutterEngine\.start\(applicationContext\)/,
    'with no engine the worker must start one, not return');
  const beforeStart = branch.slice(0, branch.indexOf('WorkerFlutterEngine.start('));
  assert.doesNotMatch(beforeStart, /return@withContext/,
    'the no-engine branch must not end the work before starting an engine');
  assert.match(worker,
    /finally \{\s*if \(startedEngine\) WorkerFlutterEngine\.stop\(/,
    'the engine the worker started must be destroyed however the wake ends');
});

test('the activity stops the worker engine before building its own', () => {
  const at = activity.indexOf('override fun provideFlutterEngine(');
  assert.notEqual(at, -1, 'MainActivity must override provideFlutterEngine');
  const body = activity.slice(at, activity.indexOf('\n    }\n', at));
  assert.match(body, /WorkerFlutterEngine\.stop\(/);
  assert.match(body, /return null/,
    'the activity builds its own engine; adopting the worker one would skip its activity plugins');
});

test('both engines register the same activity-free plugins', () => {
  for (const name of ['WebSpaceContainerPlugin', 'WebInterceptPlugin',
    'BackgroundTaskAndroidPlugin', 'ProxyRelayPlugin']) {
    assert.match(plugins, new RegExp(`${name}\\(`), `EnginePlugins must build ${name}`);
  }
  assert.match(activity, /EnginePlugins\(this, flutterEngine, this\)/);
  assert.match(engine, /EnginePlugins\(app, engine, activity = null\)/);
  assert.doesNotMatch(activity, /WebSpaceContainerPlugin\(flutterEngine\)/,
    'the activity must take the container plugin from EnginePlugins, not build its own');
});

test('main knows it runs for a wake and builds no site webview', () => {
  const arg = /kBackgroundWakeArg = '([^']+)'/.exec(launch);
  assert.ok(arg, 'launch_context.dart must name the argument');
  assert.match(engine, new RegExp(`BACKGROUND_WAKE_ARG = "${arg[1]}"`),
    'the worker engine must pass the argument main looks for');
  assert.match(engine, /executeDartEntrypoint\(\s*DartExecutor\.DartEntrypoint\.createDefault\(\),\s*listOf\(BACKGROUND_WAKE_ARG\)/);
  assert.match(main, /void main\(\[List<String> args = const \[\]\]\) async \{\s*launchedForBackgroundWake = args\.contains\(kBackgroundWakeArg\);/);
  assert.match(main, /if \(!_sites\.useContainers && !launchedForBackgroundWake\) \{/,
    'the legacy pre-paint auto-load must not run in the wake engine');
  assert.match(main,
    /if \(_sites\.useContainers && !launchedForBackgroundWake\) \{\s*unawaited\(DeferredStartupEngine\.autoLoadNotificationSites/,
    'the container auto-load must not run in the wake engine');
});

test('the refresh waits for Dart to install its handler', () => {
  assert.match(taskPlugin, /"backgroundRefreshReady" -> \{\s*NotificationRefreshDispatcher\.dartReady\(channel\)/);
  assert.match(taskPlugin, /if \(dartReady\) invoke\(c\) else waitingForDart = true/);
  const init = service.slice(service.indexOf('void initialize() {'),
    service.indexOf('Future<void> _announceReady()'));
  assert.ok(init.indexOf('setMethodCallHandler') < init.indexOf('_announceReady()'),
    'Dart must announce readiness only after its handler is installed');
});

// Android has one proxy override. A user who reopens the app mid-wake moves
// it to the site they open, and a headless check still loading would follow.
test('a return to the foreground closes the wake headless checks', () => {
  assert.match(blockAfter(lifecycle, 'void _foregrounded() {', null, 'app_lifecycle_controller.dart'),
    /background\.noteResumed\(\)/);
  assert.match(blockAfter(background, 'void noteResumed() {', null, 'background_sites_controller.dart'),
    /_activeWake\?\.closeAllHeadless\(\)/);
  const body = blockAfter(background, 'Future<WakeSkip?> openHeadless(String siteId) async {', null,
    'background_sites_controller.dart');
  assert.equal((body.match(/if \(_foreground\)/g) || []).length, 2,
    'openHeadless must refuse before building a check and drop one finished after the app came back');
});
