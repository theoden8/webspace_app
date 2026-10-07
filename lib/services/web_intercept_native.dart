import 'package:webspace/platform/host_platform.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:webspace/services/block_decision.dart';
import 'package:webspace/services/content_blocker_service.dart';
import 'package:webspace/services/dns_block_service.dart';
import 'package:webspace/services/localcdn_service.dart';
import 'package:webspace/services/log_service.dart';

/// Dart-side bridge to the native Android interceptor that runs as part of
/// flutter_inappwebview's ContentBlockerHandler path. The native handler
/// blocks DNS + ABP-listed domains and serves pre-downloaded LocalCDN
/// resources for sub-resource requests — the Dart shouldInterceptRequest
/// callback only fires for the main document on modern Chromium WebView,
/// so any sub-resource interception has to happen natively.
///
/// **Currently inert** — the native side has the kill-switch hard-forced
/// ON (see WebInterceptPlugin.kt) while we localize a System WebView
/// dangling-raw_ptr crash on Chrome_IOThread. DNS / ABP / LocalCDN are
/// all bypassed at the native layer until the upstream issue is found.
class WebInterceptNative {
  static const _channel =
      MethodChannel('org.codeberg.theoden8.webspace/web_intercept');

  static bool get isSupported => hostIsAndroid;

