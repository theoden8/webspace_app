/// Answers a site's own HTTP authentication challenge (HTTPAUTH-001..007).
///
/// A server protected by `auth_basic` / an htpasswd file (or Digest, NTLM,
/// Negotiate) answers `401` with `WWW-Authenticate`, and the platform hands
/// the challenge to `onReceivedHttpAuthRequest`. Returning nothing there is
/// the platform's cancel, which renders the server's "401 Authorization
/// Required" body. This engine decides, per challenge, whether to answer
/// with a saved credential, ask the user, or leave it to the platform.
///
/// Pure: no platform channel. The call site maps the platform's challenge
/// in, and a non-null [HttpAuthCredential] out to `PROCEED`.
library;

import 'package:webspace/web_view_model.dart' show getBaseDomain;

/// A username / password pair the network stack answers a challenge with.
class HttpAuthCredential {
  const HttpAuthCredential({required this.username, required this.password});

  final String username;
  final String password;

  @override
  bool operator ==(Object other) =>
      other is HttpAuthCredential &&
      other.username == username &&
      other.password == password;

  @override
  int get hashCode => Object.hash(username, password);

  /// Never the password: a credential that reaches a log line or an error
  /// message through string interpolation must not carry the secret.
  @override
  String toString() => 'HttpAuthCredential(username: $username)';
}

/// What a site may do with the credentials the user types (HTTPAUTH-004).
enum HttpAuthMemory {
  /// Nothing is read from or written to the device: archive-tier sites,
  /// whose `siteId` must not appear in app-tier secure storage (ARCH-001).
  off,

  /// Saved credentials answer challenges, but nothing new is saved:
  /// incognito sites, the way a private window still fills saved passwords.
  readOnly,

  /// Saved credentials answer challenges and the prompt offers to save.
  readWrite,
}

/// Per-site credential storage, keyed by the challenge's protection space.
///
/// The key is (host, realm) and not the origin: Android's callback carries
/// no port and no scheme (`AwHttpAuthHandler` forwards only host and realm),
/// so anything finer would never match there.
abstract class HttpAuthCredentialStore {
  Future<HttpAuthCredential?> lookup(String siteId, String host, String realm);
  Future<void> save(
    String siteId,
    String host,
    String realm,
    HttpAuthCredential credential,
  );
  Future<void> remove(String siteId, String host, String realm);
}

/// The platform's challenge, reduced to what the policy reads.
class HttpAuthChallengeInfo {
  const HttpAuthChallengeInfo({
    required this.host,
    this.realm,
    this.isProxy = false,
    this.platformRetry = false,
  });

  final String host;
  final String? realm;

  /// A `407` from a proxy. Only Apple and Linux can say so; Android drops
  /// `is_proxy`, which is why the router check has to run first.
  final bool isProxy;

  /// The platform reports an earlier credential for this protection space
  /// failed. False on Android, whose failure count is one process-wide
  /// static that every webview's challenges increment.
  final bool platformRetry;
}

/// What the prompt is asked to show.
class HttpAuthPromptRequest {
  const HttpAuthPromptRequest({
    required this.host,
    required this.isRetry,
    required this.canRemember,
    this.initialUsername,
    this.rememberByDefault = false,
  });

  final String host;

  /// The last credential offered for this protection space was rejected.
  final bool isRetry;

  /// Whether to offer "Remember for this site" at all.
  final bool canRemember;

  final String? initialUsername;
  final bool rememberByDefault;
}

/// What the user typed. Null from the prompt means cancel.
class HttpAuthPromptResult {
  const HttpAuthPromptResult({
    required this.username,
    required this.password,
    this.remember = false,
  });

  final String username;
  final String password;
  final bool remember;
}

typedef HttpAuthPrompt = Future<HttpAuthPromptResult?> Function(
    HttpAuthPromptRequest request);

/// One webview's answers to HTTP authentication challenges.
///
/// Holds state for the lifetime of one webview: which protection spaces it
/// has already supplied a credential for, and the prompt in flight for each.
/// A popup or nested webview builds its own session over the same store.
class HttpAuthSession {
  HttpAuthSession({
    required this.siteId,
    required this.siteUrl,
    required this.memory,
    required this.store,
    this.prompt,
  });

