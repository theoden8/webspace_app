import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/desktop_mode_shim.dart';
import 'package:webspace/services/user_agent_classifier.dart';

void main() {
  group('buildDesktopModeShim', () {
    test('emits the reentrance guard so repeat frames do not re-wrap', () {
      // WebKit / Android WebView re-run initialUserScripts on every frame
      // load. Without this guard the matchMedia wrapper would wrap itself
      // and recurse infinitely.
      final js = buildDesktopModeShim(firefoxLinuxDesktopUserAgent);
      expect(js, contains('__ws_desktop_shim__'));
    });

    test('patches the core navigator/window surfaces', () {
      // If any of these drop out silently, the toggle stops working on
      // sites that gate on just one signal.
      final js = buildDesktopModeShim(firefoxWindowsDesktopUserAgent);
      expect(js, contains('userAgentData'));
      expect(js, contains('maxTouchPoints'));
      expect(js, contains('ontouchstart'));
      expect(js, contains('matchMedia'));
      expect(js, contains('viewport'));
      expect(js, contains('MutationObserver'));
    });

    test('makes navigator.userAgentData undefined (Firefox-style)', () {
      // Our spoofed UA is Firefox-shaped, and Firefox does not implement
      // the Client Hints API. Sites feature-detecting `userAgentData`
      // should see undefined — anything else is a tell.
      final js = buildDesktopModeShim(firefoxMacosDesktopUserAgent);
      expect(js, contains(
        "def('userAgentData', asNative(function() { return undefined; }, 'userAgentData'));"));
    });

    test('Linux UA emits "Linux x86_64" navigator.platform', () {
      final js = buildDesktopModeShim(firefoxLinuxDesktopUserAgent);
      expect(js, contains('"Linux x86_64"'));
    });

    test('macOS UA emits "MacIntel" navigator.platform', () {
      final js = buildDesktopModeShim(firefoxMacosDesktopUserAgent);
      expect(js, contains('"MacIntel"'));
    });

    test('Windows UA emits "Win32" navigator.platform', () {
      final js = buildDesktopModeShim(firefoxWindowsDesktopUserAgent);
      expect(js, contains('"Win32"'));
    });

    test('different UAs emit different shim payloads', () {
      // A refactor that parameterizes one platform value but forgets
      // another would collapse two shims to the same source — guard
      // against that.
      final linux = buildDesktopModeShim(firefoxLinuxDesktopUserAgent);
      final macos = buildDesktopModeShim(firefoxMacosDesktopUserAgent);
      final windows = buildDesktopModeShim(firefoxWindowsDesktopUserAgent);
      expect(linux, isNot(equals(macos)));
      expect(linux, isNot(equals(windows)));
      expect(macos, isNot(equals(windows)));
    });

    test('matchMedia wrapper covers pointer/hover desktop flips', () {
      final js = buildDesktopModeShim(firefoxLinuxDesktopUserAgent);
      // The wrapper must synthesize matches for the desktop side of each
      // pointer/hover query and non-matches for the mobile side; otherwise
      // responsive CSS still picks the mobile layout.
      expect(js, contains('pointer'));
      expect(js, contains('hover'));
      expect(js, contains('fine'));
      expect(js, contains('coarse'));
    });

    test('viewport rewrite uses a desktop-width content value', () {
      final js = buildDesktopModeShim(firefoxLinuxDesktopUserAgent);
      expect(js, contains('width=1280'));
    });

    test('does NOT spoof devicePixelRatio', () {
      // DPR is orthogonal to desktop-vs-mobile layout. Real retina
      // MacBooks and 4K Chrome desktops report dpr >= 2; pinning to 1
      // would downgrade image quality on any modern phone/tablet for no
      // layout benefit. Regression guard against re-introducing the
      // patch — match the actual `Object.defineProperty` shape, not the
      // word `devicePixelRatio` (which appears in the explanatory
      // comment).
      final js = buildDesktopModeShim(firefoxLinuxDesktopUserAgent);
      expect(js, isNot(contains("def(window, 'devicePixelRatio'")));
      expect(js, isNot(contains("'devicePixelRatio',")));
    });
  });
}
