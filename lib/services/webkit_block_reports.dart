import 'package:webspace/services/channel_reply.dart';
import 'package:meta/meta.dart';

import 'package:webspace/platform/app_distribution.dart';
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/content_rule_lists.dart';
import 'package:webspace/services/log_service.dart';

/// Whether WebKit reports to the app each request its content rule lists
/// block (CB-023), fixed once at launch so every page of the run counts the
/// same way. Only an iOS or macOS build made with `--flavor direct` can ask:
/// the report comes through a WebKit method Apple does not publish, which
/// the Runner compiles in for that flavor alone.
abstract final class WebKitBlockReports {
  static bool _active = false;

  /// Whether this run's pages count WebKit's reports, read by every page's
  /// interceptor config and by what the app counts of the page's own asks.
  static bool get active => debugActive ?? _active;

  @visibleForTesting
  static bool? debugActive;

  /// Whether this build can ask for the reports at all.
  static bool get offered =>
      (hostIsIOS || hostIsMacOS) &&
      hostDistribution == AppDistribution.direct;

  /// Asks the Runner for the reports when [wanted], before the first
  /// webview. The Runner answers false where it cannot: an App Store build,
  /// or a WebKit whose view class it found no way into.
  static Future<void> start({required bool wanted}) async {
    if (!offered || !wanted) return;
    switch (await appleContentRuleListChannel.ask<bool>('reportBlocks')) {
      case Answered(:final value):
        _active = value ?? false;
      case PlatformRefused(:final error):
        LogTag.contentBlocker.warning('WebKit block reports refused: $error');
      case NoPlugin():
        LogTag.contentBlocker.warning('WebKit block reports: no Runner plugin');
    }
    LogTag.contentBlocker.info('WebKit block reports: ${_active ? 'on' : 'off'}');
  }
}
