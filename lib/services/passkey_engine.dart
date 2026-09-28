/// Plans a WebAuthn ceremony for the Credential Manager bridge and completes
/// the provider's answer (PASSKEY-004..009).
///
/// A browser asserting an origin to Android's Credential Manager is trusted
/// by the credential provider to have done the checks a browser does: that
/// the origin is the calling document's, that the document may use WebAuthn,
/// and that the relying party id belongs to that origin. Providers are told
/// to skip the rpId check themselves, so every one of those checks lives
/// here, and nothing the page sends is taken as the origin.
///
/// Pure: no platform channel. The call site passes the bridge's own frame
/// data in, and hands [PasskeyCeremony.requestJson] / [clientDataHash] to the
/// native plugin.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:webspace/web_view_model.dart' show getBaseDomain;

enum PasskeyOp { create, get }

/// Who answers a page's WebAuthn call.
enum PasskeyBackend {
  /// The shim and this app's Credential Manager bridge (PASSKEY-003..009).
  credentialManager,

  /// The WebView's own WebAuthn in FOR_BROWSER mode (PASSKEY-010). The
  /// engine asserts the origin itself; only as good as the WebView build.
  webView,
}

/// A webview's passkey access (PASSKEY-001).
class PasskeyAccess {
  const PasskeyAccess({
    required this.isOnScreen,
    this.backend = PasskeyBackend.credentialManager,
  });

  final PasskeyBackend backend;

  /// Whether this webview's site is the one the user is looking at. A site
  /// loaded behind another must not raise the system passkey sheet, which
  /// names only the rpId and would read as the visible site's request.
  final bool Function() isOnScreen;
}

/// A rejection the page sees as a `DOMException` of [name].
class PasskeyError implements Exception {
  const PasskeyError(this.name, this.message);

  final String name;
  final String message;

  Map<String, Object?> toBridgeJson() =>
      {'ok': false, 'name': name, 'message': message};

  @override
  bool operator ==(Object other) =>
      other is PasskeyError && other.name == name && other.message == message;

  @override
  int get hashCode => Object.hash(name, message);

  @override
  String toString() => 'PasskeyError($name: $message)';

  static const notAllowed = PasskeyError('NotAllowedError',
      'The operation either timed out or was not allowed.');
  static const notFocused =
      PasskeyError('NotAllowedError', 'The document is not focused.');
  static const busy =
      PasskeyError('NotAllowedError', 'A request is already pending.');
  static const crossOriginFrame = PasskeyError('NotAllowedError',
      'Passkeys are not available in a cross-origin frame.');
  static const insecure = PasskeyError(
      'NotAllowedError', 'Passkeys require a secure context.');
  static const badRpId = PasskeyError(
      'SecurityError', 'The relying party ID is not a registrable domain '
      'suffix of, nor equal to the current domain.');
  static const unsupported =
      PasskeyError('NotSupportedError', 'Passkeys are not available.');
  static const unreadable = PasskeyError('NotReadableError',
      'An unknown error occurred while talking to the credential manager.');
  static const excluded = PasskeyError('InvalidStateError',
      'The authenticator already contains one of the excluded credentials.');
  static const aborted =
      PasskeyError('AbortError', 'The operation was aborted.');

  static PasskeyError typeError(String message) =>
      PasskeyError('TypeError', message);
}

/// Everything the native call needs, and what completing its answer needs.
class PasskeyCeremony {
  const PasskeyCeremony({
    required this.op,
    required this.origin,
    required this.rpId,
    required this.requestJson,
    required this.clientDataJson,
    required this.clientDataHash,
  });

  final PasskeyOp op;

  /// The calling document's serialized origin, what the provider is told.
  final String origin;
  final String rpId;

  /// The page's WebAuthn-JSON options with the rp id filled in.
  final String requestJson;

  /// What the page receives as `response.clientDataJSON`. The provider signs
  /// [clientDataHash] and never sees these bytes.
  final String clientDataJson;
  final Uint8List clientDataHash;
}

class PasskeyPlan {
  const PasskeyPlan.ceremony(PasskeyCeremony this.ceremony) : error = null;
  const PasskeyPlan.reject(PasskeyError this.error) : ceremony = null;

  final PasskeyCeremony? ceremony;
  final PasskeyError? error;
}

class PasskeyEngine {
  PasskeyEngine._();

