import 'package:dbus/dbus.dart';
import 'package:flutter/services.dart';
import 'package:webspace/services/channel_reply.dart';

import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/log_service.dart';

/// A network the device is on, as the OS names it for as long as it is
/// connected: Android's network handle, NetworkManager's active connection.
/// A reconnect is a new one.
extension type const NetworkKey._(String raw) implements String {
  factory NetworkKey.android(String handle) => NetworkKey._('android:$handle');
  factory NetworkKey.networkManager(String path) => NetworkKey._('nm:$path');
}

/// What the OS found when it last checked the network the device is on.
sealed class NetworkVerdict {
  const NetworkVerdict();
}

/// The OS found a sign-in page holding traffic back on [network] (a hotel's,
/// a plane's): Android's `NET_CAPABILITY_CAPTIVE_PORTAL`, NetworkManager's
/// `NM_CONNECTIVITY_PORTAL`.
final class SignInRequired extends NetworkVerdict {
  const SignInRequired(this.network);
  final NetworkKey network;
}

/// No sign-in page the OS knows of, or an OS that cannot say.
final class NoSignIn extends NetworkVerdict {
  const NoSignIn();
}

/// What the user is told when a site's certificate was the network's
/// sign-in page answering in the site's place (TLS-012): the [host] the site
/// asked for and the name the answering certificate gave, when it gave one.
typedef SignInNotice = ({String host, String? answeredAs});

/// The OS's own captive portal check, read where a certificate the OS
/// rejected is about to be put to the user (TLS-012). The OS already probed
/// the network, so the app sends no request of its own. Holds which networks'
/// notice the user has seen, so a page retrying behind one portal raises one.
final class NetworkSignIn {
  NetworkSignIn({required this._read});

  /// The platform's; a test puts one reading its own verdict in its place.
  static NetworkSignIn instance = NetworkSignIn(read: _platformVerdict);

  static const _channel =
      MethodChannel('org.codeberg.theoden8.webspace/network_sign_in');

  final Future<NetworkVerdict> Function() _read;
  final Set<NetworkKey> _told = {};
  NetworkVerdict? _last;

  Future<NetworkVerdict> verdict() async => _last = await _read();

  /// Whether the last verdict this run read reported a portal: what a caller
  /// that cannot await one (a Dart client's certificate callback) goes by.
  /// No verdict read yet is none reported. It is as fresh as the last
  /// certificate a webview had rejected (TLS-012).
  bool get portalReported => _last is SignInRequired;

  /// True the first time [network] is passed here in this run.
  bool firstNotice(NetworkKey network) => _told.add(network);

  /// Whether this platform has a screen of the OS's where the network's
  /// sign-in page opens ([openSignIn]).
  static bool get canOpenSignIn => hostIsAndroid;

  /// Opens the OS's Wi-Fi settings, where tapping the network opens its
  /// sign-in page in the OS's own browser, apart from every site's data.
  static Future<bool> openSignIn() async {
    if (!canOpenSignIn) return false;
    try {
      return await _channel.invokeMethod<bool>('openSignIn') ?? false;
    } on PlatformException catch (e) {
      LogTag.tls.warning('Wi-Fi settings did not open: $e');
      return false;
    }
  }

  static Future<NetworkVerdict> _platformVerdict() {
    if (hostIsAndroid) return _android();
    if (hostIsLinux) return _networkManager();
    return Future.value(const NoSignIn());
  }

  static Future<NetworkVerdict> _android() async {
    switch (await _channel.ask<Object?>('verdict')) {
      case Answered(value: {'signIn': true, 'network': final String handle}):
        return SignInRequired(NetworkKey.android(handle));
      case Answered():
        return const NoSignIn();
      case PlatformRefused(:final error):
        LogTag.tls.warning('no network verdict: $error');
        return const NoSignIn();
      case NoPlugin():
        return const NoSignIn();
    }
  }

  static const _nmName = 'org.freedesktop.NetworkManager';
  static const _nmPortal = 2;

  static Future<NetworkVerdict> _networkManager() async {
    final bus = DBusClient.system();
    try {
      final nm = DBusRemoteObject(bus,
          name: _nmName, path: DBusObjectPath('/org/freedesktop/NetworkManager'));
      final connectivity = await nm.getProperty(_nmName, 'Connectivity');
      if (connectivity case DBusUint32(value: _nmPortal)) {
        final primary = await nm.getProperty(_nmName, 'PrimaryConnection');
        if (primary case DBusObjectPath(:final value)) {
          return SignInRequired(NetworkKey.networkManager(value));
        }
      }
      return const NoSignIn();
    } on IOException catch (e) {
      LogTag.tls.debug('no system bus for a network verdict: $e');
      return const NoSignIn();
    } on DBusMethodResponseException catch (e) {
      LogTag.tls.debug('NetworkManager gave no network verdict: $e');
      return const NoSignIn();
    } finally {
      await bus.close();
    }
  }
}
