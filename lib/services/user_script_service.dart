import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:http/http.dart' as http;

import 'package:webspace/services/host_resolution.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/services/page_shim.dart';
import 'package:webspace/services/url_host.dart';
import 'package:webspace/services/user_script_shim.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/settings/user_script.dart';

// The shim JS template and [buildUserScriptShim] live in
// `user_script_shim.dart` (pure Dart, no Flutter imports) so the fixture
// dumper at `tool/dump_shim_js.dart` can reach them under `fvm dart run`.
export 'package:webspace/services/user_script_shim.dart'
    show buildUserScriptShim, userScriptShimTemplate;

/// Result of validating a URL for script fetching.
enum ScriptFetchUrlStatus {
  /// URL is on the trusted whitelist — fetch without confirmation.
  whitelisted,

  /// URL is valid http/https but not whitelisted — requires user confirmation.
  requiresConfirmation,

  /// URL scheme is blocked (javascript:, data:, blob:, file://) or invalid.
  blocked,
}

/// Validate a URL for script fetching and classify it.
///
/// Returns [ScriptFetchUrlStatus.whitelisted] for trusted CDN domains,
/// [ScriptFetchUrlStatus.requiresConfirmation] for other http/https URLs,
/// and [ScriptFetchUrlStatus.blocked] for dangerous or invalid URLs.
ScriptFetchUrlStatus classifyScriptFetchUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return ScriptFetchUrlStatus.blocked;

  final scheme = uri.scheme.toLowerCase();

  if (scheme != 'http' && scheme != 'https') {
    return ScriptFetchUrlStatus.blocked;
  }

  final host = Host(uri.host);
  if (host.isEmpty) return ScriptFetchUrlStatus.blocked;

  // SSRF guard, literal half: window.__wsFetch is a page-reachable global, so
  // any script on a user-script-enabled site (including third-party page
  // scripts) can drive this fetch. Block loopback / private / link-local
  // literal hosts so it can't reach localhost services, the LAN, or cloud
  // metadata (169.254.169.254). A hostname that *resolves* into one of those
  // ranges is not visible here and is caught by the resolving half below,
  // which runs where the fetch is about to happen and knows whether we are
  // the ones resolving it.
  if (isPrivateOrLoopbackHost(host)) {
    return ScriptFetchUrlStatus.blocked;
  }

  for (final domain in scriptFetchWhitelist) {
    if (host == domain || host.endsWith('.$domain')) {
      return ScriptFetchUrlStatus.whitelisted;
    }
  }

  return ScriptFetchUrlStatus.requiresConfirmation;
}

const int _maxFetchBytes = 5 * 1024 * 1024;

/// Redirect hops a bridged fetch will follow before giving up.
const int _maxFetchRedirects = 5;

bool _isRedirect(int status) =>
    status == 301 ||
    status == 302 ||
    status == 303 ||
    status == 307 ||
    status == 308;

/// GET [url] with the client's own redirect following switched off, running
/// every `Location` back through [allow] before the next hop.
///
/// `http` follows redirects transparently, and the URL classification only
/// ever sees the first hop — so a public host answering
/// `302 Location: http://169.254.169.254/…` would hand the private-network
/// body straight back to page JS. Returns null when a hop is refused or the
/// chain outruns [_maxFetchRedirects].
Future<http.Response?> _getWithCheckedRedirects(
  http.Client client,
  String url,
  Future<bool> Function(String url) allow,
) async {
  var target = Uri.parse(url);
  for (var hop = 0; hop <= _maxFetchRedirects; hop++) {
    final request = http.Request('GET', target)..followRedirects = false;
    final response = await http.Response.fromStream(await client.send(request));
    final location = response.headers['location'];
    if (!_isRedirect(response.statusCode) ||
        location == null ||
        location.isEmpty) {
      return response;
    }
    final next = target.resolve(location);
    if (!await allow(next.toString())) {
      LogTag.userScript.debug(
          'Blocked redirect target: $next', sensitive: true);
      return null;
    }
    target = next;
  }
  LogTag.userScript.debug('Too many redirects for $url', sensitive: true);
  return null;
}

