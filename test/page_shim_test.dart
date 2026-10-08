import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/page_shim.dart';

void main() {
  test('every shim ends in the evaluator sentinel', () {
    // The evaluator returns the IIFE's value otherwise, which the platform
    // channel cannot serialize for some shapes.
    final s = pageShim('g', js: '(function(){})();', frames: ShimFrames.all);
    expect(s.source, '(function(){})();\n;null;');
    expect(s.groupName, 'g');
  });

  test('frames and timing map onto the plugin flags', () {
    final all = pageShim('g', js: 'x', frames: ShimFrames.all);
    expect(all.forMainFrameOnly, isFalse);
    expect(all.injectionTime, inapp.UserScriptInjectionTime.AT_DOCUMENT_START);
    final top =
        pageShim('g', js: 'x', frames: ShimFrames.top, at: ShimTime.end);
    expect(top.forMainFrameOnly, isTrue);
    expect(top.injectionTime, inapp.UserScriptInjectionTime.AT_DOCUMENT_END);
  });
}
