// What went wrong with the embedded Tor runtime, classified.
//
// Tor does not fail one way. A censored network stalls bootstrap at a low
// percentage with the directory authorities unreachable; a wrong device
// clock makes tor refuse to build circuits at all with an otherwise healthy
// network; a `StrictNodes` exit pin with no usable exit is a dead end that
// looks like a hang; and the control channel can fail before tor is even
// asked to do anything. Those need different words and different remedies,
// so an opaque string behind one icon is not enough (TOR-015).
//
// Pure Dart on purpose: classification is decidable from the signals alone,
// so it lives here and is unit-tested per kind rather than needing a device
// that is actually censored or actually clock-skewed.

/// Why Tor is not usable. Ordered roughly by how actionable it is.
enum TorFailureKind {
  /// No usable network at all — tor could not reach anything.
  offline,

  /// Reachable network, but the directory authorities and guards are not.
  /// The signature of a censoring middlebox. The remedy is bridges, which
  /// this release does not ship, so say so rather than implying a retry
  /// will help.
  censored,

  /// The device clock is far enough off that tor refuses to build
  /// circuits. Cheap to fix and impossible to guess at from a spinner.
  clockSkew,

  /// An exit-country pin is in force and no exit in that country is
  /// usable. `StrictNodes 1` makes this fatal rather than a fallback.
  exitPolicy,

  /// The plugin could not attach to, authenticate with, or read the port
  /// file of tor's control channel. A defect on our side, not the user's.
  controlChannel,

  /// Bootstrap ran past its deadline without a terminal signal.
  bootstrapTimeout,

  /// Anything else: the thread died, or a message we have no pattern for.
  runtime,
}

/// A classified Tor failure, carrying both the machine-readable [kind] used
/// to pick the UI copy and the raw signals a bug report needs.
class TorFailure {
  const TorFailure({
    required this.kind,
    required this.detail,
    this.torTag,
    this.torReason,
    this.recommendation,
    this.atPercent,
  });

  /// Which class of failure this is; drives the user-facing explanation.
  final TorFailureKind kind;

  /// Raw underlying message, verbatim. Shown as secondary detail and
  /// carried into logs — never the only thing a user is shown.
  final String detail;

  /// tor's own `BOOTSTRAP` fields, when the failure came from bootstrap.
  /// `TAG` names the phase (`conn_dir`, `handshake_dir`, `onehop_create`,
  /// …), `REASON` the transport-level cause (`CONNECTREFUSED`, `TIMEOUT`,
  /// `NOROUTE`, …).
  final String? torTag;
  final String? torReason;

  /// tor's `RECOMMENDATION` (`warn` / `ignore`). `ignore` means tor expects
  /// to recover on its own, so it must not be surfaced as a hard failure.
  final String? recommendation;

  /// Bootstrap percentage when it stalled. Low values point at reachability
  /// (the directory fetch), high values at circuit building.
  final int? atPercent;

  /// Whether tor expects to recover without intervention.
  bool get isTransient => recommendation == 'ignore';

  @override
  String toString() {
    final parts = <String>['${kind.name}: $detail'];
    if (torTag != null) parts.add('tag=$torTag');
    if (torReason != null) parts.add('reason=$torReason');
    if (atPercent != null) parts.add('at=$atPercent%');
    return parts.join(' ');
  }
}

/// tor `REASON` values that mean "nothing on this network answered".
const Set<String> _offlineReasons = {'NOROUTE', 'RESOURCELIMIT'};

/// tor `REASON` values that mean "something answered, but wrongly" — the
/// shape a filtering middlebox produces.
const Set<String> _censorReasons = {
  'CONNECTREFUSED',
  'CONNECTRESET',
  'TIMEOUT',
  'IDENTITY',
  'MISC',
};

/// Classify a failure from whatever signals are available.
///
/// [message] is the raw text from the plugin or the engine. The rest are
/// tor's own bootstrap fields when the failure arrived that way. Matching
/// is deliberately ordered most-specific first: a clock-skew message also
/// contains the word "circuit", and an exit-pin failure also looks like a
/// reachability failure if you only read the percentage.
TorFailure classifyTorFailure(
  String message, {
  String? torTag,
  String? torReason,
  String? recommendation,
  int? atPercent,
  bool hadExitPin = false,
  bool timedOut = false,
}) {
  final m = message.toLowerCase();

  TorFailure of(TorFailureKind kind) => TorFailure(
        kind: kind,
        detail: message,
        torTag: torTag,
        torReason: torReason,
        recommendation: recommendation,
        atPercent: atPercent,
      );

  // Clock skew first: tor reports it as a general status, and its text
  // mentions circuits, which every other branch below also does.
  if (m.contains('clock') && (m.contains('skew') || m.contains('behind') ||
      m.contains('ahead'))) {
    return of(TorFailureKind.clockSkew);
  }

  // Our own control-channel plumbing. These are the plugin's messages and
  // are never the user's fault, so they must not be reported as censorship.
  if (m.contains('control port') ||
      m.contains('control cookie') ||
      m.contains('control authentication') ||
      m.contains('no usable socks listener')) {
    return of(TorFailureKind.controlChannel);
  }

  // An exit pin in force turns an otherwise ordinary circuit failure into a
  // dead end, so it outranks the reachability branches below.
  if (m.contains('exit-country') || m.contains('exitnodes')) {
    return of(TorFailureKind.exitPolicy);
  }
  if (hadExitPin && (atPercent == null || atPercent >= 80)) {
    // Bootstrap got as far as building circuits and then stopped, with a
    // strict pin in force: the pin is the likeliest reason no circuit
    // completes.
    return of(TorFailureKind.exitPolicy);
  }

  if (torReason != null) {
    final r = torReason.toUpperCase();
    if (_offlineReasons.contains(r)) return of(TorFailureKind.offline);
    if (_censorReasons.contains(r)) return of(TorFailureKind.censored);
  }

  if (m.contains('offline') ||
      m.contains('no route') ||
      m.contains('network is unreachable')) {
    return of(TorFailureKind.offline);
  }

  // A stall in the directory phase is the classic censorship signature:
  // the network is up (we got far enough to try) but nothing tor needs
  // answers.
  if (timedOut) {
    final stalledEarly = atPercent != null && atPercent < 80;
    final dirPhase = torTag != null &&
        (torTag.startsWith('conn_dir') ||
            torTag.startsWith('handshake_dir') ||
            torTag == 'requesting_status' ||
            torTag == 'loading_status' ||
            torTag == 'requesting_descriptors' ||
            torTag == 'loading_descriptors');
    if (stalledEarly || dirPhase) return of(TorFailureKind.censored);
    return of(TorFailureKind.bootstrapTimeout);
  }

  return of(TorFailureKind.runtime);
}
