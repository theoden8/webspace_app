import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;

/// Which frames a page shim reaches.
///
/// No default: the plugin's own is main-frame-only (WKUserScript's), so a
/// shim that forgot to say looked exactly like one that meant it, and a
/// cross-origin iframe ran unpatched.
enum ShimFrames { all, top }

enum ShimTime { start, end }

/// A script installed into every document the webview loads.
///
/// The `;null;` tail keeps WebKit from reporting the last expression's value
/// as an unsupported return type.
inapp.UserScript pageShim(
  String group,
  String js, {
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
