import 'dart:async';
import 'dart:io';

import 'package:webspace/l10n/runtime/arb_messages.dart';
import 'package:webspace/services/global_outbound_proxy.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/page_js.dart';
import 'package:webspace/services/shortcut_service.dart';
import 'package:webspace/services/webview.dart';

/// Every test sees the page scripts the app loads at startup, read from the
/// checkout rather than the asset bundle so a test needs no Flutter binding,
/// and what main decides and loads before the app runs, at its defaults: the
/// composition mode, a launcher that takes home shortcuts (a TV's test says
/// `withoutShortcuts()`), and no app-wide proxy. Translations are read from
/// the checkout too, synchronously, so a widget's first frame already has its
/// text. Routine logs stay in memory so they cannot truncate CI failures;
/// WS_VERBOSE_TEST_LOGS=1 restores their console output for diagnosis.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  LogService.instance.consoleLevel =
      Platform.environment['WS_VERBOSE_TEST_LOGS'] == '1'
          ? LogLevel.debug
          : LogLevel.warning;
  await PageJs.load(read: (path) => File(path).readAsString());
  ArbMessages.read = (path) => File(path).readAsStringSync();
  WebViewFactory.hybridComposition = true;
  ShortcutService.debugOfferedOverride = true;
  GlobalOutboundProxy.resetForTest();
  await testMain();
}
