import 'dart:async';
import 'dart:io';

import 'package:webspace/l10n/runtime/arb_messages.dart';
import 'package:webspace/services/global_outbound_proxy.dart';
import 'package:webspace/services/page_js.dart';
import 'package:webspace/services/webview.dart';

/// Every test sees the page scripts the app loads at startup, read from the
/// checkout rather than the asset bundle so a test needs no Flutter binding,
/// and what main decides and loads before the app runs, at its defaults: the
/// composition mode, and no app-wide proxy. Translations are read from the
/// checkout too, synchronously, so a widget's first frame already has its
/// text.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  await PageJs.load(read: (path) => File(path).readAsString());
  ArbMessages.read = (path) => File(path).readAsStringSync();
  WebViewFactory.hybridComposition = true;
  GlobalOutboundProxy.resetForTest();
  await testMain();
}
