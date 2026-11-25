// The native half of the "Home Shortcut" dialogs (HS-010), held to the Dart
// half test/shortcut_dialog_test.dart drives: on iOS the dialog's platform
// view is the AppIntents ShortcutsUIButton, whose tap reaches Dart on the
// view's own channel; on macOS "Open Shortcuts" opens shortcuts:// through
// NSWorkspace; no undocumented per-app Shortcuts deep link anywhere.
//
// Rung 5: Swift compiles only on a Mac, and nothing ties a Dart view type or
// channel name to the Swift string that answers it; a source gate is the
// earliest point a drift between them is seen.
const test = require('node:test');
const assert = require('node:assert/strict');
const { read } = require('./helpers/source');

const PLUGIN = 'ios/Runner/ShortcutsPlugin.swift';
const DIALOG = 'lib/widgets/shortcut_prompts.dart';
const IOS_DELEGATE = 'ios/Runner/AppDelegate.swift';
const MAC_DELEGATE = 'macos/Runner/AppDelegate.swift';
const MAC_PROJECT = 'macos/Runner.xcodeproj/project.pbxproj';

/** What a drift between the Swift and Dart halves looks like, by source. */
function linkProblems({ swift, dart, iosDelegate }) {
  const problems = [];
  const native = /static let viewType = "([^"]+)"/.exec(swift)?.[1];
  const flutter = /static const _viewType = '([^']+)'/.exec(dart)?.[1];
  if (!native || native !== flutter) {
    problems.push(`the dialog builds view ${flutter}, the Runner answers ${native}`);
  }
  if (!/register\(\s*ShortcutsLinkViewFactory\(messenger: messenger\),\s*withId: ShortcutsLinkViewFactory\.viewType\s*\)/
    .test(iosDelegate)) {
    problems.push('the iOS Runner registers no ShortcutsLinkViewFactory');
  }
  if (!/ShortcutsUIButton\(/.test(swift)) problems.push('the view holds no ShortcutsUIButton');
  if (!/name: "\\\(ShortcutsLinkViewFactory\.viewType\)_\\\(viewId\)"/.test(swift)) {
    problems.push('the view talks on another channel than <viewType>_<id>');
  }
  if (!/channel\.invokeMethod\("tapped"/.test(swift)) problems.push('the button\'s tap is not sent');
  if (!/MethodChannel\('\$\{_viewType\}_\$id'\)/.test(dart)
      || !/call\.method == 'tapped'\) onOpened\(\)/.test(dart)) {
    problems.push('the dialog does not close on the view\'s tap');
  }
  return problems;
}

test('the iOS dialog\'s Shortcuts button is the native one, its tap reaching '
    + 'the dialog (HS-010)', () => {
  const sources = { swift: read(PLUGIN), dart: read(DIALOG), iosDelegate: read(IOS_DELEGATE) };
  assert.deepEqual(linkProblems(sources), []);

  const renamed = { ...sources, dart: sources.dart.replace(/shortcuts-link'/, "shortcuts-button'") };
  assert.deepEqual(linkProblems(renamed), [
    'the dialog builds view org.codeberg.theoden8.webspace/shortcuts-button, '
      + 'the Runner answers org.codeberg.theoden8.webspace/shortcuts-link',
  ]);
  const silent = { ...sources, swift: sources.swift.replace('invokeMethod("tapped"', 'invokeMethod("tap"') };
  assert.deepEqual(linkProblems(silent), ['the button\'s tap is not sent']);
});

/** The `pinShortcut` answer on macOS: the body of `openShortcutsApp`. */
function macOpen(swift) {
  const body = /private func openShortcutsApp\([^)]*\) \{([\s\S]*?)\n {2}\}\n/.exec(swift)?.[1] ?? '';
  const mac = /#if canImport\(FlutterMacOS\)([\s\S]*?)#else/.exec(body)?.[1] ?? '';
  return { body, mac };
}

test('macOS opens the Shortcuts app through NSWorkspace, and no per-app deep '
    + 'link is used (HS-010)', () => {
  const swift = read(PLUGIN);
  assert.match(swift, /case "pinShortcut":\s*openShortcutsApp\(result: result\)/);
  const { body, mac } = macOpen(swift);
  assert.match(body, /URL\(string: "shortcuts:\/\/"\)/, 'pinShortcut opens another URL');
  assert.match(mac, /NSWorkspace\.shared\.open\(url\)/, 'macOS does not open it through NSWorkspace');
  assert.match(read(MAC_DELEGATE), /ShortcutsPlugin\(messenger:/, 'the macOS Runner starts no ShortcutsPlugin');
  assert.match(read(MAC_PROJECT), /ShortcutsPlugin\.swift in Sources/, 'the macOS Runner does not compile the plugin');
  for (const file of [PLUGIN, DIALOG, IOS_DELEGATE, MAC_DELEGATE]) {
    assert.doesNotMatch(read(file), /shortcuts:\/\/(?:x-callback-url\/|app-shortcut|[a-z-]+\?bundleID=)/,
      `${file} uses an undocumented Shortcuts deep link`);
  }
});
