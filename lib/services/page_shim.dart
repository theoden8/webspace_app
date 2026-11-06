import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;

import 'package:webspace/settings/shim_group.dart';

export 'package:webspace/settings/shim_group.dart';

/// A script installed into every document the webview loads, reaching the
/// frames and running at the time its [group] declares.
///
/// The `;null;` tail keeps WebKit from reporting the last expression's value
/// as an unsupported return type.
inapp.UserScript pageShim(ShimGroup group, {required String js}) =>
    inapp.UserScript(
      groupName: group.groupName,
      source: '$js\n;null;',
      injectionTime: switch (group.at) {
        ShimTime.start => inapp.UserScriptInjectionTime.AT_DOCUMENT_START,
        ShimTime.end => inapp.UserScriptInjectionTime.AT_DOCUMENT_END,
      },
      forMainFrameOnly: switch (group.frames) {
        ShimFrames.all => false,
        ShimFrames.top => true,
      },
    );
