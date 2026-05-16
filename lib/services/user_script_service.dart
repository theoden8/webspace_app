import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;

import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/services/user_script_shim.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/settings/user_script.dart';

// The shim JS template and [buildUserScriptShim] live in
// `user_script_shim.dart` (pure Dart, no Flutter imports) so the fixture
// dumper at `tool/dump_shim_js.dart` can reach them under `fvm dart run`.
export 'package:webspace/services/user_script_shim.dart'
    show buildUserScriptShim, userScriptShimTemplate;

const int _maxFetchBytes = 5 * 1024 * 1024;

/// Evaluate JS without triggering "unsupported type" serialization errors.
/// WebKit (macOS/iOS) errors when evaluateJavascript returns `undefined`;
/// appending `;null;` returns a serializable value, and try-catch ensures
/// a stale error never breaks callers.
Future<void> _safeEval(inapp.InAppWebViewController c, String source) async {
  try {
    await c.evaluateJavascript(source: '$source\n;null;');
  } catch (e) {
    LogService.instance.log('UserScript', 'evaluateJavascript non-fatal: $e');
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
    required List<UserScriptConfig> scripts,
    required Future<bool> Function(String url)? onConfirmScriptFetch,
    required UserProxySettings proxy,
  })  : _scriptHandlerName = scriptHandlerName,
        _fetchHandlerName = fetchHandlerName,
        _inlineScriptHandlerName = inlineScriptHandlerName,
        _scripts = scripts,
        _onConfirmScriptFetch = onConfirmScriptFetch,
        _proxy = proxy;

  /// Create a service instance for the given user scripts.
  factory UserScriptService({
    required List<UserScriptConfig> scripts,
    Future<bool> Function(String url)? onConfirmScriptFetch,
    UserProxySettings? proxy,
  }) {
    final hasScripts = scripts.any((s) => s.enabled && s.fullSource.isNotEmpty);
    final ts = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final scriptHandlerName = '__ws_s_$ts';
    final fetchHandlerName = '__ws_f_$ts';
    final inlineScriptHandlerName = '__ws_i_$ts';

    String? shimScript;
    if (hasScripts) {
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

    // Shim first (at DOCUMENT_START, before user scripts).
    // Append ";null;" so WebKit doesn't error on undefined return value.
    if (shimScript != null) {
      result.add(inapp.UserScript(
        groupName: 'script_fetch_shim',
        source: '${shimScript!}\n;null;',
        injectionTime: inapp.UserScriptInjectionTime.AT_DOCUMENT_START,
      ));
    }

    // User scripts
    LogService.instance.log('UserScript', 'createWebView: ${_scripts.length} user scripts configured');
    for (final script in _scripts) {
      final src = _buildSource(script);
      if (!script.enabled || src.isEmpty) {
        LogService.instance.log('UserScript', 'Skipping "${script.name}" (enabled=${script.enabled}, empty=${src.isEmpty})');
        continue;
      }
      final time = script.injectionTime == UserScriptInjectionTime.atDocumentStart ? 'DOCUMENT_START' : 'DOCUMENT_END';
      LogService.instance.log('UserScript', 'Adding to initialUserScripts: "${script.name}" at $time (${src.length} chars, url=${script.url ?? "none"})');
      result.add(inapp.UserScript(
        groupName: 'user_scripts',
        source: '${_guarded(script.id, src)}\n;null;',
        injectionTime: script.injectionTime == UserScriptInjectionTime.atDocumentStart
            ? inapp.UserScriptInjectionTime.AT_DOCUMENT_START
            : inapp.UserScriptInjectionTime.AT_DOCUMENT_END,
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
      final clientResult = outboundHttp.clientFor(resolveEffectiveProxy(_proxy));
      if (clientResult is OutboundClientBlocked) {
        LogService.instance.log(
          'UserScript',
          'Blocked external script fetch: ${clientResult.reason}',
        );
        return false;
      }
      final client = (clientResult as OutboundClientReady).client;
      try {
        final response = await client.get(Uri.parse(url));
        if (response.statusCode == 200) {
          if (response.body.length > _maxFetchBytes) {
            LogService.instance.log('UserScript', 'Rejected: response too large (${response.body.length} bytes, max $_maxFetchBytes)');
            return false;
          }
          LogService.instance.log('UserScript', 'Injecting fetched script (${response.body.length} bytes)');
          await _safeEval(controller, response.body);
          return true;
        }
        LogService.instance.log('UserScript', 'Fetch failed: HTTP ${response.statusCode}');
      } catch (e) {
        LogService.instance.log('UserScript', 'Fetch failed: $e');
      } finally {
        client.close();
      }
      return false;
    });

    // Inline-script handler: takes a captured <script>{textContent} source
    // string and evaluates it via the privileged Dart bridge, bypassing
    // page CSP. Fire-and-forget — the JS side doesn't await a result.
    controller.addJavaScriptHandler(handlerName: _inlineScriptHandlerName, callback: (args) async {
      if (args.isEmpty || args[0] is! String) return null;
      final source = args[0] as String;
      if (source.isEmpty) return null;
      LogService.instance.log('UserScript', 'Inline script bridged (${source.length} bytes)');
      await _safeEval(controller, source);
      return null;
    });

    // Resource fetch handler: fetches URL and returns body as text.
    // Used by window.__wsFetch() for CORS-bypassing fetch (e.g., reading
    // cross-origin stylesheets).
    controller.addJavaScriptHandler(handlerName: _fetchHandlerName, callback: (args) async {
      if (args.isEmpty || args[0] is! String) return {'status': 400};
      final url = args[0] as String;
      final status = classifyScriptFetchUrl(url);
      if (status == ScriptFetchUrlStatus.blocked) {
        LogService.instance.log('UserScript', 'Blocked resource fetch: $url');
        return {'status': 403};
      }
      final clientResult = outboundHttp.clientFor(resolveEffectiveProxy(_proxy));
      if (clientResult is OutboundClientBlocked) {
        LogService.instance.log(
          'UserScript',
          'Blocked resource fetch: ${clientResult.reason}',
        );
        return {'status': 403};
      }
      final client = (clientResult as OutboundClientReady).client;
      try {
        final response = await client.get(Uri.parse(url));
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
      } finally {
        client.close();
      }
    });
  }

  /// Build injectable source for a user script.
  /// Returns the full source (urlSource + source concatenation).
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
  Future<void> reinjectOnLoadStart(inapp.InAppWebViewController controller) async {
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
        LogService.instance.log('UserScript', 'onLoadStart: re-injecting "${script.name}" (${src.length} chars)');
        await _safeEval(controller, _guarded(script.id, src));
      }
    }
  }

  /// Re-inject atDocumentEnd user scripts. Call from onLoadStop.
  ///
  /// Scripts with [urlSource] are skipped — same rationale as
  /// [reinjectOnLoadStart].
  Future<void> reinjectOnLoadStop(inapp.InAppWebViewController controller) async {
    if (!hasScripts) return;
    for (final script in _scripts) {
      if (!script.enabled) continue;
      if (script.urlSource != null && script.urlSource!.isNotEmpty) continue;
      final src = _buildSource(script);
      if (src.isEmpty) continue;
      if (script.injectionTime == UserScriptInjectionTime.atDocumentEnd) {
        LogService.instance.log('UserScript', 'onLoadStop: re-injecting "${script.name}" (${src.length} chars)');
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
  Future<void> reinjectOnSpaNavigation(inapp.InAppWebViewController controller) async {
    if (!hasScripts) return;
    for (final script in _scripts) {
      if (!script.enabled || script.source.isEmpty) continue;
      LogService.instance.log('UserScript', 'SPA nav: re-running "${script.name}" source (${script.source.length} chars)');
      final safeName = script.name.replaceAll('"', '\\"');
      await _safeEval(controller, 'console.log("__ws: SPA re-inject: $safeName");\n${script.source}');
    }
  }
}