  static void initialize() {
    if (!isSupported) return;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'blockEventsReady':
          await _drainBlockEvents(call.arguments as String?);
          break;
        case 'cdnEventsReady':
          await _drainCdnEvents(call.arguments as String?);
          break;
        case 'log':
          final args = call.arguments;
          if (args is Map) {
            final tag = (args['tag'] as String?) ?? 'WebIntercept';
            final message = (args['message'] as String?) ?? '';
            // Native bridge messages may carry per-site hosts / URLs.
            // Treat as sensitive so they stay out of adb logcat.
            LogService.instance.log(
              tag,
              message,
              sensitivity: LogSensitivity.sensitive,
            );
          }
          break;
      }
    });
  }

  static Future<void> _drainBlockEvents(String? siteId) async {
    if (siteId == null) return;
    try {
      final list =
          await _channel.invokeMethod('fetchBlockEvents', {'siteId': siteId});
      if (list is! List) return;
      applyBlockEvents(siteId, list);
    } on PlatformException {
      // A failed drain loses one window of counts; the next drain resumes.
    }
  }

  /// Decode one drained batch and apply it to the stats funnels.
  ///
  /// Split out of [_drainBlockEvents] so the payload contract with
  /// `WebInterceptPlugin.drainBlockEvents` (`{host, blocked, source, count}`,
  /// with `source` absent for allowed requests) is testable without an
  /// Android device: the fetch is platform-gated, the accounting is not.
  @visibleForTesting
  static void applyBlockEvents(String siteId, List<dynamic> list) {
    for (final entry in list) {
      if (entry is! Map) continue;
      final host = entry['host'];
      // `WebInterceptPlugin.Decision` pairs every block with its list, so a
      // block naming none is as malformed as a row without a host.
      final verdict = switch ((entry['blocked'], entry['source'])) {
        (false, _) => const Allowed(),
        (true, 'dns') => const Blocked(BlockSource.dns),
        (true, 'abp') => const Blocked(BlockSource.abp),
        _ => null,
      };
      if (host is! String || verdict == null) continue;
      // Native dedupes by host across the drain window: `count` is the
      // repeats since the last drain, absent from an older codec.
      final count = entry['count'] is int ? entry['count'] as int : 1;
      DnsBlockService.instance
          .recordVerdict(siteId, HostQuery(host), verdict, count: count);
      // Engine blocks decided natively never pass through
      // ContentBlockerService.isBlocked, so fold them into the
      // DevTools ABP counters here or the ABP tab undercounts.
      if (verdict.source == BlockSource.abp) {
        ContentBlockerService.instance
            .recordNativeEngineBlock(host, count: count);
      }
    }
  }

  static Future<void> _drainCdnEvents(String? siteId) async {
    if (siteId == null) return;
    try {
      final list =
          await _channel.invokeMethod('fetchCdnEvents', {'siteId': siteId});
      if (list is! List) return;
      for (final event in list) {
        final url = event is Map && event['url'] is String
            ? event['url'] as String
            : null;
        LocalCdnService.instance.recordReplacement(siteId, url: url);
      }
    } on PlatformException {
      // A failed drain loses one window of counts; the next drain resumes.
    }
  }

  // ========== Domain blocklists ==========

  /// Push the DNS blocklist to the native interceptor, grouped by which
  /// levels name each domain, so the Android side can answer at each site's
  /// own level off one copy of the data.
  ///
  /// Each group is introduced by a `#<mask-hex>` marker line; domain lines
  /// never start with `#` because the parser drops comments on both sides.
  /// A domain appears once however many levels name it.
  static Future<void> sendDnsLevelGroups(Map<int, Set<String>> groups) async {
    if (!isSupported) return;
    try {
      // Send one newline-joined blob, not a List<String>: the platform-channel
      // codec encodes a list element-by-element (type tag + length + UTF-8 per
      // entry), which is ~1s for a full ~650k-domain blocklist. A single string
      // is one encode/decode; the native side splits on '\n'.
      final sw = Stopwatch()..start();
      final masks = groups.keys.toList()..sort();
      final buf = StringBuffer();
      var total = 0;
      for (final mask in masks) {
        buf.writeln('#${mask.toRadixString(16)}');
        for (final domain in groups[mask]!) {
          buf.writeln(domain);
          total++;
        }
      }
      final blob = buf.toString();
      final joinMs = sw.elapsedMilliseconds;
      // The native handler kicks the set build onto a worker thread and returns
      // immediately; we already know the count here, so don't make native
      // recompute it.
      await _channel.invokeMethod('setDnsBlockedDomains', {
        'domains': blob,
      });
      LogService.instance.log(
          'DnsBlock',
          'Queued $total DNS domains across ${masks.length} group(s) for native build '
              '(join=${joinMs}ms channel+native=${sw.elapsedMilliseconds - joinMs}ms)',
          level: LogLevel.info);
    } catch (e) {
      LogService.instance.log('DnsBlock',
          'Failed to send DNS domains to native: $e',
          level: LogLevel.error);
    }
  }

  /// Push concatenated filter-list text to the native adblock-rust
  /// engine on Android. Pass an empty string to tear it down.
  ///
  /// When set, [`FastSubresourceInterceptor.checkUrl`] consults the
  /// engine for hosts the cheap `||domain^` host-set fast path didn't
  /// already block — enabling `$domain=`, path-anchored, and resource-
  /// type rules on Android sub-resources without a Dart roundtrip.
  ///
  /// Returns `null` on platforms where the engine isn't supported
  /// (no Android, library not bundled). Returns `{supported, active}`
  /// otherwise.
  static Future<Map<String, bool>?> sendAdblockEngineRules(
      String rulesText,
      {bool enableUboResources = true}) async {
    if (!isSupported) return null;
    try {
      final raw = await _channel.invokeMethod('setAdblockEngineRules', {
        'rulesText': rulesText,
        'enableUboResources': enableUboResources,
      });
      final map = (raw as Map?)
          ?.map((k, v) => MapEntry(k.toString(), v == true)) ??
          const {};
      LogService.instance.log(
          'ContentBlocker',
          'Native adblock engine: '
              'supported=${map['supported']}, active=${map['active']} '
              '(${rulesText.length} bytes pushed)',
          level: LogLevel.info);
      return map;
    } catch (e) {
      LogService.instance.log('ContentBlocker',
          'Failed to send engine rules to native: $e',
          level: LogLevel.error);
      return null;
    }
  }

  /// Diagnostic: returns true iff the native adblock-rust .so is
  /// loaded into the Android process. Lets the Dart UI grey out the
  /// engine toggle when the CI build skipped the Rust step.
  static Future<bool> isAdblockEngineSupported() async {
    if (!isSupported) return false;
    try {
      final raw = await _channel.invokeMethod('isAdblockEngineSupported');
      return raw == true;
    } on PlatformException {
      return false;
    }
  }

  // ========== LocalCDN ==========

  /// Push the CDN URL regex patterns to the native interceptor. Each
  /// pattern must expose groups 1/2/3 = library/version/file (matching
  /// LocalCdnService's _cdnPatterns table).
  static Future<void> sendCdnPatterns(List<String> patterns) async {
    if (!isSupported) return;
    try {
      final count = await _channel.invokeMethod('setCdnPatterns', {
        'patterns': patterns,
      });
      LogService.instance.log('LocalCDN',
          'Sent $count CDN patterns to native handler',
          level: LogLevel.info);
    } catch (e) {
      LogService.instance.log('LocalCDN',
          'Failed to send CDN patterns to native: $e',
          level: LogLevel.error);
    }
  }

  /// Push the cache index (cacheKey -> absolute file path) to the native
  /// interceptor. Call this whenever the cache changes (download, clear).
  static Future<void> sendCdnCacheIndex(Map<String, String> index) async {
    if (!isSupported) return;
    try {
      final count = await _channel.invokeMethod('setCdnCacheIndex', {
        'index': index,
      });
      LogService.instance.log('LocalCDN',
          'Sent $count cached CDN entries to native handler',
          level: LogLevel.info);
    } catch (e) {
      LogService.instance.log('LocalCDN',
          'Failed to send CDN cache index to native: $e',
          level: LogLevel.error);
    }
  }

  // ========== Shared ==========

  /// Attaches the interceptor to the headless webview [headlessId] alone
  /// (NOTIF-016). A headless webview is in no view tree when no activity is
  /// running, which is where [attachToWebViews] looks. True once attached.
  static Future<bool> attachToHeadless({
    required String headlessId,
    required String siteId,
    required int dnsLevel,
    required bool localCdn,
  }) async {
    if (!isSupported) return false;
    try {
      final attached = await _channel.invokeMethod<bool>('attachToHeadless', {
        'headlessId': headlessId,
        'siteId': siteId,
        'dnsLevel': dnsLevel,
        'localCdn': localCdn,
      });
      return attached ?? false;
    } on PlatformException catch (e) {
      LogService.instance.log('WebIntercept',
          'Failed to attach native interceptor to a headless webview: $e',
          level: LogLevel.error);
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// [dnsLevel] is the severity level this site blocks at (0 = the site has
  /// DNS blocking off). The interceptor applies it per request, which is the
  /// only place Android sub-resources learn about a site's DNS posture — the
  /// blocklist itself is app-wide. [localCdn] is whether this site's
  /// sub-resources may be served from the app-wide LocalCDN cache (LCDN-007).
  static Future<int> attachToWebViews({
    String? siteId,
    int? dnsLevel,
    bool? localCdn,
  }) async {
    if (!isSupported) return 0;
    try {
      final count = await _channel.invokeMethod('attachToWebViews', {
        'siteId': ?siteId,
        'dnsLevel': ?dnsLevel,
        'localCdn': ?localCdn,
      });
      LogService.instance.log(
        'WebIntercept',
        'Attached native interceptor to $count webviews '
        '(siteId: $siteId, dnsLevel: $dnsLevel, localCdn: $localCdn)',
        sensitivity: LogSensitivity.sensitive,
      );
      return count as int;
    } catch (e) {
      LogService.instance.log('WebIntercept',
          'Failed to attach native interceptor: $e',
          level: LogLevel.error);
      return 0;
    }
  }
}