  /// Decide whether the page's request may reach Credential Manager, and
  /// build it (PASSKEY-004..006).
  ///
  /// [frameOrigin] and [isMainFrame] are the bridge's frame data, computed
  /// by the plugin's preamble before page script runs. [topUrl] is the URL
  /// the webview is showing, which a main-frame origin must still match: a
  /// request racing a navigation is refused rather than asserted for a
  /// document that is no longer on screen. [onScreen] is whether this site
  /// is the one the user is looking at.
  static PasskeyPlan plan({
    required Object? op,
    required Object? options,
    required String frameOrigin,
    required bool isMainFrame,
    required String? topUrl,
    required bool onScreen,
  }) {
    final PasskeyOp operation;
    switch (op) {
      case 'create':
        operation = PasskeyOp.create;
      case 'get':
        operation = PasskeyOp.get;
      default:
        return PasskeyPlan.reject(PasskeyError.typeError('Unknown operation.'));
    }
    if (options is! Map) {
      return PasskeyPlan.reject(PasskeyError.typeError('Missing options.'));
    }

    final origin = serializeOrigin(frameOrigin);
    final top = topUrl == null ? null : serializeOrigin(topUrl);
    if (origin == null || top == null) {
      return const PasskeyPlan.reject(PasskeyError.notAllowed);
    }
    if (origin != top) {
      return PasskeyPlan.reject(isMainFrame
          ? PasskeyError.notAllowed
          : PasskeyError.crossOriginFrame);
    }
    if (!onScreen) return const PasskeyPlan.reject(PasskeyError.notFocused);
    final originUri = Uri.parse(origin);
    if (!isPotentiallyTrustworthy(originUri)) {
      return const PasskeyPlan.reject(PasskeyError.insecure);
    }

    final request = _deepCopy(options) as Map<String, Object?>;
    final challenge = _canonicalB64u(request['challenge']);
    if (challenge == null || challenge.isEmpty) {
      return PasskeyPlan.reject(
          PasskeyError.typeError('The challenge is missing.'));
    }
    request['challenge'] = challenge;

    final host = originUri.host.toLowerCase();
    final String rpId;
    if (operation == PasskeyOp.create) {
      final rp = request['rp'];
      final user = request['user'];
      if (rp is! Map || user is! Map) {
        return PasskeyPlan.reject(
            PasskeyError.typeError('rp and user are required.'));
      }
      final userId = _decodeB64u(user['id']);
      if (userId == null || userId.isEmpty || userId.length > 64) {
        return PasskeyPlan.reject(
            PasskeyError.typeError('user.id must be 1 to 64 bytes.'));
      }
      if (user['name'] is! String || user['displayName'] is! String) {
        return PasskeyPlan.reject(
            PasskeyError.typeError('user.name and user.displayName are required.'));
      }
      final rpObj = Map<String, Object?>.from(rp);
      rpId = rpObj['id'] is String ? (rpObj['id'] as String).toLowerCase() : host;
      rpObj['id'] = rpId;
      request['rp'] = rpObj;
    } else {
      rpId = request['rpId'] is String
          ? (request['rpId'] as String).toLowerCase()
          : host;
      request['rpId'] = rpId;
    }
    if (!isValidRpId(rpId, host)) {
      return const PasskeyPlan.reject(PasskeyError.badRpId);
    }

    final clientDataJson = buildClientDataJson(
      type: operation == PasskeyOp.create ? 'webauthn.create' : 'webauthn.get',
      challenge: challenge,
      origin: origin,
    );
    return PasskeyPlan.ceremony(PasskeyCeremony(
      op: operation,
      origin: origin,
      rpId: rpId,
      requestJson: jsonEncode(request),
      clientDataJson: clientDataJson,
      clientDataHash: Uint8List.fromList(
          sha256.convert(utf8.encode(clientDataJson)).bytes),
    ));
  }

