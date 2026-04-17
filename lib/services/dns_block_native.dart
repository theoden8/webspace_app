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
      if (call.method == 'dnsEventsReady') {
        // Java signals that new DNS events are available for this site.
        // We pull the list (Java clears it atomically). Each event is
        // {host: String, blocked: bool} for both allowed and blocked.
        final siteId = call.arguments as String?;
        if (siteId == null) return;
        try {
          final list = await _channel.invokeMethod('fetchEvents', {'siteId': siteId});
          if (list is List) {
            for (final entry in list) {
              if (entry is Map) {
                final host = entry['host'] as String?;
                final blocked = entry['blocked'] as bool?;
                if (host != null && blocked != null) {
                  DnsBlockService.instance.recordRequest(siteId, 'https://$host/', blocked);
                }
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
