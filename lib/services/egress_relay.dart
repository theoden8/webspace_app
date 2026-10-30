import 'dart:async';
import 'dart:math';

import 'package:flutter/services.dart';

import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/egress_route_engine.dart';
import 'package:webspace/services/experimental_features_service.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/settings/network_interface.dart';

/// An interface as the device reports it now, for the picker (NETIF-010).
typedef NetworkLink = ({InterfaceName name, bool up, List<String> addresses});

/// Dart side of the Linux runner's egress relay (`linux/egress_relay.cc`):
/// whether this device can bind a socket to an interface, which interfaces
/// it has, and the relay a site bound to one rides (network-interface
/// NETIF-003, NETIF-004).
class EgressRelay {
  EgressRelay._();
  static final EgressRelay instance = EgressRelay._();

  static const MethodChannel _channel = MethodChannel(
    'org.codeberg.theoden8.webspace/egress_relay',
  );

  bool _offered = false;
  EgressUp? _up;
  Future<void>? _starting;
  EgressRelayState? _pinned;
  List<NetworkLink>? _pinnedLinks;

  /// Whether this platform binds an interface at all: Linux, with a kernel
  /// that lets the app bind a socket to a device. The Experimental switch is
  /// listed only here.
  bool get offered => _offered;

  /// What `OutboundProxy.resolved` applies a site's interface with.
  EgressRelayState get state =>
      _pinned ??
      (!_offered ||
              !ExperimentalFeaturesService.instance.isEnabled(
                ExperimentalFeature.networkInterface,
              )
          ? const EgressOff()
          : (_up ?? const EgressDown()));

  /// After the experimental switches and developer mode have loaded.
  Future<void> initialize() async {
    if (!hostIsLinux) return;
    try {
      _offered = await _channel.invokeMethod<bool>('probe') ?? false;
    } on MissingPluginException {
      _offered = false;
    }
    if (!_offered) {
      LogTag.proxy.info('Network interfaces: this kernel binds no socket');
      return;
    }
    void follow() => unawaited(_follow());
    AppPref.experimentalNetworkInterface.listenable.addListener(follow);
    AppPref.developerMode.listenable.addListener(follow);
    await _follow();
  }

  /// Starts the relay once the experiment is reachable. It then runs until
  /// the app exits, so a site built on it is not left without its route.
  Future<void> _follow() async {
    if (_up != null || state is EgressOff) return;
    await (_starting ??= _start());
  }

  Future<void> _start() async {
    final random = Random.secure();
    final secret = [
      for (var i = 0; i < 16; i++)
        random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ].join();
    try {
      final endpoint = await _channel.invokeMapMethod<String, Object?>(
        'start',
        {'secret': secret},
      );
      if (endpoint case {'host': final String host, 'port': final int port}) {
        _up = EgressUp(host: host, port: port, secret: secret);
        LogTag.proxy.info('Egress relay up');
      }
    } on PlatformException catch (e) {
      LogTag.proxy.warning('Egress relay did not start: ${e.message}');
    } finally {
      _starting = null;
    }
  }

  /// The interfaces present now, loopback left out: nothing a site leaves by.
  Future<List<NetworkLink>> links() async {
    if (_pinnedLinks case final pinned?) return pinned;
    if (!_offered) return const [];
    final raw = await _channel.invokeListMethod<Object?>('links') ?? const [];
    return [
      for (final entry in raw)
        if (entry case {
          'name': final String name,
          'up': final bool up,
          'addresses': final List<Object?> addresses,
        })
          if (InterfaceName.parse(name) case final link? when name != 'lo')
            (
              name: link,
              up: up,
              addresses: [
                for (final a in addresses)
                  if (a is String) a,
              ],
            ),
    ];
  }

  /// What a host with no relay shows (the design gallery, a test): [state]
  /// in place of the platform's, and [links] in place of the device's when
  /// given. A null [state] hands both back.
  void setInMemory({
    required EgressRelayState? state,
    List<NetworkLink>? links,
    bool offered = true,
  }) {
    _pinned = state;
    _pinnedLinks = state == null ? null : links;
    _offered = state != null && offered;
  }
}