/// Whether the bridge may connect to [url], given the [effective] proxy.
///
/// The literal classification in `classifyScriptFetchUrl` refuses an address
/// the URL spells out. This is the half it cannot do: when *we* are the ones
/// resolving, the name is resolved and the answer checked against the same
/// ranges, so `http://evil.example/` whose A record is `127.0.0.1` is refused
/// instead of handing the page whatever listens on loopback (US-DR-007).
///
/// A name that does not resolve is refused, which only turns a connect error
/// into an earlier one. Where nothing here did the resolving — a proxy, or a
/// build with no resolver — the call goes through; see [classifyOutboundTarget]
/// for why, and for what this does not close.
Future<bool> _resolvedTargetAllowed(
  String url,
  UserProxySettings effective,
) async {
  final verdict = await classifyOutboundTarget(url, effective);
  if (verdict == HostRangeVerdict.public ||
      verdict == HostRangeVerdict.notResolvedHere) {
    return true;
  }
  LogTag.userScript.debug(verdict == HostRangeVerdict.private
      ? 'Blocked $url: resolves into a private range'
      : 'Blocked $url: does not resolve', sensitive: true);
  return false;
}

/// Fetch user-script source at [url] through the proxy seam, applying the
/// same URL classification and redirect re-checking the page-reachable
/// bridge uses. Returns the body, or a short technical detail the caller
/// localizes into its own failure message.
Future<({String? source, String? error})> fetchUserScriptSource(
  String url, {
  UserProxySettings? proxy,
}) async {
  final effective = resolveEffectiveProxy(
    proxy ?? UserProxySettings(type: ProxyType.DEFAULT),
    siteId: null,
  );
  Future<bool> allowed(String candidate) async =>
      classifyScriptFetchUrl(candidate) != ScriptFetchUrlStatus.blocked &&
      await _resolvedTargetAllowed(candidate, effective);
  if (!await allowed(url)) return (source: null, error: 'blocked URL');
  final http.Client client;
  switch (outboundHttp.clientFor(effective)) {
    case OutboundClientBlocked(:final reason):
      return (source: null, error: reason);
    case OutboundClientReady(client: final ready):
      client = ready;
  }
  try {
    final response = await _getWithCheckedRedirects(
      client,
      url,
      allowed,
    );
    if (response == null) return (source: null, error: 'blocked redirect');
    if (response.statusCode != 200) {
      return (source: null, error: 'HTTP ${response.statusCode}');
    }
    return (source: response.body, error: null);
  } catch (e) {
    return (source: null, error: e.toString());
  } finally {
    client.close();
  }
}

/// Evaluate JS without triggering "unsupported type" serialization errors.
/// WebKit (macOS/iOS) errors when evaluateJavascript returns `undefined`;
/// appending `;null;` returns a serializable value, and try-catch ensures
/// a stale error never breaks callers.
Future<void> _safeEval(inapp.InAppWebViewController c, String source) async {
  try {
    await c.evaluateJavascript(source: '$source\n;null;');
  } catch (e) {
    LogTag.userScript.debug('evaluateJavascript non-fatal: $e');
  }
}

/// Manages user script injection, external dependency resolution, and
/// CORS-bypassing fetch for webviews.
class UserScriptService {
  /// Prepared shim JS with handler names baked in, or null if no user scripts.
  final String? shimScript;
  final String _scriptHandlerName;
  final String _fetchHandlerName;
  final String _inlineScriptHandlerName;
  final bool hasScripts;

  /// Whether any enabled script asked for the privileged bridge. The bridge is
  /// page-realm machinery — globals and prototype wrappers — so it cannot be
  /// scoped to the script that wanted it; installing it takes the site's CSP
  /// and same-origin policy down for every script on the page. It is therefore
  /// installed only when a script explicitly asks (US-DR-005).
  final bool hasPrivilegedBridge;
  final List<UserScriptConfig> _scripts;
  final Future<bool> Function(String url)? _onConfirmScriptFetch;

  /// Per-site proxy of the site this service belongs to. Resolved through
  /// the per-site → global precedence ladder when the JS handlers fetch
  /// external script/resource URLs.
  final UserProxySettings _proxy;

