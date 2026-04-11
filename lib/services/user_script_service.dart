import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:http/http.dart' as http;

import 'package:webspace/services/log_service.dart';
import 'package:webspace/settings/user_script.dart';

/// JavaScript shim that intercepts <script src="..."> DOM insertions and
/// provides a CORS-bypassing fetch function for user scripts.
///
/// When user scripts create script elements with external sources, the browser
/// would block them via CSP. This shim catches those insertions, sends the URL
/// to Dart for fetching, and the content is injected natively via
/// evaluateJavascript (which bypasses CSP).
///
/// Also exposes `window.__wsFetch(url)` which returns a `Response` object,
/// useful for libraries like Dark Reader that need `setFetchMethod()`.
///
/// Security:
/// - Handler names are randomized per webview instance (placeholders replaced
///   at runtime) so page code cannot guess or call them.
/// - callHandler reference is captured lazily on first use.
/// - Only whitelisted CDN URLs are intercepted for script loading; other URLs
///   fall through to normal (CSP-governed) DOM behavior.
const String _shimTemplate = r'''
(function() {
  if (window.__wsFetchShimInstalled) return;
  window.__wsFetchShimInstalled = true;
  var _origAppend = Node.prototype.appendChild;
  var _origInsert = Node.prototype.insertBefore;
  var SCRIPT_HANDLER = '__SCRIPT_HANDLER_NAME__';
  var FETCH_HANDLER = '__FETCH_HANDLER_NAME__';

  // Lazily capture the bridge reference. At DOCUMENT_START the
  // flutter_inappwebview bridge may not be injected yet. By the time
  // user scripts actually call appendChild or __wsFetch (after the
  // library <script> loads), the bridge will be available.
  var _call = null;
  function call() {
    if (!_call) {
      if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
        _call = window.flutter_inappwebview.callHandler.bind(window.flutter_inappwebview);
      }
    }
    if (!_call) return null;
    return _call.apply(null, arguments);
  }

  var WHITELIST = __WHITELIST_JSON__;

  function isFetchableUrl(url) {
    if (typeof url !== 'string' || url.length === 0) return false;
    var lower = url.toLowerCase();
    return lower.indexOf('http://') === 0 || lower.indexOf('https://') === 0;
  }

  function isWhitelistedUrl(url) {
    if (!isFetchableUrl(url)) return false;
    try {
      var host = new URL(url).hostname.toLowerCase();
      for (var i = 0; i < WHITELIST.length; i++) {
        if (host === WHITELIST[i] || host.endsWith('.' + WHITELIST[i])) return true;
      }
    } catch(e) {}
    return false;
  }

  function intercept(scriptEl) {
    var url = scriptEl.src;
    // Only intercept whitelisted CDN URLs. Site scripts (e.g.,
    // platform.linkedin.com) fall through to normal DOM behavior.
    if (!isWhitelistedUrl(url)) return null;
    var result = call(SCRIPT_HANDLER, url);
    if (!result) return null;
    var onload = scriptEl.onload;
    var onerror = scriptEl.onerror;
    result.then(function(ok) {
      if (ok) { if (onload) try { onload.call(scriptEl); } catch(e) {} }
      else { if (onerror) try { onerror.call(scriptEl, new Error('fetch failed')); } catch(e) {} }
    }).catch(function(e) {
      if (onerror) try { onerror.call(scriptEl, e); } catch(e2) {}
    });
    return scriptEl;
  }

  Node.prototype.appendChild = function(child) {
    if (child instanceof HTMLScriptElement && child.src) {
      var result = intercept(child);
      if (result) return result;
    }
    return _origAppend.call(this, child);
  };
  Node.prototype.insertBefore = function(child, ref) {
    if (child instanceof HTMLScriptElement && child.src) {
      var result = intercept(child);
      if (result) return result;
    }
    return _origInsert.call(this, child, ref);
  };

  // CORS-bypassing fetch for user scripts. Returns a standard Response object.
  // Usage: DarkReader.setFetchMethod(window.__wsFetch);
  window.__wsFetch = function(url) {
    var urlStr = typeof url === 'string' ? url : url.toString();
    if (!isFetchableUrl(urlStr)) {
      return Promise.reject(new Error('__wsFetch: only http/https URLs supported'));
    }
    var result = call(FETCH_HANDLER, urlStr);
    if (!result) {
      return Promise.reject(new Error('__wsFetch: bridge not available'));
    }
    return result.then(function(r) {
      if (r && r.body !== undefined) {
        return new Response(r.body, {
          status: r.status || 200,
          headers: r.contentType ? { 'Content-Type': r.contentType } : {},
        });
      }
      return new Response('', { status: 500 });
    });
  };

  // Patch window.fetch to fall back to __wsFetch on CORS errors.
  // This makes libraries like Dark Reader work transparently without
  // needing setFetchMethod — cross-origin stylesheet fetches that fail
  // due to CORS are automatically retried via the Dart HTTP client.
  var _origFetch = window.fetch.bind(window);
  window.fetch = function(input, init) {
    return _origFetch(input, init).catch(function(err) {
      var url = typeof input === 'string' ? input : (input && input.url ? input.url : '');
      if (isFetchableUrl(url)) {
        return window.__wsFetch(url);
      }
      throw err;
    });
  };
})();
''';

