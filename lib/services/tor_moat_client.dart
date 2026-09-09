// Moat: fetch obfs4 bridges from BridgeDB when the network blocks Tor.
//
// ## This request is observable, deliberately
//
// Every other outbound seam in the app routes through the per-site or
// app-global proxy (LEAK-007). This one cannot: it exists precisely because
// Tor is not reachable, so there is no circuit to carry it. A moat fetch
// therefore goes out direct, and a network observer sees a TLS connection to
// bridges.torproject.org — which in a censoring environment is close to
// announcing "this user is trying to obtain Tor bridges".
//
// That is inherent to asking a public service for bridges over the network
// the service is being blocked on. The real mitigation is domain fronting
// (moat over meek), which is what the protocol was designed for and what we
// do not have yet: [MoatClient] takes its `http.Client` from the caller
// precisely so a fronted transport can be supplied later without touching
// this file. Until then the UI must say plainly that fetching bridges is
// visible to the network, and offer pasting a bridge line obtained
// elsewhere (email, a friend, https://bridges.torproject.org over some
// other path) as the private alternative.
//
// ## Wire format
//
// Verified against the live service rather than the documentation, which is
// stale in three ways that each would have been a bug: `transport` comes
// back as a *list*, the captcha `image` is JPEG rather than PNG, and
// `challenge` is currently just the transport name rather than an opaque
// token. The client round-trips `challenge` verbatim regardless of what it
// contains, so a return to opaque tokens needs no change here.
//
// Spec: openspec/specs/tor-proxy/spec.md (TOR-016).

import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'package:webspace/services/tor_bridges.dart';

/// Where BridgeDB answers. Not configurable by the user: a moat endpoint is
/// a trust anchor for the bridges it hands out, and letting a hostile value
/// in here would let an attacker hand the user bridges it controls.
const String kMoatBaseUrl = 'https://bridges.torproject.org/moat';

/// How a moat exchange failed. Each maps to its own message: "could not get
/// bridges" is useless to someone deciding whether to change networks or
/// paste a line by hand.
enum MoatErrorKind {
  /// The request never completed — no route, TLS failure, timeout. On a
  /// censored network this is itself the expected outcome, and the UI has
  /// to say so rather than implying the service is down.
  unreachable,

  /// A response arrived but was not the shape moat documents.
  malformed,

  /// The service rejected the captcha solution.
  wrongSolution,

  /// The exchange succeeded but produced no line we can use.
  noBridges,
}

class MoatException implements Exception {
  const MoatException(this.kind, [this.detail]);
  final MoatErrorKind kind;
  final String? detail;

  @override
  String toString() => 'MoatException(${kind.name}${detail == null ? '' : ': $detail'})';
}

/// Outcome of [MoatClient.obtainBridges]: either we already have bridges, or
/// the service wants a human.
sealed class MoatAttempt {
  const MoatAttempt();
}

/// Bridges obtained with no captcha shown.
class MoatBridgesObtained extends MoatAttempt {
  const MoatBridgesObtained(this.lines);
  final List<TorBridgeLine> lines;
}

/// The service rejected the empty solution: show [challenge] and submit the
/// user's answer with [MoatClient.submitSolution].
class MoatCaptchaRequired extends MoatAttempt {
  const MoatCaptchaRequired(this.challenge);
  final MoatChallenge challenge;
}

/// A captcha to show the user, plus the token that must come back with the
/// answer.
class MoatChallenge {
  const MoatChallenge({
    required this.transport,
    required this.challenge,
    required this.imageBytes,
  });

  /// Transport these bridges will be for.
  final TorTransport transport;

  /// Opaque to us: whatever the service sent, returned verbatim.
  final String challenge;

  /// Decoded captcha image. JPEG at the time of writing, but decoded by the
  /// image widget rather than assumed here.
  final Uint8List imageBytes;
}

