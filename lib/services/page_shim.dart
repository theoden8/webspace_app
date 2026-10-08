import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;

import 'package:webspace/settings/shim_frames.dart';

export 'package:webspace/settings/shim_frames.dart';

enum ShimTime { start, end }

/// A script installed into every document the webview loads.
///
/// The `;null;` tail keeps WebKit from reporting the last expression's value
/// as an unsupported return type.
inapp.UserScript pageShim(
  String group, {
  required String js,
  required ShimFrames frames,
  ShimTime at = ShimTime.start,
}) =>
    inapp.UserScript(
      groupName: group,
      source: '$js\n;null;',
      injectionTime: switch (at) {
        ShimTime.start => inapp.UserScriptInjectionTime.AT_DOCUMENT_START,
        ShimTime.end => inapp.UserScriptInjectionTime.AT_DOCUMENT_END,
      },
      forMainFrameOnly: switch (frames) {
        ShimFrames.all => false,
        ShimFrames.top => true,
      },
    );