/// Max size for fetched resources (5 MB).
const int _maxFetchBytes = 5 * 1024 * 1024;

/// Manages user script injection, external dependency resolution, and
/// CORS-bypassing fetch for webviews.
class UserScriptService {
  /// Prepared shim JS with handler names baked in, or null if no user scripts.
  final String? shimScript;
  final String _scriptHandlerName;
  final String _fetchHandlerName;
  final bool hasScripts;
  final List<UserScriptConfig> _scripts;
  final Future<bool> Function(String url)? _onConfirmScriptFetch;

  UserScriptService._({
    required this.shimScript,
    required String scriptHandlerName,
    required String fetchHandlerName,
    required this.hasScripts,
    required List<UserScriptConfig> scripts,
    required Future<bool> Function(String url)? onConfirmScriptFetch,
  })  : _scriptHandlerName = scriptHandlerName,
        _fetchHandlerName = fetchHandlerName,
        _scripts = scripts,
        _onConfirmScriptFetch = onConfirmScriptFetch;

  /// Create a service instance for the given user scripts.
  factory UserScriptService({
    required List<UserScriptConfig> scripts,
    Future<bool> Function(String url)? onConfirmScriptFetch,
  }) {
    final hasScripts = scripts.any((s) => s.enabled && s.fullSource.isNotEmpty);
    final ts = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final scriptHandlerName = '__ws_s_$ts';
    final fetchHandlerName = '__ws_f_$ts';

    String? shimScript;
    if (hasScripts) {
      final whitelistJson = '[${scriptFetchWhitelist.map((d) => '"$d"').join(',')}]';
      shimScript = _shimTemplate
          .replaceAll('__SCRIPT_HANDLER_NAME__', scriptHandlerName)
          .replaceAll('__FETCH_HANDLER_NAME__', fetchHandlerName)
          .replaceAll('__WHITELIST_JSON__', whitelistJson);
    }

    return UserScriptService._(
      shimScript: shimScript,
      scriptHandlerName: scriptHandlerName,
      fetchHandlerName: fetchHandlerName,
      hasScripts: hasScripts,
      scripts: scripts,
      onConfirmScriptFetch: onConfirmScriptFetch,
    );
  }

  /// Build the list of [inapp.UserScript]s to pass to initialUserScripts.
  /// Includes the shim (at DOCUMENT_START) followed by user scripts.
  List<inapp.UserScript> buildInitialUserScripts() {
    final result = <inapp.UserScript>[];
    if (!hasScripts) return result;

    // Shim first (at DOCUMENT_START, before user scripts)
    if (shimScript != null) {
      result.add(inapp.UserScript(
        groupName: 'script_fetch_shim',
        source: shimScript!,
        injectionTime: inapp.UserScriptInjectionTime.AT_DOCUMENT_START,
      ));
    }

    // User scripts
    LogService.instance.log('UserScript', 'createWebView: ${_scripts.length} user scripts configured');
    for (final script in _scripts) {
      final src = script.fullSource;
      if (!script.enabled || src.isEmpty) {
        LogService.instance.log('UserScript', 'Skipping "${script.name}" (enabled=${script.enabled}, empty=${src.isEmpty})');
        continue;
      }
      final time = script.injectionTime == UserScriptInjectionTime.atDocumentStart ? 'DOCUMENT_START' : 'DOCUMENT_END';
      LogService.instance.log('UserScript', 'Adding to initialUserScripts: "${script.name}" at $time (${src.length} chars, url=${script.url ?? "none"})');
      result.add(inapp.UserScript(
        groupName: 'user_scripts',
        source: src,
        injectionTime: script.injectionTime == UserScriptInjectionTime.atDocumentStart
            ? inapp.UserScriptInjectionTime.AT_DOCUMENT_START
            : inapp.UserScriptInjectionTime.AT_DOCUMENT_END,
      ));
    }
    return result;
  }

