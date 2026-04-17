import 'dart:io';

import 'package:flutter/services.dart';
import 'package:webspace/services/dns_block_service.dart';
import 'package:webspace/services/localcdn_service.dart';
import 'package:webspace/services/log_service.dart';

/// Dart-side bridge to the native Android interceptor that runs as part of
/// flutter_inappwebview's ContentBlockerHandler path. The native handler
/// blocks DNS + ABP-listed domains and serves pre-downloaded LocalCDN
/// resources for sub-resource requests — the Dart shouldInterceptRequest
/// callback only fires for the main document on modern Chromium WebView,
/// so any sub-resource interception has to happen natively.
class WebInterceptNative {
  static const _channel =
      MethodChannel('org.codeberg.theoden8.webspace/web_intercept');

  static bool get isSupported => Platform.isAndroid;

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
            LogService.instance.log(tag, message);
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
      for (final entry in list) {
        if (entry is Map) {
          final host = entry['host'] as String?;
          final blocked = entry['blocked'] as bool?;
          if (host == null || blocked == null) continue;
          final sourceStr = entry['source'] as String?;
          final source = switch (sourceStr) {
            'dns' => BlockSource.dns,
            'abp' => BlockSource.abp,
            _ => null,
          };
          DnsBlockService.instance
              .recordRequest(siteId, 'https://$host/', blocked, source: source);
        }
      }
    } catch (_) {}
  }

  static Future<void> _drainCdnEvents(String? siteId) async {
    if (siteId == null) return;
    try {
      final list =
          await _channel.invokeMethod('fetchCdnEvents', {'siteId': siteId});
      if (list is! List) return;
      for (final _ in list) {
        LocalCdnService.instance.recordReplacement(siteId);
      }
    } catch (_) {}
  }

  // ========== Domain blocklists ==========

  /// Push the DNS blocklist domains to the native interceptor.
  static Future<void> sendDnsDomains(Set<String> domains) async {
    if (!isSupported) return;
    try {
      final count = await _channel.invokeMethod('setDnsBlockedDomains', {
        'domains': domains.toList(),
      });
      LogService.instance.log(
          'DnsBlock', 'Sent $count DNS domains to native handler',
          level: LogLevel.info);
    } catch (e) {
      LogService.instance.log('DnsBlock',
          'Failed to send DNS domains to native: $e',
          level: LogLevel.error);
    }
  }

  /// Push the ABP blocklist domains (aggregated from enabled filter
  /// lists' `||domain^` rules) to the native interceptor. Hits are
  /// attributed to ABP in the per-site block log.
  static Future<void> sendAbpDomains(Set<String> domains) async {
    if (!isSupported) return;
    try {
      final count = await _channel.invokeMethod('setAbpBlockedDomains', {
        'domains': domains.toList(),
      });
      LogService.instance.log(
          'ContentBlocker', 'Sent $count ABP domains to native handler',
          level: LogLevel.info);
    } catch (e) {
      LogService.instance.log('ContentBlocker',
          'Failed to send ABP domains to native: $e',
          level: LogLevel.error);
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

  static Future<int> attachToWebViews({String? siteId}) async {
    if (!isSupported) return 0;
    try {
      final count = await _channel.invokeMethod('attachToWebViews', {
        if (siteId != null) 'siteId': siteId,
      });
      LogService.instance.log('WebIntercept',
          'Attached native interceptor to $count webviews (siteId: $siteId)');
      return count as int;
    } catch (e) {
      LogService.instance.log('WebIntercept',
          'Failed to attach native interceptor: $e',
          level: LogLevel.error);
      return 0;
    }
  }
}