  /// Owner of saved credentials; null for a webview that belongs to no
  /// site, which therefore neither reads nor saves any.
  final String? siteId;

  /// The page the webview was opened for. Challenges are answered only for
  /// hosts on its base domain (HTTPAUTH-002).
  final String? siteUrl;

  final HttpAuthMemory memory;
  final HttpAuthCredentialStore store;
  final HttpAuthPrompt? prompt;

  final Set<String> _supplied = <String>{};
  final Map<String, Future<HttpAuthCredential?>> _inFlight = {};

  /// The username last sent for each protection space, so a refused sign-in
  /// reopens with it even when it was not saved. Never the password.
  final Map<String, String> _lastUsername = {};

  static String _normalizeHost(String host) {
    var h = host.trim().toLowerCase();
    if (h.startsWith('[') && h.endsWith(']')) {
      h = h.substring(1, h.length - 1);
    }
    if (h.endsWith('.')) h = h.substring(0, h.length - 1);
    return h;
  }

  /// Whether [host] shares [siteUrl]'s base domain, the unit the app
  /// already isolates cookies and keeps navigations in-webview by. A private
  /// suffix (`github.io`) is not a base domain, so a page on one
  /// `github.io` subdomain cannot raise a prompt for another.
  static bool isSiteHost(String host, String? siteUrl) {
    if (siteUrl == null) return false;
    final siteHost = _normalizeHost(Uri.tryParse(siteUrl)?.host ?? '');
    final h = _normalizeHost(host);
    if (siteHost.isEmpty || h.isEmpty) return false;
    return getBaseDomain(h) == getBaseDomain(siteHost);
  }

  /// The storage key for a challenge's protection space.
  static ({String host, String realm}) protectionSpace(
    String host,
    String? realm,
  ) =>
      (host: _normalizeHost(host), realm: realm ?? '');

  /// The credential to answer [challenge] with, or null to leave it to the
  /// platform (which cancels and renders the server's `401` body).
  ///
  /// Concurrent challenges for one protection space share one answer: a page
  /// whose images sit behind the same htpasswd fires several at once, and
  /// they must not stack one dialog each.
  Future<HttpAuthCredential?> answer(HttpAuthChallengeInfo challenge) {
    if (challenge.isProxy) return Future.value(null);
    if (!isSiteHost(challenge.host, siteUrl)) return Future.value(null);
    final space = protectionSpace(challenge.host, challenge.realm);
    final key = '${space.host}\n${space.realm}';
    final pending = _inFlight[key];
    if (pending != null) return pending;
    final result = _resolve(challenge, space, key);
    _inFlight[key] = result;
    return result.whenComplete(() => _inFlight.remove(key));
  }

  Future<HttpAuthCredential?> _resolve(
    HttpAuthChallengeInfo challenge,
    ({String host, String realm}) space,
    String key,
  ) async {
    final owner = siteId;
    final readsSaved = owner != null && memory != HttpAuthMemory.off;
    final saved =
        readsSaved ? await store.lookup(owner, space.host, space.realm) : null;
    final retry = challenge.platformRetry || _supplied.contains(key);

    // A saved credential is offered once per webview. Being asked again for
    // the same protection space means the network stack no longer holds it,
    // which in practice means the server refused it; offering it again
    // would loop against the server with no way out.
    if (saved != null && !retry) {
      _supplied.add(key);
      return saved;
    }

    final ask = prompt;
    if (ask == null) return null;
    final canRemember = owner != null && memory == HttpAuthMemory.readWrite;
    final result = await ask(HttpAuthPromptRequest(
      host: space.host,
      isRetry: retry,
      canRemember: canRemember,
      initialUsername: saved?.username ?? _lastUsername[key],
      rememberByDefault: saved != null,
    ));
    if (result == null) {
      // A later challenge for this space is a fresh attempt, not a retry.
      _supplied.remove(key);
      return null;
    }
    final credential = HttpAuthCredential(
      username: result.username,
      password: result.password,
    );
    _supplied.add(key);
    _lastUsername[key] = result.username;
    if (canRemember) {
      if (result.remember) {
        await store.save(owner, space.host, space.realm, credential);
      } else if (saved != null) {
        await store.remove(owner, space.host, space.realm);
      }
    }
    return credential;
  }
}
