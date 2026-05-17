import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/log_service.dart';

/// Mirrors `_generateSiteId` in `lib/web_view_model.dart` so tests
/// exercise the same surface a real session would use. Format:
/// `<microseconds-base36>-<rand-base36>`.
String _generateSiteId() {
  final now = DateTime.now().microsecondsSinceEpoch;
  final random = Random().nextInt(999999);
  return '${now.toRadixString(36)}-${random.toRadixString(36)}';
}

/// Captures any `print()` call inside [body], including the implicit
/// pipe inside `debugPrint`. Returns the captured lines.
Future<List<String>> _captureZonePrint(FutureOr<void> Function() body) async {
  final captured = <String>[];
  final completer = Completer<void>();
  runZoned(
    () async {
      try {
        await body();
        completer.complete();
      } catch (e, st) {
        completer.completeError(e, st);
      }
    },
    zoneSpecification: ZoneSpecification(
      print: (self, parent, zone, line) {
        captured.add(line);
      },
    ),
  );
  await completer.future;
  return captured;
}

void main() {
  setUp(() {
    LogService.instance.resetForTest();
  });

  test('sensitive logs never appear in zone print stream', () async {
    final siteId = _generateSiteId();
    final url = 'https://example.org/private?token=abc123';

    final captured = await _captureZonePrint(() async {
      // Simulate a representative session: site creation, navigation,
      // cookie capture, switch. Every per-site log call must already be
      // tagged sensitive in production code; this asserts the contract
      // holds end-to-end.
      LogService.instance.log(
        'WebView',
        'Creating webview for "$siteId" (siteId: $siteId)',
        sensitivity: LogSensitivity.sensitive,
      );
      LogService.instance.log(
        'WebView',
        'onUrlChanged: $url',
        sensitivity: LogSensitivity.sensitive,
      );
      LogService.instance.log(
        'Container',
        'Bound container ws-$siteId to 1 webview(s)',
        sensitivity: LogSensitivity.sensitive,
      );
      LogService.instance.log(
        'CookieIsolation',
        'Restoring cookies for siteId: $siteId',
        sensitivity: LogSensitivity.sensitive,
      );

      // Normal logs are also fine — they should NOT carry siteId/URLs.
      LogService.instance.log('App', 'Application started');
    });

    // Site identifier must never appear in adb logcat / iOS console
    // (which is what zone `print` simulates here).
    expect(
      captured.where((l) => l.contains(siteId)),
      isEmpty,
      reason:
          'siteId "$siteId" leaked through print() — sensitive entries must stay '
          'memory-only. Captured: ${captured.length} line(s).',
    );

    // Container name format also must not appear.
    expect(
      captured.where((l) => l.contains('ws-$siteId')),
      isEmpty,
      reason: 'Container name leaked through print().',
    );

    // The per-site URL must not appear.
    expect(
      captured.where((l) => l.contains(url)),
      isEmpty,
      reason: 'Per-site URL leaked through print().',
    );

    // Per-site host must not appear either (broader regex).
    expect(
      captured.where((l) => l.contains('example.org')),
      isEmpty,
      reason: 'Per-site host leaked through print().',
    );

    // Sanity: the sensitive ring captured them.
    final inSensitiveRing = LogService.instance.sensitiveEntries
        .where((e) => e.message.contains(siteId))
        .toList();
    expect(inSensitiveRing, isNotEmpty,
        reason: 'Sensitive entries should still reach the in-memory ring.');
  });

  test('export() never contains siteId-shaped substrings, even from sensitive logs',
      () async {
    final ids = [for (var i = 0; i < 5; i++) _generateSiteId()];

    for (final id in ids) {
      LogService.instance.log(
        'WebView',
        'siteId=$id',
        sensitivity: LogSensitivity.sensitive,
      );
    }
    // One normal log to confirm export() still works.
    LogService.instance.log('App', 'started');

    final exported = LogService.instance.export();
    expect(exported, contains('started'));
    for (final id in ids) {
      expect(
        exported,
        isNot(contains(id)),
        reason: 'siteId $id leaked into export() text',
      );
    }
  });

  test('siteId-shaped values land in sensitive ring under realistic call shape',
      () async {
    // Generate a few siteIds; if any matches the radix-36 shape regex
    // also leaks into print, the assertion below will catch it.
    final siteIds = [for (var i = 0; i < 3; i++) _generateSiteId()];

    final captured = await _captureZonePrint(() async {
      for (final id in siteIds) {
        // The audit guarantees these call sites are sensitive.
        LogService.instance.log(
          'WebView',
          'shouldOverrideUrlLoading: site (siteId: $id)',
          sensitivity: LogSensitivity.sensitive,
        );
      }
    });

    // The siteId pattern is `<base36>-<base36>` — at least 6 chars
    // before the dash, at least 1 after. Calibrated to the actual
    // _generateSiteId output.
    final siteIdRegex = RegExp(r'[0-9a-z]{6,}-[0-9a-z]+');
    for (final line in captured) {
      expect(
        siteIdRegex.hasMatch(line),
        isFalse,
        reason: 'Line "$line" matches siteId regex; sensitive logging contract '
            'broken.',
      );
    }

    // All explicit siteIds we passed in are still searchable in the
    // sensitive ring (proves we actually emitted something).
    for (final id in siteIds) {
      final hits = LogService.instance.sensitiveEntries
          .where((e) => e.message.contains(id))
          .toList();
      expect(hits, isNotEmpty,
          reason: 'siteId $id must be visible to developers via the toggle');
    }
  });

  test('debugPrint pipe is silent for sensitive entries even in debug mode',
      () async {
    // We can't override kDebugMode at runtime, but we CAN observe what
    // debugPrint pipes to the zone. The contract: only normal entries
    // ever call debugPrint. We assert by capturing the zone's print
    // stream (which is what debugPrint defaults to) and checking the
    // sensitive payload never shows up.
    final siteId = _generateSiteId();
    final captured = <String>[];
    final original = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) captured.add(message);
    };
    try {
      LogService.instance.log(
        'WebView',
        'siteId=$siteId',
        sensitivity: LogSensitivity.sensitive,
      );
    } finally {
      debugPrint = original;
    }
    expect(captured.where((l) => l.contains(siteId)), isEmpty);
  });
}
