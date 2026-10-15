// The iOS Runner runs under the UIScene lifecycle, which the iOS 27 SDK
// requires (https://flutter.dev/to/uiscene-migration).
//
// Under it the scene's storyboard starts the engine after launch, and UIKit
// sends URLs, shortcuts and foreground changes to the scene. App delegate code
// written for the old lifecycle still compiles and never runs: a
// `window?.rootViewController` lookup in didFinishLaunching finds no window,
// so every channel behind it goes unregistered, and `application(_:open:)` is
// never called. Neither the compiler nor Xcode says a delegate method is dead
// under scenes, so this reads the source (rung 5).

const test = require('node:test');
const assert = require('node:assert/strict');
const { read, code } = require('./helpers/source');
const { blockAfter } = require('./helpers/dart_blocks');

const rel = 'ios/Runner/AppDelegate.swift';
const delegate = code(read(rel));
const plist = read('ios/Runner/Info.plist');
const launch = blockAfter(delegate, 'didFinishLaunchingWithOptions launchOptions', '-> Bool', rel);
const engine = blockAfter(delegate, 'func didInitializeImplicitFlutterEngine(', null, rel);

test('Info.plist declares one scene, built from the storyboard that starts the engine', () => {
  // Its presence is also what flutter_tools checks before warning that the
  // app has not migrated.
  assert.match(plist, /<key>UIApplicationSceneManifest<\/key>/);
  assert.match(plist, /<key>UIApplicationSupportsMultipleScenes<\/key>\s*<false\/>/);
  assert.match(plist, /<key>UISceneDelegateClassName<\/key>\s*<string>FlutterSceneDelegate<\/string>/);
  assert.match(plist, /<key>UISceneStoryboardFile<\/key>\s*<string>Main<\/string>/);
});

test('plugins and channels are set up when the engine starts, not at launch', () => {
  assert.match(delegate, /class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate/);
  assert.match(engine, /GeneratedPluginRegistrant\.register\(with: engineBridge\.pluginRegistry\)/);
  for (const shape of [/GeneratedPluginRegistrant/, /messenger/i, /Plugin\(/, /\.attach\(/]) {
    assert.doesNotMatch(launch, shape, `didFinishLaunching runs before the engine exists: ${shape}`);
  }
});

test('the app delegate reads no window and no launch options', () => {
  assert.doesNotMatch(delegate, /\bwindow\b|rootViewController/,
    'the app delegate has no window under scenes; set up in didInitializeImplicitFlutterEngine');
  assert.doesNotMatch(launch, /launchOptions\?\[|launchOptions!\[/,
    'launch options are nil under scenes; a launch URL arrives on the scene');
});

test('no app delegate method that scenes replace', () => {
  // Flutter's migration table: each has a scene counterpart, and UIKit stops
  // calling the app delegate's.
  for (const replaced of [
    /open url: URL/,
    /continue userActivity:/,
    /performActionFor shortcutItem:/,
    /func applicationDidBecomeActive\(/,
    /func applicationWillResignActive\(/,
    /func applicationWillEnterForeground\(/,
    /func applicationDidEnterBackground\(/,
  ]) {
    assert.doesNotMatch(delegate, replaced, `${rel} overrides a method UIKit no longer calls: ${replaced}`);
  }
});

test('what must happen before launch ends still does', () => {
  // BGTaskScheduler throws for a task whose handler was registered late, and
  // a notification answered before the delegate is set is lost.
  assert.match(delegate, /private let backgroundTask = BackgroundTaskPlugin\(\)/,
    'the refresh plugin must exist at launch to take a task before there is an engine');
  assert.match(launch, /backgroundTask\.registerLaunchHandler\(\)/);
  assert.match(launch, /UNUserNotificationCenter\.current\(\)\.delegate = /);
});

test('webspace:// URLs reach the share-intent plugin through the scene', () => {
  const scene = engine.indexOf('.addSceneDelegate(shareIntent)');
  assert.notEqual(scene, -1, 'the share-intent plugin must be a scene delegate, where iOS sends URLs');
  assert.ok(scene < engine.indexOf('GeneratedPluginRegistrant'),
    'the scene offers a URL to its plugins in registration order; the first to claim it ends the offer');
  assert.match(delegate, /private let shareIntent = ShareIntentPlugin\(\)/,
    'an engine holds its scene delegates weakly; the app delegate keeps the plugin');
});