  /// RFC 6454 serialization, `scheme://host[:port]` with the default port
  /// dropped; null for anything that is not an http(s) origin.
  static String? serializeOrigin(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasAuthority || uri.host.isEmpty) return null;
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'https' && scheme != 'http') return null;
    var host = uri.host.toLowerCase();
    if (host.contains(':')) host = '[$host]';
    final defaultPort = scheme == 'https' ? 443 : 80;
    final port = uri.hasPort && uri.port != defaultPort ? ':${uri.port}' : '';
    return '$scheme://$host$port';
  }

  /// Secure-context origins: https, or http to the loopback interface.
  static bool isPotentiallyTrustworthy(Uri origin) {
    if (origin.scheme == 'https') return true;
    if (origin.scheme != 'http') return false;
    final host = origin.host.toLowerCase();
    return host == 'localhost' ||
        host.endsWith('.localhost') ||
        host == '::1' ||
        RegExp(r'^127(\.\d{1,3}){3}$').hasMatch(host);
  }

  /// Whether [rpId] is [host] or a registrable domain suffix of it.
  ///
  /// The registrable part comes from [getBaseDomain], the same reading the
  /// app isolates cookies by. It errs long on suffixes it does not know, so
  /// an unknown registry suffix is refused as an rpId rather than accepted.
  static bool isValidRpId(String rpId, String host) {
    final r = rpId.toLowerCase();
    final h = host.toLowerCase();
    if (r.isEmpty) return false;
    if (_isIpLiteral(h)) return r == h;
    if (r != h && !h.endsWith('.$r')) return false;
    final base = getBaseDomain(h);
    return r == base || r.endsWith('.$base');
  }

  /// CollectedClientData in the WebAuthn L3 §5.8.1.1 serialization, which
  /// fixes key order and escaping so an RP's limited verification matches.
  static String buildClientDataJson({
    required String type,
    required String challenge,
    required String origin,
  }) =>
      '{"type":${_ccdString(type)},'
      '"challenge":${_ccdString(challenge)},'
      '"origin":${_ccdString(origin)},'
      '"crossOrigin":false}';

  /// Turn the provider's JSON into what the page receives (PASSKEY-007):
  /// `response.clientDataJSON` becomes ours, since providers given a hash
  /// return a placeholder or JSON of their own that does not hash to what
  /// they signed; and the credential must be for [PasskeyCeremony.rpId].
  static Map<String, Object?> completeResponse(
      PasskeyCeremony ceremony, String responseJson) {
    Object? decoded;
    try {
      decoded = jsonDecode(responseJson);
    } catch (_) {
      return PasskeyError.unreadable.toBridgeJson();
    }
    if (decoded is! Map) return PasskeyError.unreadable.toBridgeJson();
    final credential = Map<String, Object?>.from(decoded);
    final id = credential['id'];
    final response = credential['response'];
    if (id is! String || id.isEmpty || response is! Map) {
      return PasskeyError.unreadable.toBridgeJson();
    }
    final r = Map<String, Object?>.from(response);
    credential['rawId'] = credential['rawId'] is String ? credential['rawId'] : id;
    credential['type'] = 'public-key';
    credential['clientExtensionResults'] =
        credential['clientExtensionResults'] is Map
            ? credential['clientExtensionResults']
            : <String, Object?>{};

    Uint8List? authData;
    if (ceremony.op == PasskeyOp.create) {
      final attestation = _decodeB64u(r['attestationObject']);
      if (attestation == null) return PasskeyError.unreadable.toBridgeJson();
      authData = _decodeB64u(r['authenticatorData']) ??
          attestationAuthData(attestation);
      if (authData == null) return PasskeyError.unreadable.toBridgeJson();
      r['authenticatorData'] = encodeB64u(authData);
    } else {
      authData = _decodeB64u(r['authenticatorData']);
      if (authData == null || _decodeB64u(r['signature']) == null) {
        return PasskeyError.unreadable.toBridgeJson();
      }
    }
    final rpIdHash = sha256.convert(utf8.encode(ceremony.rpId)).bytes;
    if (authData.length < 37 || !_equalBytes(authData.sublist(0, 32), rpIdHash)) {
      return PasskeyError.unreadable.toBridgeJson();
    }
    r['clientDataJSON'] = encodeB64u(utf8.encode(ceremony.clientDataJson));
    credential['response'] = r;
    return {'ok': true, 'credential': credential};
  }

  /// The DOMException a native failure surfaces as (PASSKEY-008). Messages
  /// are fixed strings: a provider's own message can name the provider or
  /// the accounts it holds, and the page is not told either.
  ///
  /// Cancelling, having no passkey and having nowhere to save one all read
  /// as NotAllowedError, as in Chromium: a page must not learn which it was.
  static PasskeyError errorForNative(String code) {
    switch (code) {
      case 'USER_CANCELED':
      case 'NO_CREDENTIAL':
      case 'NO_CREATE_OPTIONS':
      case 'DOM_NOT_ALLOWED':
      case 'DOM_ABORT':
        return PasskeyError.notAllowed;
      case 'DOM_INVALID_STATE':
        return PasskeyError.excluded;
      case 'DOM_SECURITY':
        return PasskeyError.badRpId;
      case 'BUSY':
        return PasskeyError.busy;
      case 'CANCELLED':
        return PasskeyError.aborted;
      case 'SECURITY':
      case 'UNSUPPORTED':
      case 'INVALID_REQUEST':
      case 'DOM_NOT_SUPPORTED':
        return PasskeyError.unsupported;
      default:
        return PasskeyError.unreadable;
    }
  }

  /// The `authData` byte string of a CBOR attestation object, or null when
  /// it is not a well-formed map carrying one.
  static Uint8List? attestationAuthData(Uint8List cbor) {
    try {
      final reader = _CborReader(cbor);
      final head = reader.head();
      if (head.major != 5) return null;
      for (var i = 0; i < head.value; i++) {
        final key = reader.item();
        final value = reader.item();
        if (key == 'authData' && value is Uint8List) return value;
      }
    } on FormatException {
      return null;
    }
    return null;
  }

  static String encodeB64u(List<int> bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');

  static Uint8List? _decodeB64u(Object? value) {
    if (value is! String) return null;
    var s = value.replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '');
    if (s.length % 4 == 1) return null;
    while (s.length % 4 != 0) {
      s += '=';
    }
    try {
      return base64Url.decode(s);
    } on FormatException {
      return null;
    }
  }

  static String? _canonicalB64u(Object? value) {
    final bytes = _decodeB64u(value);
    return bytes == null ? null : encodeB64u(bytes);
  }

  static String _ccdString(String s) {
    final out = StringBuffer('"');
    for (final rune in s.runes) {
      if (rune == 0x22) {
        out.write(r'\"');
      } else if (rune == 0x5c) {
        out.write(r'\\');
      } else if (rune < 0x20) {
        out.write('\\u${rune.toRadixString(16).padLeft(4, '0')}');
      } else {
        out.writeCharCode(rune);
      }
    }
    out.write('"');
    return out.toString();
  }

  static bool _isIpLiteral(String host) =>
      host.contains(':') || RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(host);

  static bool _equalBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  static Object? _deepCopy(Object? v) {
    if (v is Map) {
      return <String, Object?>{
        for (final e in v.entries) '${e.key}': _deepCopy(e.value),
      };
    }
    if (v is List) return [for (final e in v) _deepCopy(e)];
    return v;
  }
}

