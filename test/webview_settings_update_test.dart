// BUG-022: a settings update must differ from what the webview holds only in
// the fields it means to change.

import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/user_agent_metadata_builder.dart';
import 'package:webspace/services/webview.dart';

bool _deepEquals(Object? a, {required Object? b}) {
  if (a is Map && b is Map) {
    return a.length == b.length &&
        a.keys.every((k) => b.containsKey(k) && _deepEquals(a[k], b: b[k]));
  }
  if (a is Iterable && b is Iterable) {
    final la = a.toList(), lb = b.toList();
    if (la.length != lb.length) return false;
    for (var i = 0; i < la.length; i++) {
      if (!_deepEquals(la[i], b: lb[i])) return false;
    }
    return true;
  }
  return a == b;
}

/// The keys a native `setSettings` acts on, the way Android and iOS/macOS
/// decide it: present in the incoming map and different from what the
/// webview holds.
Set<String> appliedKeys(
    Map<String, dynamic> held, {required Map<String, dynamic> incoming}) {
  return {
    for (final e in incoming.entries)
      if (e.value != null && !_deepEquals(held[e.key], b: e.value)) e.key,
  };
}

/// A desktop-mode, JavaScript-off, incognito site, shaped like
/// `WebViewFactory.createWebView` builds it.
inapp.InAppWebViewSettings createdSettings() => inapp.InAppWebViewSettings()
  ..javaScriptEnabled = false
  ..userAgent = null
  ..userAgentMetadata = buildUserAgentMetadata(null)
  ..thirdPartyCookiesEnabled = false
  ..incognito = true
  ..preferredContentMode = inapp.UserPreferredContentMode.DESKTOP
  ..mediaPlaybackRequiresUserGesture = false
  ..useWideViewPort = true
  ..loadWithOverviewMode = false
  ..textZoom = 130
  ..useHybridComposition = false;

void main() {
  test('premise: a fresh settings object names a default for what it leaves out',
      () {
    final held = createdSettings().toMap();
    final fresh = inapp.InAppWebViewSettings(
      textZoom: 150,
      useHybridComposition: false,
    ).toMap();
    expect(
      appliedKeys(held, incoming: fresh),
      containsAll(<String>[
        'textZoom',
        'javaScriptEnabled',
        'thirdPartyCookiesEnabled',
        'incognito',
        'preferredContentMode',
        'mediaPlaybackRequiresUserGesture',
        'loadWithOverviewMode',
      ]),
    );
  });

  test('a text zoom update on the creation settings changes only textZoom', () {
    final settings = createdSettings();
    final held = settings.toMap();
    settings.textZoom = 150;
    expect(appliedKeys(held, incoming: settings.toMap()), {'textZoom'});
  });

  test('re-applying the options a site was created with changes nothing', () {
    final settings = createdSettings();
    final held = settings.toMap();
    applyWebViewOptions(
      settings,
      javascriptEnabled: false,
      userAgent: null,
      thirdPartyCookiesEnabled: false,
      incognito: true,
    );
    expect(appliedKeys(held, incoming: settings.toMap()), isEmpty);
  });

  test('setOptions changes the options it owns and nothing else', () {
    final settings = createdSettings();
    final held = settings.toMap();
    applyWebViewOptions(
      settings,
      javascriptEnabled: true,
      userAgent: null,
      thirdPartyCookiesEnabled: true,
      incognito: false,
    );
    expect(appliedKeys(held, incoming: settings.toMap()),
        {'javaScriptEnabled', 'thirdPartyCookiesEnabled', 'incognito'});
    expect(settings.preferredContentMode,
        inapp.UserPreferredContentMode.DESKTOP);
    expect(settings.mediaPlaybackRequiresUserGesture, isFalse);
    expect(settings.loadWithOverviewMode, isFalse);
    expect(settings.textZoom, 130);
    expect(settings.useHybridComposition, isFalse);
  });
}
