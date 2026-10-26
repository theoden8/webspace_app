import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/settings/site_ids.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:webspace/services/block_decision.dart';
import 'package:webspace/services/content_blocker_service.dart';
import 'package:webspace/services/dns_block_service.dart';
import 'package:webspace/services/localcdn_service.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/view_blockers.dart';

/// Dart-side bridge to the native Android interceptor that runs as part of
/// flutter_inappwebview's ContentBlockerHandler path. The native handler
/// blocks DNS + ABP-listed domains and serves pre-downloaded LocalCDN
/// resources for sub-resource requests — the Dart shouldInterceptRequest
/// callback only fires for the main document on modern Chromium WebView,
/// so any sub-resource interception has to happen natively.
class WebInterceptNative {
  static const _channel =
      MethodChannel('org.codeberg.theoden8.webspace/web_intercept');

  static bool get isSupported => hostIsAndroid || debugAssumeAndroid;

  /// Lets a host test drive the Android paths against a mocked channel.
  @visibleForTesting
  static bool debugAssumeAndroid = false;

  /// Installs the handler for what the native side reports; what sends it
  /// data takes the [NativeIntercept] this returns.
  static NativeIntercept initialize() {
    if (!isSupported) return const NativeIntercept._();
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'blockEventsReady':
          await _drainBlockEvents(SiteId.parse(call.arguments));
          break;
        case 'cdnEventsReady':
          await _drainCdnEvents(SiteId.parse(call.arguments));
          break;
        case 'log':
          final args = call.arguments;
          if (args is Map) {
            // Native bridge messages may carry per-site hosts / URLs.
            // Treat as sensitive so they stay out of adb logcat.
            LogTag.webIntercept
                .debug((args['message'] as String?) ?? '', sensitive: true);
          }
          break;
      }
    });
    return const NativeIntercept._();
  }

  static Future<void> _drainBlockEvents(SiteId? siteId) async {
    if (siteId == null) return;
    try {
      final list =
          await _channel.invokeMethod('fetchBlockEvents', {'siteId': siteId});
      if (list is! List) return;
      applyBlockEvents(siteId, list: list);
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
  static void applyBlockEvents(SiteId siteId, {required List<dynamic> list}) {
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
      DnsBlockService.instance.recordVerdict(siteId,
          query: HostQuery(host), verdict: verdict, count: count);
      // Engine blocks decided natively never pass through
      // ContentBlockerService.isBlocked, so fold them into the
      // DevTools ABP counters here or the ABP tab undercounts.
      if (verdict.source == BlockSource.abp) {
        ContentBlockerService.instance
            .recordNativeEngineBlock(host, count: count);
      }
    }
  }

  static Future<void> _drainCdnEvents(SiteId? siteId) async {
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

  /// Attaches the interceptor to [headless] alone (NOTIF-016), by its
  /// headless id: a headless webview has no platform view. True once
  /// attached.
  static Future<bool> attachToHeadless(
    inapp.HeadlessInAppWebView headless, {
    required SiteBlockers blockers,
  }) async {
    if (!isSupported) return false;
    try {
      final attached = await _channel.invokeMethod<bool>('attachToHeadless', {
        'headlessId': headless.id,
        ..._told(blockers),
      });
      return attached ?? false;
    } on PlatformException catch (e) {
      LogTag.webIntercept.error(
          'Failed to attach native interceptor to a headless webview: $e');
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Attaches the interceptor to the webview behind the platform view
  /// [attach] names, for its site alone. True once attached; the view's
  /// first load waits for it, so the first document's sub-resources meet the
  /// site's blockers.
  static Future<bool> attachToView(ViewAttach attach) async {
    if (!isSupported) return true;
    try {
      final attached = await _channel.invokeMethod<bool>('attachToView', {
        'viewId': attach.view,
        ..._told(attach.blockers),
      });
      if (attached != true) {
        LogTag.webIntercept.warning(
            'No webview behind platform view ${attach.view} to attach to',
            sensitive: true);
      }
      return attached ?? false;
    } on PlatformException catch (e) {
      LogTag.webIntercept.error('Failed to attach native interceptor: $e');
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// What the channel carries of [b]. The interceptor applies the level per
  /// request, the only place Android sub-resources learn a site's DNS
  /// posture: the blocklist itself is app-wide.
  static Map<String, Object> _told(SiteBlockers b) => {
        'siteId': b.site,
        'dnsLevel': b.dnsLevel,
        'localCdn': b.localCdn,
        'contentBlock': b.contentBlock,
      };

  /// Re-reads each attached webview's site settings into its interceptor,
  /// after a dataset or a setting changed. Returns how many are attached.
  static Future<int> attachToWebViews() async {
    if (!isSupported) return 0;
    try {
      final count = await _channel.invokeMethod<int>('attachToWebViews');
      LogTag.webIntercept.debug('Refreshed $count attached webviews');
      return count ?? 0;
    } on PlatformException catch (e) {
      LogTag.webIntercept.error('Failed to refresh the native interceptors: $e');
      return 0;
    } on MissingPluginException {
      return 0;
    }
  }
}

/// What the native adblock engine is built from.
sealed class NativeEngineSource {
  const NativeEngineSource();

  int get length;
}

/// The engine as the Dart side serialized it, which Android hydrates instead
/// of parsing the lists again.
class SerializedEngine extends NativeEngineSource {
  const SerializedEngine(this.blob);

  final Uint8List blob;

  @override
  int get length => blob.length;
}

/// The rules text, parsed natively: the fallback for a blob that does not
/// hydrate.
class EngineRulesText extends NativeEngineSource {
  const EngineRulesText(this.rulesText);

  final String rulesText;

  @override
  int get length => rulesText.length;
}

/// The native interceptor with its handler installed, which only
/// [WebInterceptNative.initialize] makes: whatever sends it data holds one,
/// so nothing reaches it before Dart can hear what it reports.
final class NativeIntercept {
  const NativeIntercept._();

  /// Push the DNS blocklist to the native interceptor, grouped by which
  /// levels name each domain, so the Android side can answer at each site's
  /// own level off one copy of the data.
  ///
  /// Each group is introduced by a `#<mask-hex>` marker line; domain lines
  /// never start with `#` because the parser drops comments on both sides.
  /// A domain appears once however many levels name it.
  Future<void> sendDnsLevelGroups(Map<int, Set<String>> groups) async {
    if (!WebInterceptNative.isSupported) return;
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
      await WebInterceptNative._channel.invokeMethod('setDnsBlockedDomains', {
        'domains': blob,
      });
      LogTag.dnsBlock.info(
          'Queued $total DNS domains across ${masks.length} group(s) for native build '
          '(join=${joinMs}ms channel+native=${sw.elapsedMilliseconds - joinMs}ms)');
    } on PlatformException catch (e) {
      LogTag.dnsBlock.error('Failed to send DNS domains to native: $e');
    } on MissingPluginException catch (e) {
      LogTag.dnsBlock.error('Failed to send DNS domains to native: $e');
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
  /// Hands the native interceptor the engine the Dart side runs, so Android
  /// decides sub-resources without a Dart round trip. Empty turns it off.
  Future<Map<String, bool>?> sendAdblockEngine(NativeEngineSource source,
      {required bool enableUboResources}) async {
    if (!WebInterceptNative.isSupported) return null;
    try {
      final raw = await WebInterceptNative._channel.invokeMethod('setAdblockEngine', {
        ...switch (source) {
          SerializedEngine(:final blob) => {'blob': blob},
          EngineRulesText(:final rulesText) => {'rulesText': rulesText},
        },
        'enableUboResources': enableUboResources,
      });
      final map = (raw as Map?)
          ?.map((k, v) => MapEntry(k.toString(), v == true)) ??
          const {};
      LogTag.contentBlocker.info('Native adblock engine: '
          'supported=${map['supported']}, active=${map['active']} '
          '(${source.length} bytes pushed)');
      return map;
    } on PlatformException catch (e) {
      LogTag.contentBlocker.error('Failed to send engine to native: $e');
      return null;
    }
  }

  /// Push the CDN URL regex patterns to the native interceptor. Each
  /// pattern must expose groups 1/2/3 = library/version/file (matching
  /// LocalCdnService's _cdnPatterns table).
  Future<void> sendCdnPatterns(List<String> patterns) async {
    if (!WebInterceptNative.isSupported) return;
    try {
      final count = await WebInterceptNative._channel.invokeMethod('setCdnPatterns', {
        'patterns': patterns,
      });
      LogTag.localCdn.info('Sent $count CDN patterns to native handler');
    } on PlatformException catch (e) {
      LogTag.localCdn.error('Failed to send CDN patterns to native: $e');
    } on MissingPluginException catch (e) {
      LogTag.localCdn.error('Failed to send CDN patterns to native: $e');
    }
  }

  /// Push the cache index (cacheKey -> absolute file path) to the native
  /// interceptor. Call this whenever the cache changes (download, clear).
  Future<void> sendCdnCacheIndex(Map<String, String> index) async {
    if (!WebInterceptNative.isSupported) return;
    try {
      final count = await WebInterceptNative._channel.invokeMethod('setCdnCacheIndex', {
        'index': index,
      });
      LogTag.localCdn.info('Sent $count cached CDN entries to native handler');
    } on PlatformException catch (e) {
      LogTag.localCdn.error('Failed to send CDN cache index to native: $e');
    } on MissingPluginException catch (e) {
      LogTag.localCdn.error('Failed to send CDN cache index to native: $e');
    }
  }
}
