// A tor started outside the app (Orbot, the system tor service, Tor
// Browser's), reached over its SOCKS port. The engine treats it like the
// embedded runtime: the same per-site SOCKS credentials, which a tor with
// IsolateSOCKSAuth (its default) turns into per-site circuits. Spec: TOR-025.
//
// When the user names that tor's control port as well (TOR-026), the runtime
// holds a control link to it: what the link reads is published as an
// [ExternalTorControlState], and new circuits and exit countries go through
// it as they go through the built-in tor's. Without one, neither is offered.
//
// Free of dart:io, like tor_service.dart; the socket probe lives in
// tor_socks_probe_io.dart and the control socket in tor_control_io.dart.

import 'dart:async';

import 'package:webspace/services/external_tor_posture_engine.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/outbound_http_types.dart'
    show splitProxyAddress;
import 'package:webspace/services/tor_control.dart';
import 'package:webspace/services/tor_control_link.dart';
import 'package:webspace/services/tor_engine.dart';

/// What a listener said when asked whether it is tor.
enum ExternalTorAnswer {
  /// It answered an HTTP request with tor's own "Tor is not an HTTP Proxy",
  /// which C tor and Arti both send from a SOCKS port.
  tor,

  /// Something answered, and not as tor.
  notTor,

  /// Nothing accepted the connection.
  unreachable,
}

typedef ExternalTorIdentify = Future<ExternalTorAnswer> Function(
    String host, {required int port});

/// How the runtime reaches the external tor's control port (TOR-026).
final class ExternalTorControlAccess {
  const ExternalTorControlAccess({
    required this.endpoint,
    required this.password,
    required this.connect,
    required this.readCookie,
  });

  /// The control endpoint as the user saved it; empty for none.
  final String Function() endpoint;

  /// The saved control password, or null.
  final Future<String?> Function() password;

  final TorControlConnect connect;
  final TorCookieRead readCookie;
}

/// The app's control channel to the external tor, as screens show it.
sealed class ExternalTorControlState {
  const ExternalTorControlState();
}

/// Not asked: no control port is named, or the tor is not up.
final class TorControlIdle extends ExternalTorControlState {
  const TorControlIdle();
}

final class TorControlAsking extends ExternalTorControlState {
  const TorControlAsking();
}

/// Attached: new circuits and exit countries go through it, and [gaps] is
/// how that tor treats sites differently from the built-in one.
final class TorControlAttached extends ExternalTorControlState {
  const TorControlAttached({required this.version, required this.gaps});

  final String? version;
  final List<TorPostureGap> gaps;
}

final class TorControlNotAttached extends ExternalTorControlState {
  const TorControlNotAttached(this.refusal, {required this.detail});

  final TorControlRefusal refusal;
  final String detail;
}

class ExternalTorRuntime implements TorRuntime {
  ExternalTorRuntime({
    required String Function() address,
    required ExternalTorIdentify identify,
    ExternalTorControlAccess? control,
  })  : _address = address,
        _identify = identify,
        _control = control;

  final String Function() _address;
  final ExternalTorIdentify _identify;
  final ExternalTorControlAccess? _control;
  final StreamController<TorStatus> _events =
      StreamController<TorStatus>.broadcast();
  final StreamController<ExternalTorControlState> _controlStates =
      StreamController<ExternalTorControlState>.broadcast();

  /// Bumped per [_connect], so an answer for an address the user has since
  /// changed cannot overwrite the answer for the new one.
  int _attempt = 0;

  TorControlLink? _link;
  StreamSubscription<TorControlLinkEvent>? _linkSub;

  /// The exit pin the link has put in force, or null. Kept here rather than
  /// read from the link, which may be gone by the time it matters.
  String? _pinned;

  ExternalTorControlState _controlState = const TorControlIdle();

  ExternalTorControlState get controlState => _controlState;
  Stream<ExternalTorControlState> get controlStates => _controlStates.stream;

  @override
  bool get isAvailable => true;

  /// A start is one probe of the listener, and the user may have started
  /// that tor since the last one.
  @override
  bool get retriesFreely => true;

  @override
  Stream<TorStatus> get events => _events.stream;

  @override
  Future<void> start() => _connect();

  /// Asked again after the address or the control port changes, or when the
  /// engine finds the listener gone after the app was away.
  Future<void> reconnect() => _connect();

  @override
  Future<void> reopenListeners() => _connect();

  /// Puts back any exit pin and lets the control channel go. The engine
  /// starts the runtime again when it is next wanted.
  @override
  Future<void> stop() async {
    _attempt++;
    await _dropLink();
    _events.add(const TorStopped());
  }

  @override
  Future<void> rebuildCircuits() async {
    final link = _link;
    if (link == null) return;
    try {
      await link.newCircuits();
    } on TorControlClosed {
      LogTag.tor.debug('New circuits: the control channel had closed');
    } on TimeoutException {
      LogTag.tor.debug('New circuits: the control port did not answer');
    } on TorControlRejected catch (e) {
      LogTag.tor.debug('New circuits refused: $e');
    }
  }

