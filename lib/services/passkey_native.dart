import 'package:flutter/services.dart';
import 'package:webspace/services/channel_reply.dart';
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/passkey_engine.dart';
import 'package:webspace/utils/concurrency.dart';

/// What the device can do for passkeys, from `PasskeyPlugin.status`.
class PasskeyNativeStatus {
  const PasskeyNativeStatus({
    required this.sdk,
    required this.feature,
    required this.permission,
    required this.webViewSupport,
  });

  static const none = PasskeyNativeStatus(
      sdk: 0, feature: false, permission: false, webViewSupport: false);

  final int sdk;

  /// `android.software.credentials`: some vendors ship Android 14 without
  /// Credential Manager.
  final bool feature;

  /// CREDENTIAL_MANAGER_SET_ORIGIN, which a build without it lacks.
  final bool permission;

  /// Whether this WebView can do WebAuthn itself (WebViewFeature
  /// WEB_AUTHENTICATION), for the FOR_BROWSER comparison.
  final bool webViewSupport;

  bool get available => sdk >= 34 && feature && permission;

  /// What decided [available], for the log.
  String get describe => 'sdk=$sdk feature=$feature permission=$permission';
}

/// Dart side of `PasskeyPlugin.kt`. Android only; elsewhere every call
/// answers "not available" without touching a channel.
class PasskeyNative {
  PasskeyNative._();

  static const MethodChannel _channel =
      MethodChannel('org.codeberg.theoden8.webspace/passkey');

  /// Kept once the plugin has answered; a failed read is asked again.
  static PasskeyNativeStatus? _status;
  static final SingleFlight<(), PasskeyNativeStatus> _reading = SingleFlight();

  static Future<PasskeyNativeStatus> status() {
    if (!hostIsAndroid) return Future.value(PasskeyNativeStatus.none);
    final known = _status;
    if (known != null) return Future.value(known);
    return _reading.run((), call: _readStatus);
  }

  static Future<PasskeyNativeStatus> _readStatus() async {
    return switch (await _channel.askMap<String, Object?>('status')) {
      Answered(value: null) => _status = PasskeyNativeStatus.none,
      Answered(value: final raw?) => _status = PasskeyNativeStatus(
          sdk: raw['sdk'] is int ? raw['sdk'] as int : 0,
          feature: raw['feature'] == true,
          permission: raw['permission'] == true,
          webViewSupport: raw['webViewSupport'] == true,
        ),
      PlatformRefused() => PasskeyNativeStatus.none,
      NoPlugin() => PasskeyNativeStatus.none,
    };
  }

  /// Run [ceremony] through Credential Manager. Returns the provider's JSON,
  /// or throws [PasskeyNativeFailure].
  static Future<String> run(String key,
      {required PasskeyCeremony ceremony}) async {
    return switch (await _channel.ask<String>(
      ceremony.op == PasskeyOp.create ? 'create' : 'get',
      arguments: {
        'key': key,
        'requestJson': ceremony.requestJson,
        'origin': ceremony.origin,
        'clientDataHash': ceremony.clientDataHash,
      },
    )) {
      Answered(value: final json?) => json,
      Answered(value: null) => throw const PasskeyNativeFailure('UNREADABLE'),
      PlatformRefused(:final error) => throw PasskeyNativeFailure(error.code),
      NoPlugin() => throw const PasskeyNativeFailure('UNSUPPORTED'),
    };
  }

  static Future<void> cancel(String key) async {
    if (!hostIsAndroid) return;
    switch (await _channel.ask<void>('cancel', arguments: {'key': key})) {
      case Answered():
        break;
      case PlatformRefused():
        // Nothing in flight under this key any more.
        break;
      case NoPlugin():
        // No plugin, so nothing was started either.
        break;
    }
  }

  /// Switch the on-screen WebViews' own WebAuthn: `browser`, `app` or
  /// `none`. Returns what the engine kept, per WebView.
  static Future<Map<String, Object?>> setWebViewSupport(String mode) async {
    if (!hostIsAndroid) return const {'supported': false};
    final raw = await _channel.invokeMapMethod<String, Object?>(
        'setWebViewSupport', {'mode': mode});
    return raw ?? const {'supported': false};
  }
}
