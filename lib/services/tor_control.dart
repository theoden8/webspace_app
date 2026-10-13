// tor's control protocol, as much of it as an external tor needs (TOR-026):
// where the channel is, how its replies are framed, which authentication to
// send, and how to read the answers. No dart:io; the socket lives in
// tor_control_io.dart.
//
// Grammar: tor's control-spec.txt, sections 2 (framing) and 3.5, 3.24
// (PROTOCOLINFO, AUTHCHALLENGE).

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'package:webspace/services/outbound_http_types.dart'
    show splitProxyAddress;

/// Where an external tor's control channel listens.
sealed class TorControlEndpoint {
  const TorControlEndpoint();

  /// [raw] as typed: a Unix socket path (`/run/tor/control`, or tor's own
  /// `unix:/run/tor/control`) or `host:port`. Null for anything else,
  /// including an empty value.
  static TorControlEndpoint? parse(String raw) {
    final value = raw.trim();
    final path = value.startsWith('unix:') ? value.substring(5) : value;
    if (path.startsWith('/')) return TorControlSocket(path);
    final hostPort = splitProxyAddress(value);
    if (hostPort == null) return null;
    return TorControlTcp(hostPort.host, port: hostPort.port);
  }
}

final class TorControlSocket extends TorControlEndpoint {
  const TorControlSocket(this.path);

  final String path;

  @override
  String toString() => 'unix:$path';
}

final class TorControlTcp extends TorControlEndpoint {
  const TorControlTcp(this.host, {required this.port});

  final String host;
  final int port;

  @override
  String toString() => '$host:$port';
}

