import 'dart:io';

import 'package:flutter/services.dart';
import 'package:webspace/services/dns_block_service.dart';
import 'package:webspace/services/log_service.dart';

class DnsBlockNative {
  static const _channel = MethodChannel('org.codeberg.theoden8.webspace/dns_block');

  static bool get isSupported => Platform.isAndroid;

  static void initialize() {
    if (!isSupported) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'dnsBlockedReady') {
        // Java signals that new blocked events are available for this site.
        // We pull the list (Java clears it atomically).
        final siteId = call.arguments as String?;
        if (siteId == null) return;
        try {
          final list = await _channel.invokeMethod('fetchBlocked', {'siteId': siteId});
          if (list is List) {
            for (final host in list) {
              if (host is String) {
                DnsBlockService.instance.recordRequest(siteId, 'https://$host/', true);
              }
            }
          }
        } catch (_) {}
      }
    });
  }

  static Future<void> sendDomains(Set<String> domains) async {
    if (!isSupported) return;
    try {
      final count = await _channel.invokeMethod('setBlockedDomains', {
        'domains': domains.toList(),
      });
      LogService.instance.log('DnsBlock', 'Sent $count domains to native handler', level: LogLevel.info);
    } catch (e) {
      LogService.instance.log('DnsBlock', 'Failed to send domains to native: $e', level: LogLevel.error);
    }
  }

  static Future<int> attachToWebViews({String? siteId}) async {
    if (!isSupported) return 0;
    try {
      final count = await _channel.invokeMethod('attachToWebViews', {
        if (siteId != null) 'siteId': siteId,
      });
      LogService.instance.log('DnsBlock', 'Attached native DNS handler to $count webviews (siteId: $siteId)');
      return count as int;
    } catch (e) {
      LogService.instance.log('DnsBlock', 'Failed to attach native handler: $e', level: LogLevel.error);
      return 0;
    }
  }
}
