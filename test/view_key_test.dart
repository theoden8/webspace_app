import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/view_key.dart';

import 'helpers/fake_platform_controller.dart';

// A view's key is minted unique and memoised on the platform controller, so
// every callback of one view reads the same key and two views never read the
// same one.

inapp.InAppWebViewController _wrap(inapp.PlatformInAppWebViewController p) =>
    inapp.InAppWebViewController.fromPlatform(platform: p);

void main() {
  test('every callback of one view reads the same key', () {
    // The plugin hands a fresh wrapper per callback over the one platform
    // controller; the key is memoised on the platform, not the wrapper.
    final platform = FakePlatformController();
    expect(ViewKey.of(_wrap(platform)), ViewKey.of(_wrap(platform)));
  });

  test('two views read different keys', () {
    expect(ViewKey.of(_wrap(FakePlatformController())),
        isNot(ViewKey.of(_wrap(FakePlatformController()))));
  });
}
