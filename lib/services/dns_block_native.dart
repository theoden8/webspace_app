import 'dart:io';

import 'package:flutter/services.dart';
import 'package:webspace/services/dns_block_service.dart';
import 'package:webspace/services/log_service.dart';

class DnsBlockNative {
  static const _channel = MethodChannel('org.codeberg.theoden8.webspace/dns_block');

  static bool get isSupported => Platform.isAndroid;

  /// Current site ID for attributing blocked requests. Set by the app when switching sites.
  static String? activeSiteId;

  static void initialize() {
    if (!isSupported) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onDnsBlocked' && activeSiteId != null) {
        final host = call.arguments as String;
        DnsBlockService.instance.recordRequest(activeSiteId!, 'https://$host/', true);
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

  static Future<int> attachToWebViews() async {
    if (!isSupported) return 0;
    try {
      final count = await _channel.invokeMethod('attachToWebViews');
      LogService.instance.log('DnsBlock', 'Attached native DNS handler to $count webviews');
      return count as int;
    } catch (e) {
      LogService.instance.log('DnsBlock', 'Failed to attach native handler: $e', level: LogLevel.error);
      return 0;
    }
  }
}