  /// Register JS handlers on the controller for script fetching and
  /// CORS-bypassing resource fetching.
  void registerHandlers(inapp.InAppWebViewController controller) {
    if (!hasScripts) return;

    // Script handler: fetches URL and injects content as JS via evaluateJavascript.
    controller.addJavaScriptHandler(handlerName: _scriptHandlerName, callback: (args) async {
      if (args.isEmpty || args[0] is! String) return false;
      final url = args[0] as String;
      final status = classifyScriptFetchUrl(url);
      if (status == ScriptFetchUrlStatus.blocked) {
        LogService.instance.log('UserScript', 'Blocked script fetch: $url');
        return false;
      }
      if (status == ScriptFetchUrlStatus.requiresConfirmation) {
        if (_onConfirmScriptFetch == null) {
          LogService.instance.log('UserScript', 'Blocked non-whitelisted URL (no confirmation handler): $url');
          return false;
        }
        final approved = await _onConfirmScriptFetch!(url);
        if (!approved) {
          LogService.instance.log('UserScript', 'User denied script fetch: $url');
          return false;
        }
      }
      LogService.instance.log('UserScript', 'Fetching external script: $url');
      try {
        final response = await http.get(Uri.parse(url));
        if (response.statusCode == 200) {
          if (response.body.length > _maxFetchBytes) {
            LogService.instance.log('UserScript', 'Rejected: response too large (${response.body.length} bytes, max $_maxFetchBytes)');
            return false;
          }
          LogService.instance.log('UserScript', 'Injecting fetched script (${response.body.length} bytes)');
          await controller.evaluateJavascript(source: response.body);
          return true;
        }
        LogService.instance.log('UserScript', 'Fetch failed: HTTP ${response.statusCode}');
      } catch (e) {
        LogService.instance.log('UserScript', 'Fetch failed: $e');
      }
      return false;
    });

    // Resource fetch handler: fetches URL and returns body as text.
    // Used by window.__wsFetch() for CORS-bypassing fetch (e.g., Dark Reader
    // needs to read cross-origin stylesheets via setFetchMethod).
    controller.addJavaScriptHandler(handlerName: _fetchHandlerName, callback: (args) async {
      if (args.isEmpty || args[0] is! String) return {'status': 400};
      final url = args[0] as String;
      final status = classifyScriptFetchUrl(url);
      if (status == ScriptFetchUrlStatus.blocked) {
        LogService.instance.log('UserScript', 'Blocked resource fetch: $url');
        return {'status': 403};
      }
      try {
        final response = await http.get(Uri.parse(url));
        if (response.body.length > _maxFetchBytes) {
          LogService.instance.log('UserScript', 'Resource too large: ${response.body.length} bytes');
          return {'status': 413};
        }
        final contentType = response.headers['content-type'] ?? '';
        return {
          'status': response.statusCode,
          'body': response.body,
          'contentType': contentType,
        };
      } catch (e) {
        LogService.instance.log('UserScript', 'Resource fetch failed: $e');
        return {'status': 500};
      }
    });
  }

  /// Re-inject the shim and atDocumentStart user scripts. Call from onLoadStart.
  Future<void> reinjectOnLoadStart(inapp.InAppWebViewController controller) async {
    if (!hasScripts) return;
    if (shimScript != null) {
      await controller.evaluateJavascript(source: shimScript!);
    }
    for (final script in _scripts) {
      final src = script.fullSource;
      if (!script.enabled || src.isEmpty) continue;
      if (script.injectionTime == UserScriptInjectionTime.atDocumentStart) {
        LogService.instance.log('UserScript', 'onLoadStart: re-injecting "${script.name}" (${src.length} chars)');
        await controller.evaluateJavascript(source: src);
      }
    }
  }

  /// Re-inject atDocumentEnd user scripts. Call from onLoadStop.
  Future<void> reinjectOnLoadStop(inapp.InAppWebViewController controller) async {
    if (!hasScripts) return;
    for (final script in _scripts) {
      final src = script.fullSource;
      if (!script.enabled || src.isEmpty) continue;
      if (script.injectionTime == UserScriptInjectionTime.atDocumentEnd) {
        LogService.instance.log('UserScript', 'onLoadStop: re-injecting "${script.name}" (${src.length} chars)');
        await controller.evaluateJavascript(source: src);
      }
    }
  }

  /// Re-run user scripts' custom source (not the URL library) on SPA
  /// navigations. Called from onUpdateVisitedHistory when the URL changes
  /// without a full page load. The library (urlSource) is already loaded
  /// in the page context, so only the user's own code needs to re-run
  /// (e.g., `DarkReader.enable()` after a SPA route change).
  Future<void> reinjectOnSpaNavigation(inapp.InAppWebViewController controller) async {
    if (!hasScripts) return;
    for (final script in _scripts) {
      if (!script.enabled || script.source.isEmpty) continue;
      LogService.instance.log('UserScript', 'SPA navigation: re-running "${script.name}" source (${script.source.length} chars)');
      // Wrap in void function to suppress return value (avoids
      // "unsupported type" errors from evaluateJavascript).
      await controller.evaluateJavascript(source: '(function(){${script.source}})();');
    }
  }
}