  UserScriptService._({
    required this.shimScript,
    required String scriptHandlerName,
    required String fetchHandlerName,
    required String inlineScriptHandlerName,
    required this.hasScripts,
    required this.hasPrivilegedBridge,
    required List<UserScriptConfig> scripts,
    required Future<bool> Function(String url)? onConfirmScriptFetch,
    required UserProxySettings proxy,
  }) : _scriptHandlerName = scriptHandlerName,
       _fetchHandlerName = fetchHandlerName,
       _inlineScriptHandlerName = inlineScriptHandlerName,
       _scripts = scripts,
       _onConfirmScriptFetch = onConfirmScriptFetch,
       _proxy = proxy;

  factory UserScriptService({
    required List<UserScriptConfig> scripts,
    Future<bool> Function(String url)? onConfirmScriptFetch,
    UserProxySettings? proxy,
  }) {
    final hasScripts = scripts.any((s) => s.enabled && s.fullSource.isNotEmpty);
    final hasPrivilegedBridge = scripts.any(
      (s) => s.enabled && s.fullSource.isNotEmpty && s.bypassSitePolicy,
    );
    final ts = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final scriptHandlerName = '__ws_s_$ts';
    final fetchHandlerName = '__ws_f_$ts';
    final inlineScriptHandlerName = '__ws_i_$ts';

    String? shimScript;
    if (hasPrivilegedBridge) {
      shimScript = buildUserScriptShim(
        scriptHandlerName: scriptHandlerName,
        fetchHandlerName: fetchHandlerName,
        inlineScriptHandlerName: inlineScriptHandlerName,
      );
    }

    return UserScriptService._(
      shimScript: shimScript,
      scriptHandlerName: scriptHandlerName,
      fetchHandlerName: fetchHandlerName,
      inlineScriptHandlerName: inlineScriptHandlerName,
      hasScripts: hasScripts,
      hasPrivilegedBridge: hasPrivilegedBridge,
      scripts: scripts,
      onConfirmScriptFetch: onConfirmScriptFetch,
      proxy: proxy ?? UserProxySettings(type: ProxyType.DEFAULT),
    );
  }

  /// Build the list of [inapp.UserScript]s to pass to initialUserScripts.
  /// Includes the shim (at DOCUMENT_START) followed by user scripts.
  List<inapp.UserScript> buildInitialUserScripts() {
    final result = <inapp.UserScript>[];
    if (!hasScripts) return result;

    if (shimScript != null) {
      result.add(pageShim('script_fetch_shim', shimScript!,
          frames: ShimFrames.top));
    }

    LogTag.userScript.debug(
        'createWebView: ${_scripts.length} user scripts configured');
    for (final script in _scripts) {
      final src = _buildSource(script);
      if (!script.enabled || src.isEmpty) {
        LogTag.userScript.debug(
            'Skipping "${script.name}" (enabled=${script.enabled}, empty=${src.isEmpty})',
            sensitive: true);
        continue;
      }
      final time =
          script.injectionTime == UserScriptInjectionTime.atDocumentStart
          ? 'DOCUMENT_START'
          : 'DOCUMENT_END';
      LogTag.userScript.debug(
          'Adding to initialUserScripts: "${script.name}" at $time (${src.length} chars, url=${script.url ?? "none"})',
          sensitive: true);
      result.add(pageShim(
        'user_scripts',
        _guarded(script.id, src),
        frames: ShimFrames.top,
        at: switch (script.injectionTime) {
          UserScriptInjectionTime.atDocumentStart => ShimTime.start,
          UserScriptInjectionTime.atDocumentEnd => ShimTime.end,
        },
      ));
    }
    return result;
  }

  /// Wrap [source] in a once-per-document guard so the same script does not
  /// run twice when [initialUserScripts] (native WKUserScript) and
  /// [reinjectOnLoadStart]/[reinjectOnLoadStop] (evaluateJavascript) both
  /// fire on a full page load.
  ///
  /// The flag lives on `window`, which is fresh per document, so guards
  /// never need explicit resetting. SPA re-injection (where `window`
  /// persists) deliberately bypasses this helper so that scripts can
  /// re-initialize on route changes.
  static String _guarded(String scriptId, String source) {
    final safeId = scriptId.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_');
    return 'if (!window.__wsRan_$safeId) { window.__wsRan_$safeId = true;\n$source\n}';
  }