/// One ceremony at a time, app-wide (PASSKEY-006). Credential Manager shows
/// one sheet, and a second request from another site while it is up would
/// otherwise be answered under the first site's sheet.
class PasskeyCeremonyGate {
  String? _active;

  String? get active => _active;

  bool begin(String key) {
    if (_active != null) return false;
    _active = key;
    return true;
  }

  void end(String key) {
    if (_active == key) _active = null;
  }
}

class _CborHead {
  const _CborHead(this.major, this.value);
  final int major;
  final int value;
}

/// Just enough CBOR to walk an attestation object's top-level map: definite
/// lengths only, which is what CTAP2's canonical encoding produces.
class _CborReader {
  _CborReader(this._bytes);

  final Uint8List _bytes;
  int _pos = 0;
  int _depth = 0;

  int _byte() {
    if (_pos >= _bytes.length) throw const FormatException('truncated');
    return _bytes[_pos++];
  }

  _CborHead head() {
    final initial = _byte();
    final major = initial >> 5;
    final info = initial & 0x1f;
    int value;
    if (info < 24) {
      value = info;
    } else if (info <= 27) {
      final n = 1 << (info - 24);
      if (n == 8) {
        final hi = _uint(4);
        if (hi != 0) throw const FormatException('length too large');
        value = _uint(4);
      } else {
        value = _uint(n);
      }
    } else {
      throw const FormatException('indefinite length');
    }
    return _CborHead(major, value);
  }

  int _uint(int n) {
    var v = 0;
    for (var i = 0; i < n; i++) {
      v = (v << 8) | _byte();
    }
    return v;
  }

  Uint8List _take(int n) {
    if (n < 0 || _pos + n > _bytes.length) {
      throw const FormatException('truncated');
    }
    final out = Uint8List.sublistView(_bytes, _pos, _pos + n);
    _pos += n;
    return out;
  }

  Object? item() {
    if (++_depth > 16) throw const FormatException('too deep');
    try {
      final h = head();
      switch (h.major) {
        case 0:
          return h.value;
        case 1:
          return -1 - h.value;
        case 2:
          return Uint8List.fromList(_take(h.value));
        case 3:
          return utf8.decode(_take(h.value));
        case 4:
          for (var i = 0; i < h.value; i++) {
            item();
          }
          return null;
        case 5:
          for (var i = 0; i < h.value * 2; i++) {
            item();
          }
          return null;
        case 6:
          return item();
        default:
          return null;
      }
    } finally {
      _depth--;
    }
  }
}
