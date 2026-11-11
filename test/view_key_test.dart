import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/download_manager.dart';
import 'package:webspace/services/view_key.dart';

import 'helpers/fake_platform_controller.dart';

// ViewKey names one native webview for its life. DL-008 and SHARE-017 compare
// views by it, so two live views must never share a key and every callback of
// one view must read the same key. The key is minted unique, never
// identityHashCode (not unique: two live objects can share one and a value is
// reused after a collection). identityHashCode collisions cannot be forced in
// a Dart test, so the "no collision" guarantee rests on minting (pinned here as
// distinctness) plus a source gate for the hash mutant
// (test/js/view_key_mint.test.js, rung 5).

inapp.InAppWebViewController _wrap(inapp.PlatformInAppWebViewController p) =>
    inapp.InAppWebViewController.fromPlatform(platform: p);

void main() {
  test('every callback of one view reads the same key', () {
    // The plugin hands a fresh wrapper per callback over the one platform
    // controller, so the key is memoised on the platform, not the wrapper.
    final platform = FakePlatformController();
    expect(ViewKey.of(_wrap(platform)), ViewKey.of(_wrap(platform)));
  });

  test('two live views never share a key (DL-008, SHARE-017)', () {
    final a = ViewKey.of(_wrap(FakePlatformController()));
    final b = ViewKey.of(_wrap(FakePlatformController()));
    expect(a, isNot(b));
  });

  test('a stored download id holds the key value, not the controller', () {
    final platform = FakePlatformController();
    final view = ViewKey.of(_wrap(platform));
    final downloads = DownloadsService.instance;
    final task = downloads.start(filename: 'a.bin', view: view);
    addTearDown(() => downloads.dismiss(task.id));
    // The view the task carries is the minted String, not the platform object,
    // so download history (which outlives the view) cannot keep a dead
    // controller alive.
    expect(task.id.view, isA<String>());
    expect(identical(task.id.view, platform), isFalse);
    expect(task.id.view, view);
  });
}