/// Nothing accepted a connection at the endpoint.
final class TorControlUnreachable implements Exception {
  const TorControlUnreachable(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The channel closed before tor answered.
final class TorControlClosed implements Exception {
  const TorControlClosed();

  @override
  String toString() => "tor's control channel closed.";
}

/// tor answered a command with anything but 250.
final class TorControlRejected implements Exception {
  const TorControlRejected(this.reply, {required this.command});

  final TorControlReply reply;

  /// The command's verb only: an AUTHENTICATE line carries the secret.
  final String command;

  @override
  String toString() => '$command: ${reply.status} ${reply.lines.join(' ')}';
}

/// One reply or asynchronous event from tor.
final class TorControlReply {
  const TorControlReply({required this.status, required this.lines});

  final int status;

  /// Each line's text after the status and its separator. A data block
  /// (`250+key=`, its lines, `.`) is one entry: the head with the data
  /// appended, dot-unescaped and joined by newlines.
  final List<String> lines;

  bool get isOk => status == 250;
  bool get isEvent => status ~/ 100 == 6;
}

/// Splits the lines tor sends into replies and events (control-spec 2.3).
/// tor writes each message whole, so an event never lands inside a reply.
final class TorControlFramer {
  TorControlFramer({required this.onMessage});

  final void Function(TorControlReply message) onMessage;

  int? _status;
  final List<String> _lines = [];
  String? _dataHead;
  final List<String> _data = [];

  /// One line, without its CRLF.
  void addLine(String line) {
    final head = _dataHead;
    if (head != null) {
      if (line == '.') {
        _lines.add('$head${_data.join('\n')}');
        _dataHead = null;
        _data.clear();
      } else {
        _data.add(line.startsWith('.') ? line.substring(1) : line);
      }
      return;
    }
    if (line.length < 4) throw FormatException('Not a control reply line', line);
    final status = int.tryParse(line.substring(0, 3));
    if (status == null) throw FormatException('Not a control reply line', line);
    _status ??= status;
    final text = line.substring(4);
    switch (line[3]) {
      case '-':
        _lines.add(text);
      case '+':
        _dataHead = text;
      case ' ':
        _lines.add(text);
        final message = TorControlReply(status: _status!, lines: List.of(_lines));
        _status = null;
        _lines.clear();
        onMessage(message);
      default:
        throw FormatException('Not a control reply line', line);
    }
  }
}

/// `"text"` with tor's C-style escapes, for a command argument. A line break
/// is escaped too, so a value can never end the command early.
String torQuoted(String value) {
  final escaped = value
      .replaceAll(r'\', r'\\')
      .replaceAll('"', r'\"')
      .replaceAll('\r', r'\r')
      .replaceAll('\n', r'\n');
  return '"$escaped"';
}

/// The quoted string at [start] of [text] (which must be `"`), unescaped,
/// and the index just past its closing quote.
(String, int) _unquote(String text, {required int start}) {
  final out = StringBuffer();
  var i = start + 1;
  while (i < text.length) {
    final c = text[i];
    if (c == '"') return (out.toString(), i + 1);
    if (c == r'\' && i + 1 < text.length) {
      final next = text[i + 1];
      out.write(switch (next) { 'n' => '\n', 't' => '\t', 'r' => '\r', _ => next });
      i += 2;
      continue;
    }
    out.write(c);
    i++;
  }
  throw FormatException('Unterminated quoted string', text);
}

/// `KEY=value KEY="quoted value"` pairs after the first word of [line].
Map<String, String> _keywordArgs(String line) {
  final out = <String, String>{};
  var i = line.indexOf(' ');
  if (i < 0) return out;
  while (i < line.length) {
    while (i < line.length && line[i] == ' ') {
      i++;
    }
    final eq = line.indexOf('=', i);
    if (eq < 0) break;
    final key = line.substring(i, eq);
    if (eq + 1 < line.length && line[eq + 1] == '"') {
      final (value, end) = _unquote(line, start: eq + 1);
      out[key] = value;
      i = end;
    } else {
      final space = line.indexOf(' ', eq);
      final end = space < 0 ? line.length : space;
      out[key] = line.substring(eq + 1, end);
      i = end;
    }
  }
  return out;
}

/// `key=value` lines of a GETINFO or GETCONF reply, every value of a key
/// kept in order. A GETCONF line with no `=` is an option at its default,
/// read as null; the closing `OK` of a GETINFO is skipped.
Map<String, List<String?>> torKeyValues(TorControlReply reply) {
  final out = <String, List<String?>>{};
  for (final line in reply.lines) {
    if (line == 'OK') continue;
    final eq = line.indexOf('=');
    final key = eq < 0 ? line : line.substring(0, eq);
    final value = eq < 0 ? null : line.substring(eq + 1);
    (out[key] ??= []).add(value);
  }
  return out;
}

/// The quoted strings of a GETINFO value such as `net/listeners/socks`.
List<String> torQuotedList(String value) {
  final out = <String>[];
  var i = 0;
  while (i < value.length) {
    if (value[i] == '"') {
      final (item, end) = _unquote(value, start: i);
      out.add(item);
      i = end;
    } else {
      i++;
    }
  }
  return out;
}

enum TorAuthMethod {
  none('NULL'),
  hashedPassword('HASHEDPASSWORD'),
  cookie('COOKIE'),
  safeCookie('SAFECOOKIE');

  const TorAuthMethod(this.wireName);

  final String wireName;
}

/// What PROTOCOLINFO said: how tor will take an AUTHENTICATE, and which
/// tor it is.
final class TorProtocolInfo {
  const TorProtocolInfo({
    required this.methods,
    required this.cookieFile,
    required this.version,
  });

  final Set<TorAuthMethod> methods;
  final String? cookieFile;
  final String? version;

  /// Whether the cookie file is worth reading: only SAFECOOKIE uses it.
  bool get wantsCookie => methods.contains(TorAuthMethod.safeCookie);

  /// Null when [reply] is not a PROTOCOLINFO answer: something that is not
  /// tor's control port.
  static TorProtocolInfo? fromReply(TorControlReply reply) {
    if (!reply.isOk || reply.lines.isEmpty) return null;
    if (!reply.lines.first.startsWith('PROTOCOLINFO ')) return null;
    final methods = <TorAuthMethod>{};
    String? cookieFile;
    String? version;
    for (final line in reply.lines) {
      if (line.startsWith('AUTH ')) {
        final args = _keywordArgs(line);
        for (final name in (args['METHODS'] ?? '').split(',')) {
          for (final method in TorAuthMethod.values) {
            if (method.wireName == name) methods.add(method);
          }
        }
        cookieFile = args['COOKIEFILE'];
      } else if (line.startsWith('VERSION ')) {
        version = _keywordArgs(line)['Tor'];
      }
    }
    return TorProtocolInfo(
        methods: methods, cookieFile: cookieFile, version: version);
  }
}

/// Why the app holds no control channel to an external tor.
enum TorControlRefusal {
  /// Nothing answered at the endpoint, or it did not answer in time.
  unreachable,

  /// Something answered, and not as tor's control port.
  notTor,

  /// tor takes only a password here, and none is saved.
  needsPassword,

  /// tor takes only its cookie here, and the app cannot read the file.
  cookieUnreadable,

  /// tor refused the password or cookie.
  refused,

  /// That control port belongs to a tor whose SOCKS listeners do not
  /// include the address sites use.
  otherTor,
}

/// The AUTHENTICATE to send, in the order a password the user saved, then
/// tor's cookie, is preferred; or why there is none.
sealed class TorAuthPlan {
  const TorAuthPlan();
}

final class TorAuthNull extends TorAuthPlan {
  const TorAuthNull();
}

final class TorAuthPassword extends TorAuthPlan {
  const TorAuthPassword(this.password);

  final String password;
}

final class TorAuthSafeCookie extends TorAuthPlan {
  const TorAuthSafeCookie(this.cookie);

  final Uint8List cookie;
}

final class TorAuthImpossible extends TorAuthPlan {
  const TorAuthImpossible(this.refusal);

  final TorControlRefusal refusal;
}

/// tor's cookie is 32 bytes; anything else read from its path is not one.
const int kTorCookieLength = 32;

/// Which authentication to send. A failed AUTHENTICATE closes the channel,
/// so there is one attempt: no auth when tor needs none, the saved password
/// when tor takes one, else SAFECOOKIE.
///
/// Never plain COOKIE: the cookie's path comes from whatever answers at the
/// endpoint, which could name any file, and COOKIE sends its bytes. Under
/// SAFECOOKIE the listener proves it read the file before the app sends
/// anything derived from it. Every tor since 0.2.3 offers it beside COOKIE.
TorAuthPlan planTorAuth({
  required TorProtocolInfo info,
  required String? password,
  required Uint8List? cookie,
}) {
  final methods = info.methods;
  if (methods.contains(TorAuthMethod.none)) return const TorAuthNull();
  final takesPassword = methods.contains(TorAuthMethod.hashedPassword);
  if (takesPassword && password != null && password.isNotEmpty) {
    return TorAuthPassword(password);
  }
  final usable = cookie != null && cookie.length == kTorCookieLength;
  final safeCookie = methods.contains(TorAuthMethod.safeCookie);
  if (usable && safeCookie) return TorAuthSafeCookie(cookie);
  if (takesPassword) {
    return const TorAuthImpossible(TorControlRefusal.needsPassword);
  }
  if (safeCookie) {
    return const TorAuthImpossible(TorControlRefusal.cookieUnreadable);
  }
  return const TorAuthImpossible(TorControlRefusal.refused);
}

/// SAFECOOKIE's two HMACs over cookie, client nonce and server nonce
/// (control-spec 3.24).
final class TorSafeCookieExchange {
  const TorSafeCookieExchange({
    required this.cookie,
    required this.clientNonce,
    required this.serverNonce,
  });

  final List<int> cookie;
  final List<int> clientNonce;
  final List<int> serverNonce;

  static const String _serverKey =
      'Tor safe cookie authentication server-to-controller hash';
  static const String _clientKey =
      'Tor safe cookie authentication controller-to-server hash';

  List<int> _mac(String key) => Hmac(sha256, ascii.encode(key))
      .convert([...cookie, ...clientNonce, ...serverNonce]).bytes;

  /// What tor must have sent as SERVERHASH, proving it read the cookie.
  List<int> get serverHash => _mac(_serverKey);

  /// What the app sends to AUTHENTICATE.
  List<int> get clientHash => _mac(_clientKey);

  /// SERVERHASH and SERVERNONCE from an AUTHCHALLENGE reply, or null.
  static ({List<int> hash, List<int> nonce})? challengeOf(
      TorControlReply reply) {
    if (!reply.isOk || reply.lines.isEmpty) return null;
    final line = reply.lines.first;
    if (!line.startsWith('AUTHCHALLENGE ')) return null;
    final args = _keywordArgs(line);
    final hash = hexBytes(args['SERVERHASH'] ?? '');
    final nonce = hexBytes(args['SERVERNONCE'] ?? '');
    if (hash == null || nonce == null) return null;
    return (hash: hash, nonce: nonce);
  }
}

String hexOf(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// Bytes of an even-length hex string, or null.
List<int>? hexBytes(String hex) {
  if (hex.isEmpty || hex.length.isOdd) return null;
  final out = <int>[];
  for (var i = 0; i < hex.length; i += 2) {
    final byte = int.tryParse(hex.substring(i, i + 2), radix: 16);
    if (byte == null) return null;
    out.add(byte);
  }
  return out;
}

/// Equal without an early exit, for comparing a MAC.
bool sameBytes(List<int> a, {required List<int> other}) {
  if (a.length != other.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ other[i];
  }
  return diff == 0;
}