  /// Whether the script handler may fetch [url]: classification plus, for
  /// anything off the whitelist, the user's confirmation. Applied to the
  /// initial URL and again to every redirect target, so a whitelisted CDN
  /// cannot hop the fetch onto an origin the user never approved.
  Future<bool> _allowScriptFetch(String url) async {
    final status = classifyScriptFetchUrl(url);
    if (status == ScriptFetchUrlStatus.blocked) {
      LogTag.userScript.debug('Blocked script fetch: $url', sensitive: true);
      return false;
    }
    // Before the prompt, not after: a name resolving into a private range is
    // refused outright, never offered to the user as a choice. The dialog
    // shows a URL, and `http://cdn.evil.example/lib.js` reads as a CDN
    // whatever it resolves to.
    if (!await _resolvedTargetAllowed(
        url, resolveEffectiveProxy(_proxy, siteId: null))) {
      return false;
    }
    if (status == ScriptFetchUrlStatus.requiresConfirmation) {
      if (_onConfirmScriptFetch == null) {
        LogTag.userScript.debug(
            'Blocked non-whitelisted URL (no confirmation handler): $url',
            sensitive: true);
        return false;
      }
      if (!await _onConfirmScriptFetch(url)) {
        LogTag.userScript.debug(
            'User denied script fetch: $url', sensitive: true);
        return false;
      }
    }
    return true;
  }

  /// Register JS handlers on the controller for script fetching and
  /// CORS-bypassing resource fetching.
  void registerHandlers(inapp.InAppWebViewController controller) {
    // No bridge, no handlers: the shim that reaches them is not injected
    // either, and a handler nothing can call is still a handler anything on
    // the page could call if it learned the name.
    if (!hasPrivilegedBridge) return;

    // Script handler: fetches URL and injects content as JS via evaluateJavascript.
    controller.addJavaScriptHandler(
      handlerName: _scriptHandlerName,
      callback: (args) async {
        if (args.isEmpty || args[0] is! String) return false;
        final url = args[0] as String;
        if (!await _allowScriptFetch(url)) return false;
        LogTag.userScript.debug(
            'Fetching external script: $url', sensitive: true);
        final http.Client client;
        switch (outboundHttp.clientFor(
          resolveEffectiveProxy(_proxy, siteId: null),
        )) {
          case OutboundClientBlocked(:final reason):
            LogTag.userScript.debug('Blocked external script fetch: $reason');
            return false;
          case OutboundClientReady(client: final ready):
            client = ready;
        }
        try {
          final response = await _getWithCheckedRedirects(
            client,
            url,
            _allowScriptFetch,
          );
          if (response == null) return false;
          if (response.statusCode == 200) {
            if (response.body.length > _maxFetchBytes) {
              LogTag.userScript.debug(
                  'Rejected: response too large (${response.body.length} bytes, max $_maxFetchBytes)');
              return false;
            }
            LogTag.userScript.debug(
                'Injecting fetched script (${response.body.length} bytes)');
            await _safeEval(controller, response.body);
            return true;
          }
          LogTag.userScript.debug('Fetch failed: HTTP ${response.statusCode}');
        } catch (e) {
          LogTag.userScript.debug('Fetch failed: $e');
        } finally {
          client.close();
        }
        return false;
      },
    );

    // Inline-script handler: takes a captured <script>{textContent} source
    // string and evaluates it via the privileged Dart bridge, bypassing
    // page CSP. Fire-and-forget — the JS side doesn't await a result.
    controller.addJavaScriptHandler(
      handlerName: _inlineScriptHandlerName,
      callback: (args) async {
        if (args.isEmpty || args[0] is! String) return null;
        final source = args[0] as String;
        if (source.isEmpty) return null;
        LogTag.userScript.debug(
            'Inline script bridged (${source.length} bytes)');
        await _safeEval(controller, source);
        return null;
      },
    );

    // Resource fetch handler: fetches URL and returns body as text.
    // Used by window.__wsFetch() for CORS-bypassing fetch (e.g., reading
    // cross-origin stylesheets).
    controller.addJavaScriptHandler(
      handlerName: _fetchHandlerName,
      callback: (args) async {
        if (args.isEmpty || args[0] is! String) return {'status': 400};
        final url = args[0] as String;
        final effective = resolveEffectiveProxy(_proxy, siteId: null);
        Future<bool> reachable(String candidate) async =>
            classifyScriptFetchUrl(candidate) !=
                ScriptFetchUrlStatus.blocked &&
            await _resolvedTargetAllowed(candidate, effective);
        if (!await reachable(url)) {
          LogTag.userScript.debug(
              'Blocked resource fetch: $url', sensitive: true);
          return {'status': 403};
        }
        final http.Client client;
        switch (outboundHttp.clientFor(effective)) {
          case OutboundClientBlocked(:final reason):
            LogTag.userScript.debug('Blocked resource fetch: $reason');
            return {'status': 403};
          case OutboundClientReady(client: final ready):
            client = ready;
        }
        try {
          final response = await _getWithCheckedRedirects(
            client,
            url,
            reachable,
          );
          if (response == null) return {'status': 403};
          if (response.body.length > _maxFetchBytes) {
            LogTag.userScript.debug(
                'Resource too large: ${response.body.length} bytes');
            return {'status': 413};
          }
          final contentType = response.headers['content-type'] ?? '';
          return {
            'status': response.statusCode,
            'body': response.body,
            'contentType': contentType,
          };
        } catch (e) {
          LogTag.userScript.debug('Resource fetch failed: $e');
          return {'status': 500};
        } finally {
          client.close();
        }
      },
    );
  }