  @override
  Future<void> applyExitCountry(String? exitNodes, {String? geoipFile}) async {
    final link = _link;
    if (link == null) {
      if (exitNodes == null) return;
      throw const TorExitPinUnsupported(
          'An exit country needs the control port of the external tor, and '
          'the app has no control channel to it.');
    }
    final previous = _pinned;
    // Counted as in force from here, so a link lost mid-pin holds the sites.
    _pinned ??= exitNodes;
    try {
      await link.pin(exitNodes);
    } on Exception {
      if (identical(_link, link)) _pinned = previous;
      rethrow;
    }
    if (!identical(_link, link)) {
      throw const TorExitPinUnsupported(
          "The external tor's control channel was replaced while the exit "
          'country was being changed, so the change is not in force.');
    }
    _pinned = exitNodes;
  }

  /// Bridges are the external tor's own configuration.
  @override
  Future<int> startTransport(String transport) async => 0;

  @override
  Future<void> setTorrcOptions(List<(String, String)> options) async {}

  Future<void> _connect() async {
    final attempt = ++_attempt;
    final address = _address();
    // The pin was put in force on the link about to go. The engine is told
    // the runtime starts again, which holds the sites and has it ask for the
    // pin on whatever link comes next.
    if (_pinned != null) _events.add(const TorStarting());
    if (_link != null) await _dropLink();
    if (attempt != _attempt) return;
    final parsed = splitProxyAddress(address);
    if (parsed == null) {
      _fail('The external Tor address "$address" is not host:port.');
      return;
    }
    LogTag.tor.debug('Asking $address whether it is tor', sensitive: true);
    final answer = await _identify(parsed.host, port: parsed.port);
    if (attempt != _attempt) return;
    switch (answer) {
      case ExternalTorAnswer.tor:
        LogTag.tor.debug('$address answered as tor', sensitive: true);
        await _attach(attempt: attempt, socks: parsed);
        if (attempt != _attempt) return;
        _events.add(TorUp(parsed.host, port: parsed.port));
      case ExternalTorAnswer.notTor:
        _fail('Something answers at $address, but not as tor.');
      case ExternalTorAnswer.unreachable:
        _fail('Nothing answers at $address.');
    }
  }

  /// Opens the control link to the tor behind [socks], before `up` is
  /// published so a pin waiting on `up` finds it.
  Future<void> _attach(
      {required int attempt, required ({String host, int port}) socks}) async {
    final control = _control;
    final endpoint =
        control == null ? null : TorControlEndpoint.parse(control.endpoint());
    if (control == null || endpoint == null) {
      _setControl(const TorControlIdle());
      return;
    }
    _setControl(const TorControlAsking());
    final TorControlAttach result;
    try {
      final channel =
          await control.connect(endpoint).timeout(kTorControlCommandTimeout);
      result = await TorControlLink.attach(
        channel: channel,
        password: await control.password(),
        readCookie: control.readCookie,
        socks: socks,
      );
    } on TorControlUnreachable catch (e) {
      if (attempt == _attempt) {
        _setControl(TorControlNotAttached(TorControlRefusal.unreachable,
            detail: e.message));
      }
      return;
    } on TimeoutException {
      if (attempt == _attempt) {
        _setControl(const TorControlNotAttached(TorControlRefusal.unreachable,
            detail: 'The control port did not answer in time.'));
      }
      return;
    }
    switch (result) {
      case TorControlLinked(:final link):
        if (attempt != _attempt) {
          await link.close();
          return;
        }
        _link = link;
        _linkSub = link.changes.listen(_onLinkChange);
        LogTag.tor.debug('Attached to the external tor ${link.version ?? ''} '
            'at $endpoint');
        _publishAttached(link.posture);
      case TorControlNotLinked(:final refusal, :final detail):
        LogTag.tor.debug('No control channel to the external tor: $detail');
        if (attempt == _attempt) {
          _setControl(TorControlNotAttached(refusal, detail: detail));
        }
    }
  }

  void _onLinkChange(TorControlLinkEvent change) {
    switch (change) {
      case TorLinkPostureChanged(:final posture):
        _publishAttached(posture);
      case TorLinkLost():
        // With a pin in force the sites were promised it, and only a new
        // link can say whether it still holds: [_connect] holds them and
        // asks again. Without one nothing is at stake but the control
        // channel, which is opened again quietly.
        if (_pinned != null) {
          unawaited(_connect());
        } else {
          unawaited(_reattach());
        }
    }
  }

  Future<void> _reattach() async {
    final attempt = ++_attempt;
    await _dropLink();
    final parsed = splitProxyAddress(_address());
    if (parsed == null || attempt != _attempt) return;
    await _attach(attempt: attempt, socks: parsed);
  }

  void _publishAttached(TorPostureRead posture) {
    _setControl(TorControlAttached(version: _link?.version, gaps: posture.gaps));
  }

  Future<void> _dropLink() async {
    final link = _link;
    _link = null;
    _pinned = null;
    await _linkSub?.cancel();
    _linkSub = null;
    await link?.close();
  }

  void _setControl(ExternalTorControlState state) {
    _controlState = state;
    if (!_controlStates.isClosed) _controlStates.add(state);
  }

  void _fail(String message) {
    _setControl(const TorControlIdle());
    _events.add(TorErrored(message,
        failure: TorFailure(
            kind: TorFailureKind.externalUnreachable, detail: message)));
  }
}