/// Talks the moat JSON-API. Stateless; construct per exchange.
class MoatClient {
  MoatClient({
    http.Client? client,
    this.baseUrl = kMoatBaseUrl,
    this.timeout = const Duration(seconds: 30),
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final String baseUrl;
  final Duration timeout;

  static const Map<String, String> _headers = {
    'Content-Type': 'application/vnd.api+json',
    'Accept': 'application/vnd.api+json',
  };

  /// Ask for a captcha for [transport].
  Future<MoatChallenge> fetchChallenge(TorTransport transport) async {
    final body = jsonEncode({
      'data': [
        {
          'version': '0.1.0',
          'type': 'client-transports',
          'supported': [transport.wireName],
        }
      ]
    });

    final decoded = await _post('$baseUrl/fetch', body);
    final entry = _firstData(decoded);

    final image = entry['image'];
    final challenge = entry['challenge'];
    if (image is! String || challenge is! String) {
      throw const MoatException(
          MoatErrorKind.malformed, 'challenge missing image or token');
    }

    final Uint8List bytes;
    try {
      bytes = base64Decode(image);
    } on FormatException catch (e) {
      throw MoatException(MoatErrorKind.malformed, 'captcha not base64: $e');
    }
    if (bytes.isEmpty) {
      throw const MoatException(MoatErrorKind.malformed, 'empty captcha image');
    }

    return MoatChallenge(
      transport: transport,
      challenge: challenge,
      imageBytes: bytes,
    );
  }

  /// Get bridges, asking the user to solve a captcha only if the service
  /// insists on one.
  ///
  /// BridgeDB currently issues a captcha and then accepts any answer,
  /// including an empty one (verified against the live service). Making
  /// someone read distorted text that is not checked is pure friction, so
  /// the empty solution goes first. It is an honest request rather than a
  /// forged one: it says "I have no answer", and if the service ever starts
  /// caring it will say so and we fall back to [MoatCaptchaRequired].
  ///
  /// Only [MoatErrorKind.wrongSolution] becomes a captcha prompt. An
  /// unreachable service or a malformed reply is not something a human can
  /// solve, so those propagate.
  Future<MoatAttempt> obtainBridges(TorTransport transport) async {
    final challenge = await fetchChallenge(transport);
    try {
      return MoatBridgesObtained(await submitSolution(challenge, ''));
    } on MoatException catch (e) {
      if (e.kind == MoatErrorKind.wrongSolution) {
        return MoatCaptchaRequired(challenge);
      }
      rethrow;
    }
  }

  /// Submit [solution] and get bridge lines back.
  ///
  /// Called directly by the UI once the user has answered a captcha that
  /// [obtainBridges] reported as required.
  Future<List<TorBridgeLine>> submitSolution(
    MoatChallenge challenge,
    String solution,
  ) async {
    final body = jsonEncode({
      'data': [
        {
          'id': '2',
          'version': '0.1.0',
          'type': 'moat-solution',
          'transport': challenge.transport.wireName,
          'challenge': challenge.challenge,
          'solution': solution,
          'qrcode': 'false',
        }
      ]
    });

    final decoded = await _post('$baseUrl/check', body);

    // An error document rather than bridges: moat reports a wrong captcha
    // this way when it is validating them.
    final errors = decoded['errors'];
    if (errors is List && errors.isNotEmpty) {
      final first = errors.first;
      final detail = first is Map ? '${first['detail'] ?? first}' : '$first';
      throw MoatException(MoatErrorKind.wrongSolution, detail);
    }

    final entry = _firstData(decoded);
    final raw = entry['bridges'];
    if (raw is! List) {
      throw const MoatException(
          MoatErrorKind.malformed, 'no bridges array in response');
    }

    final lines = <TorBridgeLine>[];
    for (final item in raw) {
      if (item is! String) continue;
      final parsed = parseTorBridgeLine(item);
      // Silently skipping an unparseable line is right here: BridgeDB may
      // hand out a transport this build does not run, and one such line
      // must not discard the others.
      if (parsed.isOk) lines.add(parsed.line!);
    }
    if (lines.isEmpty) {
      throw const MoatException(MoatErrorKind.noBridges,
          'the service returned no line this build can use');
    }
    return lines;
  }

  Future<Map<String, Object?>> _post(String url, String body) async {
    http.Response response;
    try {
      response = await _client
          .post(Uri.parse(url), headers: _headers, body: body)
          .timeout(timeout);
    } catch (e) {
      // Includes the timeout and every socket failure. On a censored
      // network this is the expected path, not an exceptional one.
      throw MoatException(MoatErrorKind.unreachable, '${e.runtimeType}');
    }

    if (response.statusCode != 200) {
      throw MoatException(
          MoatErrorKind.unreachable, 'HTTP ${response.statusCode}');
    }

    try {
      final decoded = jsonDecode(response.body);
      if (decoded is! Map) {
        throw const MoatException(MoatErrorKind.malformed, 'not a JSON object');
      }
      return decoded.cast<String, Object?>();
    } on MoatException {
      rethrow;
    } catch (e) {
      throw MoatException(MoatErrorKind.malformed, 'bad JSON: ${e.runtimeType}');
    }
  }

  Map<String, Object?> _firstData(Map<String, Object?> decoded) {
    final data = decoded['data'];
    if (data is! List || data.isEmpty || data.first is! Map) {
      throw const MoatException(MoatErrorKind.malformed, 'no data entry');
    }
    return (data.first as Map).cast<String, Object?>();
  }
}