  static String _buildSource(UserScriptConfig script) {
    return script.fullSource;
  }

  /// Re-inject the shim and atDocumentStart user scripts. Call from onLoadStart.
  ///
  /// Scripts with [urlSource] (cached library) are skipped — they are already
  /// handled by [initialUserScripts] (WKUserScript / native injection) which
  /// persists across navigations. Re-injecting large libraries via
  /// evaluateJavascript at onLoadStart races with the JS context setup and
  /// causes ReferenceErrors.
  Future<void> reinjectOnLoadStart(
    inapp.InAppWebViewController controller,
  ) async {
    if (!hasScripts) return;
    if (shimScript != null) {
      await _safeEval(controller, shimScript!);
    }
    for (final script in _scripts) {
      if (!script.enabled) continue;
      // Scripts with urlSource are injected via initialUserScripts (native
      // mechanism). Re-injecting here races with WKUserScript timing.
      if (script.urlSource != null && script.urlSource!.isNotEmpty) continue;
      final src = _buildSource(script);
      if (src.isEmpty) continue;
      if (script.injectionTime == UserScriptInjectionTime.atDocumentStart) {
        LogTag.userScript.debug(
            'onLoadStart: re-injecting "${script.name}" (${src.length} chars)',
            sensitive: true);
        await _safeEval(controller, _guarded(script.id, src));
      }
    }
  }

  /// Re-inject atDocumentEnd user scripts. Call from onLoadStop.
  ///
  /// Scripts with [urlSource] are skipped — same rationale as
  /// [reinjectOnLoadStart].
  Future<void> reinjectOnLoadStop(
    inapp.InAppWebViewController controller,
  ) async {
    if (!hasScripts) return;
    for (final script in _scripts) {
      if (!script.enabled) continue;
      if (script.urlSource != null && script.urlSource!.isNotEmpty) continue;
      final src = _buildSource(script);
      if (src.isEmpty) continue;
      if (script.injectionTime == UserScriptInjectionTime.atDocumentEnd) {
        LogTag.userScript.debug(
            'onLoadStop: re-injecting "${script.name}" (${src.length} chars)',
            sensitive: true);
        await _safeEval(controller, _guarded(script.id, src));
      }
    }
  }

  /// Re-run user scripts' custom source (not the URL library) on SPA
  /// navigations. Called from onUpdateVisitedHistory when the URL changes
  /// without a full page load.
  ///
  /// On SPA navigations the JS context persists, so the library (urlSource)
  /// is still loaded. We only re-run the user's [source] code to re-trigger
  /// initialization (e.g. re-running a library's enable() call).
  Future<void> reinjectOnSpaNavigation(
    inapp.InAppWebViewController controller,
  ) async {
    if (!hasScripts) return;
    for (final script in _scripts) {
      if (!script.enabled || script.source.isEmpty) continue;
      LogTag.userScript.debug(
          'SPA nav: re-running "${script.name}" source (${script.source.length} chars)',
          sensitive: true);
      final safeName = script.name.replaceAll('"', '\\"');
      await _safeEval(
        controller,
        'console.log("__ws: SPA re-inject: $safeName");\n${script.source}',
      );
    }
  }
}
