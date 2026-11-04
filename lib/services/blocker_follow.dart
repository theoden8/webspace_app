import 'dart:async';

import 'package:flutter/foundation.dart' show VoidCallback;
import 'package:webspace/services/content_blocker_service.dart';
import 'package:webspace/services/dns_block_service.dart';
import 'package:webspace/services/view_blockers.dart';
import 'package:webspace/services/web_intercept_native.dart';
import 'package:webspace/services/webview_config.dart';

/// Tells a live view when the blockers' data changes under it: a level's
/// list lands, a filter list downloads. Android's interceptor keeps the
/// level it was attached at, so the view is one of [ViewBlockers]', told
/// its site's level as the partition moves (DNS-022); WebKit's interceptor
/// answers from the bloom its document fetched, where a miss is a hard
/// allow, so the page reloads its bloom ([evaluate] runs it). A wake's
/// headless check follows them the same way. Returns the undo, run when
/// the view unmounts, a new one replaces it or the check is disposed.
VoidCallback followBlockerData(
  WebViewConfig config, {
  required InterceptedView? view,
  required Future<void> Function(String js) evaluate,
  required bool Function() live,
}) {
  if (WebInterceptNative.isSupported) {
    final views = DnsBlockService.instance.views;
    return () {
      if (view != null) views.gone(view);
    };
  }
  void changed() {
    if (!live()) return;
    if (config.posture.blocking.dns || config.posture.blocking.contentBlock) {
      unawaited(evaluate(
          'window.__wsReloadBlockBloom && window.__wsReloadBlockBloom()'));
    }
  }

  final dns = DnsBlockService.instance..addBlocklistChangedListener(changed);
  final blocker = ContentBlockerService.instance
    ..addRulesChangedListener(changed);
  return () {
    dns.removeBlocklistChangedListener(changed);
    blocker.removeRulesChangedListener(changed);
  };
}
