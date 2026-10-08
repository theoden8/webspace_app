import 'package:flutter/services.dart';
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
    try {
      final raw = await _channel.invokeMapMethod<String, Object?>('status');
      return _status = raw == null
          ? PasskeyNativeStatus.none
          : PasskeyNativeStatus(
              sdk: raw['sdk'] is int ? raw['sdk'] as int : 0,
              feature: raw['feature'] == true,
              permission: raw['permission'] == true,
              webViewSupport: raw['webViewSupport'] == true,
            );
    } on PlatformException {
      return PasskeyNativeStatus.none;
    } on MissingPluginException {
      return PasskeyNativeStatus.none;
    }
  }

  /// Run [ceremony] through Credential Manager. Returns the provider's JSON,
  /// or throws [PasskeyNativeFailure].
  static Future<String> run(String key,
      {required PasskeyCeremony ceremony}) async {
    try {
      final json = await _channel.invokeMethod<String>(
        ceremony.op == PasskeyOp.create ? 'create' : 'get',
        {
          'key': key,
          'requestJson': ceremony.requestJson,
          'origin': ceremony.origin,
          'clientDataHash': ceremony.clientDataHash,
        },
      );
      if (json == null) throw const PasskeyNativeFailure('UNREADABLE');
      return json;
    } on PlatformException catch (e) {
      throw PasskeyNativeFailure(e.code);
    } on MissingPluginException {
      throw const PasskeyNativeFailure('UNSUPPORTED');
    }
  }

  static Future<void> cancel(String key) async {
    if (!hostIsAndroid) return;
    try {
      await _channel.invokeMethod<void>('cancel', {'key': key});
    } on PlatformException {
      // Nothing in flight under this key any more.
    } on MissingPluginException {
      // No plugin, so nothing was started either.
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
