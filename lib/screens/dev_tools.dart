import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' show ConsoleMessageLevel;
import 'package:share_plus/share_plus.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/screens/add_site.dart' show FaviconUrlCache;
import 'package:webspace/services/container_cookie_manager.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/services/icon_png_export.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/content_blocker_service.dart';
import 'package:webspace/services/dns_block_service.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/settings/user_script.dart';

typedef VoidAsyncCallback = Future<void> Function();

/// Bag of dependencies DevToolsScreen reads from the surrounding webview.
/// Two concrete implementations:
///
/// - [WebViewModelDevToolsHost] for top-level sites (`WebViewModel`-backed):
///   exposes per-site state (cookie blocking, scripts) and DNS stats.
/// - [NestedDevToolsHost] for [InAppWebViewScreen] popups (no
///   `WebViewModel`): exposes only console + JS eval + HTML export.
///
/// `blockedCookies == null` is the sentinel for "no per-site state" and
/// hides the Cookies, Scripts, and DNS surfaces.
abstract class DevToolsHost {
  String get name;
  String? get siteId;
  String get currentUrl;
  /// URL used as the favicon cache key for this host (the site's stable
  /// `initUrl` for top-level sites; the current URL for nested webviews).
  String get iconUrl;
  /// Per-site proxy the favicon must be fetched through, or null for global.
  UserProxySettings? get proxy;
  WebViewController? get controller;
  List<ConsoleLogEntry> get consoleLogs;
  set onConsoleLogChanged(VoidCallback? cb);
  List<Cookie> get cookies;
  set cookies(List<Cookie> value);
  Set<BlockedCookie>? get blockedCookies;
  List<UserScriptConfig>? get siteUserScripts;
  Set<String> get enabledGlobalScriptIds;
  void reload();
}

class WebViewModelDevToolsHost implements DevToolsHost {
  final WebViewModel model;
  WebViewModelDevToolsHost(this.model);

  @override
  String get name => model.name;
  @override
  String? get siteId => model.siteId;
  @override
  String get currentUrl => model.currentUrl;
  @override
  String get iconUrl => model.initUrl;
  @override
  UserProxySettings? get proxy => model.proxySettings;
  @override
  WebViewController? get controller => model.controller;
  @override
  List<ConsoleLogEntry> get consoleLogs => model.consoleLogs;
  @override
  set onConsoleLogChanged(VoidCallback? cb) => model.onConsoleLogChanged = cb;
  @override
  List<Cookie> get cookies => model.cookies;
  @override
  set cookies(List<Cookie> value) => model.cookies = value;
  @override
  Set<BlockedCookie>? get blockedCookies => model.blockedCookies;
  @override
  List<UserScriptConfig>? get siteUserScripts => model.userScripts;
  @override
  Set<String> get enabledGlobalScriptIds => model.enabledGlobalScriptIds;
  @override
  void reload() => model.controller?.reload();
}

/// Console-only host for nested [InAppWebViewScreen]s. There is no
/// WebViewModel in nested mode, so per-site cookie/script state is absent
/// and DNS stats belong to the parent site's siteId (already exposed in
/// the parent's DevTools); we surface neither here.
class NestedDevToolsHost implements DevToolsHost {
  @override
  final String name;
  @override
  final String? siteId;
  String _currentUrl;
  WebViewController? _controller;
  @override
  final List<ConsoleLogEntry> consoleLogs = [];
  VoidCallback? _onConsoleLogChanged;
  @override
  List<Cookie> cookies = const [];

  NestedDevToolsHost({
    required this.name,
    required this.siteId,
    required String currentUrl,
  }) : _currentUrl = currentUrl;

  @override
  String get currentUrl => _currentUrl;
  set currentUrl(String value) => _currentUrl = value;

  @override
  String get iconUrl => _currentUrl;
  @override
  UserProxySettings? get proxy => null;

  @override
  WebViewController? get controller => _controller;
  set controller(WebViewController? value) => _controller = value;

  @override
  set onConsoleLogChanged(VoidCallback? cb) => _onConsoleLogChanged = cb;
  VoidCallback? get onConsoleLogChanged => _onConsoleLogChanged;

  static const _maxConsoleLogs = 500;

  void appendConsole(String message, ConsoleMessageLevel level) {
    consoleLogs.add(ConsoleLogEntry(
      timestamp: DateTime.now(),
      message: message,
      level: level,
    ));
    if (consoleLogs.length > _maxConsoleLogs) {
      consoleLogs.removeAt(0);
    }
    _onConsoleLogChanged?.call();
  }

  @override
  Set<BlockedCookie>? get blockedCookies => null;
  @override
  List<UserScriptConfig>? get siteUserScripts => null;
  @override
  Set<String> get enabledGlobalScriptIds => const {};
  @override
  void reload() => _controller?.reload();
}

class DevToolsScreen extends StatefulWidget {
  final DevToolsHost? host;
  final CookieManager cookieManager;
  /// Container-mode counterpart of [cookieManager]; non-null when
  /// `_useContainers` is true. The cookie inspector reads/deletes
  /// through this so the UI reflects the per-site container's jar
  /// instead of the (unused, likely empty) default jar in container
  /// mode. Same branching pattern as the WebView construction and
  /// onCookiesChanged sites.
  final ContainerCookieManager? containerCookieManager;
  final VoidAsyncCallback? onSave;
  final List<UserScriptConfig> globalUserScripts;

  const DevToolsScreen({
    super.key,
    this.host,
    required this.cookieManager,
    this.containerCookieManager,
    this.onSave,
    this.globalUserScripts = const [],
  });

  @override
  State<DevToolsScreen> createState() => _DevToolsScreenState();
}

class _DevToolsScreenState extends State<DevToolsScreen> {
  bool _loadingCookies = false;
  String? _exportedHtml;
  bool _isFetchingHtml = false;
  bool _isSavingIcon = false;
  final Set<LogLevel> _activeFilters = LogLevel.values.toSet();

  /// Runtime-only toggle: when true, the App Logs tab shows
  /// [LogSensitivity.sensitive] entries (siteId, hostnames, page URLs,
  /// proxy host:port, …) merged with normal entries. Resets on every
  /// cold launch — `LogService._sensitiveEntries` is process-local and
  /// the toggle is not persisted to SharedPreferences.
  bool _showSensitive = false;

  final ScrollController _consoleScrollController = ScrollController();
  final ScrollController _logScrollController = ScrollController();

  bool _isSearchVisible = false;
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();

  final TextEditingController _evalController = TextEditingController();
  final FocusNode _evalFocusNode = FocusNode();
  final List<String> _evalHistory = [];
  int _evalHistoryIndex = -1;
  bool _isEvaluating = false;

  /// Snapshot of blocked cookies on entry, to detect changes on exit.
  late final Set<BlockedCookie> _initialBlockedCookies;

  bool get _hasHost => widget.host != null;
  bool get _hasSiteState => widget.host?.blockedCookies != null;

  bool get _hasDnsBlocklist => DnsBlockService.instance.hasBlocklist;
  int get _tabCount {
    var n = 1; // App Logs is always present.
    if (_hasHost) n += 1; // Console
    if (_hasSiteState) {
      n += 1; // Cookies
      if (_hasDnsBlocklist) n += 1; // DNS
    }
    if (ContentBlockerService.instance.usingRustEngine) n += 1; // ABP
    return n;
  }

  /// Filter for DNS log: null = all, true = blocked only, false = allowed only.
  bool? _dnsFilter;
  final ScrollController _dnsScrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _initialBlockedCookies = _hasSiteState
        ? Set<BlockedCookie>.of(widget.host!.blockedCookies!)
        : <BlockedCookie>{};
    LogService.instance.addListener(_onLogUpdate);
    DnsBlockService.instance.addDnsLogListener(_onDnsLogUpdate);
    // ABP timing buffer is off in normal app runs (small but non-zero
    // Stopwatch + ring-buffer cost on every sub-resource decision).
    // Enable while DevTools is open so the ABP tab has fresh data;
    // disable on close so production runs aren't paying the overhead.
    if (ContentBlockerService.instance.usingRustEngine) {
      ContentBlockerService.instance.engineTimingEnabled = true;
    }
    if (_hasHost) {
      widget.host!.onConsoleLogChanged = _onConsoleUpdate;
    }
  }

  @override
  void dispose() {
    LogService.instance.removeListener(_onLogUpdate);
    DnsBlockService.instance.removeDnsLogListener(_onDnsLogUpdate);
    ContentBlockerService.instance.engineTimingEnabled = false;
    if (_hasHost) {
      widget.host!.onConsoleLogChanged = null;
    }
    if (_hasSiteState) {
      // If blocked cookies changed while DevTools was open, reload the page
      // so the webview re-fetches cookies with the new rules applied.
      final current = widget.host!.blockedCookies!;
      if (!_setEquals(current, _initialBlockedCookies)) {
        widget.host!.reload();
      }
    }
    _consoleScrollController.dispose();
    _logScrollController.dispose();
    _dnsScrollController.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    _evalController.dispose();
    _evalFocusNode.dispose();
    super.dispose();
  }

  /// Value-equality check for two sets (avoid importing collection).
  static bool _setEquals<T>(Set<T> a, Set<T> b) {
    if (a.length != b.length) return false;
    return a.every(b.contains);
  }

  void _onConsoleUpdate() {
    if (mounted) setState(() {});
  }

  void _onLogUpdate() {
    if (mounted) setState(() {});
  }

  void _onDnsLogUpdate() {
    if (mounted) setState(() {});
  }

  List<Tab> get _tabs {
    final loc = AppLocalizations.of(context);
    return [
      if (_hasHost)
        Tab(icon: const Icon(Icons.terminal, size: 18), text: loc.devToolsTabConsole),
      if (_hasSiteState)
        Tab(icon: const Icon(Icons.cookie_outlined, size: 18), text: loc.devToolsTabCookies),
      if (_hasSiteState && _hasDnsBlocklist)
        Tab(icon: const Icon(Icons.shield_outlined, size: 18), text: loc.devToolsTabDns),
      if (ContentBlockerService.instance.usingRustEngine)
        Tab(icon: const Icon(Icons.speed, size: 18), text: loc.devToolsTabAbp),
      Tab(icon: const Icon(Icons.list_alt, size: 18), text: loc.devToolsTabLogs),
    ];
  }

  void _toggleSearch() {
    setState(() {
      _isSearchVisible = !_isSearchVisible;
      if (!_isSearchVisible) {
        _searchQuery = '';
        _searchController.clear();
      } else {
        _searchFocusNode.requestFocus();
      }
    });
  }

  bool _matchesSearch(String text) {
    if (_searchQuery.isEmpty) return true;
    return text.toLowerCase().contains(_searchQuery.toLowerCase());
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return DefaultTabController(
      length: _tabCount,
      child: Scaffold(
        appBar: AppBar(
          title: Text(loc.devToolsTitle),
          actions: [
            if (_hasSiteState)
              IconButton(
                icon: const Icon(Icons.code, size: 20),
                tooltip: loc.devToolsScriptsTooltip,
                onPressed: _showScriptsSheet,
              ),
            if (_hasHost)
              IconButton(
                icon: const Icon(Icons.share, size: 20),
                tooltip: loc.devToolsExportTooltip,
                onPressed: _showShareSheet,
              ),
            IconButton(
              icon: Icon(_isSearchVisible ? Icons.search_off : Icons.search),
              tooltip: loc.devToolsSearchTooltip,
              onPressed: _toggleSearch,
            ),
          ],
          bottom: TabBar(
            tabs: _tabs,
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            labelPadding:
                const EdgeInsets.symmetric(horizontal: 12),
          ),
        ),
        body: Column(
          children: [
            if (_isSearchVisible)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 4.0),
                child: TextField(
                  controller: _searchController,
                  focusNode: _searchFocusNode,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    hintText: loc.devToolsSearchHint,
                    prefixIcon: const Icon(Icons.search, size: 20),
                    suffixIcon: _searchQuery.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear, size: 20),
                            onPressed: () {
                              _searchController.clear();
                              setState(() => _searchQuery = '');
                            },
                          )
                        : null,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 8.0),
                  ),
                  onChanged: (value) {
                    setState(() => _searchQuery = value);
                  },
                ),
              ),
            Expanded(
              child: TabBarView(
                children: [
                  if (_hasHost) _buildConsoleTab(),
                  if (_hasSiteState) _buildCookiesTab(),
                  if (_hasSiteState && _hasDnsBlocklist) _buildDnsTab(),
                  if (ContentBlockerService.instance.usingRustEngine)
                    _buildAbpTab(),
                  _buildAppLogsTab(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Console Tab ──

  Widget _buildConsoleTab() {
    final loc = AppLocalizations.of(context);
    final allLogs = widget.host!.consoleLogs;
    final logs = _searchQuery.isEmpty
        ? allLogs
        : allLogs.where((e) => _matchesSearch(e.message)).toList();
    return Column(
      children: [
        _buildConsoleActions(logs),
        Expanded(
          child: logs.isEmpty
              ? Center(child: Text(_searchQuery.isEmpty ? loc.devToolsConsoleEmpty : loc.devToolsNoMatches))
              : ListView.builder(
                  controller: _consoleScrollController,
                  reverse: _searchQuery.isEmpty,
                  itemCount: logs.length,
                  itemBuilder: (context, index) {
                    return _buildConsoleEntry(logs[logs.length - 1 - index]);
                  },
                ),
        ),
        _buildEvalInput(),
      ],
    );
  }

  Widget _buildConsoleActions(List<ConsoleLogEntry> logs) {
    final loc = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
      child: Row(
        children: [
          TextButton.icon(
            onPressed: () {
              setState(() {
                widget.host!.consoleLogs.clear();
              });
            },
            icon: const Icon(Icons.delete_outline, size: 18),
            label: Text(loc.devToolsClear),
          ),
          TextButton.icon(
            onPressed: logs.isEmpty
                ? null
                : () {
                    final text = logs
                        .map((e) => '[${_formatTime(e.timestamp)}] [${_consoleLevelName(e.level)}] ${e.message}')
                        .join('\n');
                    Clipboard.setData(ClipboardData(text: text));
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(loc.devToolsConsoleCopied(logs.length))),
                    );
                  },
            icon: const Icon(Icons.copy, size: 18),
            label: Text(loc.devToolsCopy),
          ),
        ],
      ),
    );
  }

  Widget _buildConsoleEntry(ConsoleLogEntry entry) {
    Color color;
    if (entry.isEvalInput) {
      color = Theme.of(context).colorScheme.primary;
    } else {
      switch (entry.level) {
        case ConsoleMessageLevel.WARNING:
          color = Colors.amber;
          break;
        case ConsoleMessageLevel.ERROR:
          color = Colors.red;
          break;
        default:
          color = Theme.of(context).textTheme.bodyMedium?.color ?? Colors.white;
      }
    }
    final text = entry.isEvalInput
        ? '> ${entry.message}'
        : '[${_formatTimeMs(entry.timestamp)}] ${entry.message}';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 2.0),
      child: SelectableText(
        text,
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 12,
          color: color,
          fontWeight: entry.isEvalInput ? FontWeight.bold : FontWeight.normal,
        ),
      ),
    );
  }

  // ── Console Eval ──

  static const _kEvalPromptGlyph = '>';

  Widget _buildEvalInput() {
    final loc = AppLocalizations.of(context);
    final hasController = widget.host?.controller != null;
    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      padding: const EdgeInsetsDirectional.only(start: 8.0, end: 4.0, top: 4.0, bottom: 4.0),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            Text(_kEvalPromptGlyph, style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: hasController
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).disabledColor,
            )),
            const SizedBox(width: 6),
            Expanded(
              child: TextField(
                controller: _evalController,
                focusNode: _evalFocusNode,
                enabled: hasController && !_isEvaluating,
                autocorrect: false,
                enableSuggestions: false,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                decoration: InputDecoration(
                  hintText: loc.devToolsEvalHint,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 8.0),
                  border: InputBorder.none,
                ),
                onSubmitted: hasController ? (_) => _evaluateJs() : null,
                textInputAction: TextInputAction.send,
              ),
            ),
            if (_evalHistory.isNotEmpty) ...[
              SizedBox(
                width: 28,
                height: 28,
                child: IconButton(
                  icon: const Icon(Icons.keyboard_arrow_up, size: 18),
                  padding: EdgeInsets.zero,
                  tooltip: loc.devToolsEvalPrevCommand,
                  onPressed: hasController ? _historyUp : null,
                ),
              ),
              SizedBox(
                width: 28,
                height: 28,
                child: IconButton(
                  icon: const Icon(Icons.keyboard_arrow_down, size: 18),
                  padding: EdgeInsets.zero,
                  tooltip: loc.devToolsEvalNextCommand,
                  onPressed: hasController ? _historyDown : null,
                ),
              ),
            ],
            SizedBox(
              width: 36,
              height: 36,
              child: IconButton(
                icon: _isEvaluating
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.play_arrow, size: 20),
                tooltip: loc.devToolsEvalRun,
                onPressed: hasController && !_isEvaluating ? _evaluateJs : null,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _evaluateJs() async {
    final source = _evalController.text.trim();
    if (source.isEmpty) return;

    final controller = widget.host?.controller;
    if (controller == null) return;

    if (_isEvaluating) return;
    setState(() => _isEvaluating = true);

    try {
      if (_evalHistory.isEmpty || _evalHistory.last != source) {
        _evalHistory.add(source);
      }
      _evalHistoryIndex = -1;

      widget.host!.consoleLogs.add(ConsoleLogEntry(
        timestamp: DateTime.now(),
        message: source,
        level: ConsoleMessageLevel.LOG,
        isEvalInput: true,
      ));
      _onConsoleUpdate();

      // Directly embed code (no eval/Function) to respect CSP.
      // Phase 1: set sentinel. Phase 2: try as expression.
      // Phase 3: if expression had a parse error, try as statements.
      await controller.evaluateJavascript('window.__wsEvalOk=false');
      await controller.evaluateJavascript(_buildExprJs(source));
      await controller.evaluateJavascript(_buildStmtJs(source));

      _evalController.clear();
    } finally {
      if (mounted) {
        setState(() => _isEvaluating = false);
      }
    }
  }

  String _buildExprJs(String source) {
    return '(function(){try{var __r=(\n$source\n);if(__r!==undefined){if(typeof __r==="object"&&__r!==null){try{console.log(JSON.stringify(__r,null,2))}catch(e){console.log(String(__r))}}else{console.log(String(__r))}}window.__wsEvalOk=true}catch(__e){console.error((__e&&__e.message)?__e.message:String(__e));window.__wsEvalOk=true}})()';
  }

  String _buildStmtJs(String source) {
    return 'if(!window.__wsEvalOk){try{\n$source\n}catch(__e){console.error((__e&&__e.message)?__e.message:String(__e))}delete window.__wsEvalOk}else{delete window.__wsEvalOk}';
  }

  void _historyUp() {
    if (_evalHistory.isEmpty) return;
    if (_evalHistoryIndex == -1) {
      _evalHistoryIndex = _evalHistory.length - 1;
    } else if (_evalHistoryIndex > 0) {
      _evalHistoryIndex--;
    }
    _evalController.text = _evalHistory[_evalHistoryIndex];
    _evalController.selection = TextSelection.fromPosition(
      TextPosition(offset: _evalController.text.length),
    );
  }

  void _historyDown() {
    if (_evalHistory.isEmpty || _evalHistoryIndex == -1) return;
    if (_evalHistoryIndex < _evalHistory.length - 1) {
      _evalHistoryIndex++;
      _evalController.text = _evalHistory[_evalHistoryIndex];
    } else {
      _evalHistoryIndex = -1;
      _evalController.clear();
    }
    _evalController.selection = TextSelection.fromPosition(
      TextPosition(offset: _evalController.text.length),
    );
  }

  // ── Cookies Tab ──

  Widget _buildCookiesTab() {
    final loc = AppLocalizations.of(context);
    final allCookies = widget.host!.cookies;
    final blocked = widget.host!.blockedCookies!;
    final cookies = _searchQuery.isEmpty
        ? allCookies
        : allCookies
            .where((c) =>
                _matchesSearch(c.name) ||
                _matchesSearch(c.value) ||
                _matchesSearch(c.domain ?? ''))
            .toList();
    final filteredBlocked = _searchQuery.isEmpty
        ? blocked.toList()
        : blocked.where((b) => _matchesSearch(b.name) || _matchesSearch(b.domain)).toList();
    return Column(
      children: [
        _buildCookieActions(cookies),
        Expanded(
          child: _loadingCookies
              ? const Center(child: CircularProgressIndicator())
              : (cookies.isEmpty && filteredBlocked.isEmpty)
                  ? Center(child: Text(_searchQuery.isEmpty ? loc.devToolsCookiesEmpty : loc.devToolsNoMatches))
                  : ListView(
                      children: [
                        if (filteredBlocked.isNotEmpty) ...[
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                            child: Text(
                              loc.devToolsCookiesBlockedHeader(filteredBlocked.length),
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                color: Colors.red.shade300,
                              ),
                            ),
                          ),
                          ...filteredBlocked.map(_buildBlockedCookieTile),
                          const Divider(),
                        ],
                        ...cookies.map(_buildCookieTile),
                      ],
                    ),
        ),
      ],
    );
  }

  Widget _buildCookieActions(List<Cookie> cookies) {
    final loc = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
      child: Row(
        children: [
          TextButton.icon(
            onPressed: _refreshCookies,
            icon: const Icon(Icons.refresh, size: 18),
            label: Text(loc.devToolsRefresh),
          ),
          if (cookies.isNotEmpty)
            TextButton.icon(
              onPressed: () {
                final json = cookies.map((c) => c.toJson()).toList();
                Clipboard.setData(
                    ClipboardData(text: const JsonEncoder.withIndent('  ').convert(json)));
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(loc.devToolsCookiesCopiedJson(cookies.length))),
                );
              },
              icon: const Icon(Icons.copy, size: 18),
              label: Text(loc.devToolsCopyAsJson),
            ),
        ],
      ),
    );
  }

  Future<void> _refreshCookies() async {
    final url = widget.host!.currentUrl;
    if (url.isEmpty) return;
    setState(() => _loadingCookies = true);
    try {
      final List<Cookie> cookies;
      final container = widget.containerCookieManager;
      final controller = widget.host!.controller;
      if (container != null && controller != null) {
        cookies = await container.getCookies(
          controller: controller,
          siteId: widget.host!.siteId!,
          url: Uri.parse(url),
        );
        LogService.instance.log(
          'DevTools',
          'Cookie inspector via ContainerCookieManager: '
              'siteId=${widget.host!.siteId} url=$url '
              'count=${cookies.length}',
          sensitivity: LogSensitivity.sensitive,
        );
      } else {
        cookies = await widget.cookieManager.getCookies(url: Uri.parse(url));
        LogService.instance.log(
          'DevTools',
          'Cookie inspector via legacy CookieManager: '
              'siteId=${widget.host!.siteId} url=$url '
              'count=${cookies.length} '
              '(container=${container != null} ctrl=${controller != null})',
          sensitivity: LogSensitivity.sensitive,
        );
      }
      if (mounted) {
        widget.host!.cookies = cookies;
        setState(() => _loadingCookies = false);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loadingCookies = false);
      }
    }
  }

  Future<void> _deleteCookie(Cookie cookie) async {
    final url = Uri.parse(widget.host!.currentUrl);
    final container = widget.containerCookieManager;
    final controller = widget.host!.controller;
    if (container != null && controller != null) {
      await container.deleteCookie(
        controller: controller,
        siteId: widget.host!.siteId!,
        url: url,
        name: cookie.name,
        domain: cookie.domain,
        path: cookie.path ?? '/',
      );
    } else {
      await widget.cookieManager.deleteCookie(
        url: url,
        name: cookie.name,
        domain: cookie.domain,
        path: cookie.path ?? '/',
      );
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).devToolsCookieDeleted(cookie.name))),
      );
      _refreshCookies();
    }
  }

  Future<void> _blockCookie(Cookie cookie) async {
    final domain = cookie.domain ?? extractDomain(widget.host!.currentUrl);
    final rule = BlockedCookie(name: cookie.name, domain: domain);
    setState(() {
      widget.host!.blockedCookies!.add(rule);
    });
    // Delete the cookie immediately from the webview
    await _deleteCookie(cookie);
    await widget.onSave?.call();
  }

  Future<void> _unblockCookie(BlockedCookie rule) async {
    setState(() {
      widget.host!.blockedCookies!.remove(rule);
    });
    await widget.onSave?.call();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).devToolsCookieUnblocked(rule.name))),
      );
    }
  }

  Widget _buildCookieTile(Cookie cookie) {
    final loc = AppLocalizations.of(context);
    final truncatedValue = cookie.value.length > 60
        ? '${cookie.value.substring(0, 60)}...'
        : cookie.value;
    return ExpansionTile(
      title: Text(cookie.name, style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
      subtitle: Text(
        truncatedValue,
        style: const TextStyle(fontSize: 11),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (cookie.domain != null)
                Text(loc.devToolsCookieDomain(cookie.domain!), style: const TextStyle(fontSize: 12)),
              if (cookie.path != null)
                Text(loc.devToolsCookiePath(cookie.path!), style: const TextStyle(fontSize: 12)),
              if (cookie.expiresDate != null)
                Text(
                  loc.devToolsCookieExpires(
                      DateTime.fromMillisecondsSinceEpoch(cookie.expiresDate!).toString()),
                  style: const TextStyle(fontSize: 12),
                ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  _buildSecurityChip(
                    cookie.isSecure == true ? loc.devToolsCookieSecure : loc.devToolsCookieNotSecure,
                    cookie.isSecure == true ? Colors.green : Colors.red,
                  ),
                  if (cookie.isHttpOnly == true)
                    _buildSecurityChip('HttpOnly', Colors.green),
                  if (cookie.sameSite != null)
                    _buildSameSiteChip(cookie.sameSite.toString()),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  TextButton.icon(
                    onPressed: () => _deleteCookie(cookie),
                    icon: const Icon(Icons.delete_outline, size: 16, color: Colors.red),
                    label: Text(loc.commonDelete, style: const TextStyle(color: Colors.red, fontSize: 12)),
                  ),
                  const SizedBox(width: 8),
                  TextButton.icon(
                    onPressed: () => _blockCookie(cookie),
                    icon: const Icon(Icons.block, size: 16, color: Colors.orange),
                    label: Text(loc.devToolsCookieBlock, style: const TextStyle(color: Colors.orange, fontSize: 12)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildBlockedCookieTile(BlockedCookie rule) {
    final loc = AppLocalizations.of(context);
    return ListTile(
      leading: Icon(Icons.block, color: Colors.red.shade300, size: 20),
      title: Text(rule.name, style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
      subtitle: Text(rule.domain, style: const TextStyle(fontSize: 11)),
      trailing: TextButton.icon(
        onPressed: () => _unblockCookie(rule),
        icon: const Icon(Icons.check_circle_outline, size: 16, color: Colors.green),
        label: Text(loc.devToolsCookieUnblock, style: const TextStyle(color: Colors.green, fontSize: 12)),
      ),
    );
  }

  Widget _buildSecurityChip(String label, Color color) {
    return Chip(
      label: Text(label, style: TextStyle(fontSize: 11, color: color)),
      backgroundColor: color.withAlpha(25),
      side: BorderSide(color: color.withAlpha(76)),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }

  Widget _buildSameSiteChip(String value) {
    Color color;
    String label;
    if (value.contains('STRICT')) {
      color = Colors.green;
      label = 'SameSite=Strict';
    } else if (value.contains('LAX')) {
      color = Colors.blue;
      label = 'SameSite=Lax';
    } else {
      color = Colors.amber;
      label = 'SameSite=None';
    }
    return _buildSecurityChip(label, color);
  }

  // ── Scripts Bottom Sheet ──

  void _showScriptsSheet() {
    final loc = AppLocalizations.of(context);
    final siteScripts = widget.host!.siteUserScripts ?? const <UserScriptConfig>[];
    final enabledIds = widget.host!.enabledGlobalScriptIds;
    final activeGlobals = widget.globalUserScripts
        .where((g) => enabledIds.contains(g.id))
        .toList();
    final scripts = [...activeGlobals, ...siteScripts];
    final globalCount = activeGlobals.length;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return DraggableScrollableSheet(
          initialChildSize: 0.5,
          minChildSize: 0.3,
          maxChildSize: 0.85,
          expand: false,
          builder: (context, scrollController) {
            if (scripts.isEmpty) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildSheetHandle(),
                  Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Text(loc.devToolsNoUserScripts,
                        style: Theme.of(context).textTheme.bodyLarge),
                  ),
                ],
              );
            }
            return Column(
              children: [
                _buildSheetHandle(),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
                  child: Row(
                    children: [
                      Text(loc.devToolsScriptsHeader, style: Theme.of(context).textTheme.titleMedium),
                      const Spacer(),
                      Text(scripts.length.toString(),
                          style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView.builder(
                    controller: scrollController,
                    itemCount: scripts.length,
                    itemBuilder: (context, index) {
                      final script = scripts[index];
                      final isGlobal = index < globalCount;
                      final active = isGlobal || script.enabled;
                      return ExpansionTile(
                        leading: Icon(
                          active ? Icons.code : Icons.code_off,
                          color: active ? Colors.green : Colors.grey,
                          size: 20,
                        ),
                        title: Row(
                          children: [
                            Flexible(
                              child: Text(script.name,
                                  style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
                            ),
                            if (isGlobal) ...[
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                                decoration: BoxDecoration(
                                  color: Theme.of(context).colorScheme.secondaryContainer,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  loc.devToolsScriptGlobalBadge,
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: Theme.of(context).colorScheme.onSecondaryContainer,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        subtitle: Text(
                          script.injectionTime == UserScriptInjectionTime.atDocumentStart
                              ? loc.devToolsScriptDocumentStart
                              : loc.devToolsScriptDocumentEnd,
                          style: const TextStyle(fontSize: 11),
                        ),
                        children: [
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(12.0),
                            margin: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Stack(
                              children: [
                                SelectableText(
                                  script.source.isEmpty ? loc.devToolsScriptEmptySource : script.source,
                                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                                ),
                                Positioned(
                                  top: 0,
                                  right: 0,
                                  child: IconButton(
                                    icon: const Icon(Icons.copy, size: 16),
                                    tooltip: loc.devToolsScriptCopySource,
                                    onPressed: () {
                                      Clipboard.setData(ClipboardData(text: script.source));
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(content: Text(loc.devToolsScriptCopied(script.name))),
                                      );
                                    },
                                    visualDensity: VisualDensity.compact,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 8),
                        ],
                      );
                    },
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // ── Share HTML Bottom Sheet ──

  void _showShareSheet() {
    final loc = AppLocalizations.of(context);
    showModalBottomSheet(
      context: context,
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildSheetHandle(),
              ListTile(
                leading: const Icon(Icons.share),
                title: Text(loc.devToolsShareHtml),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _shareHtml();
                },
              ),
              ListTile(
                leading: const Icon(Icons.save),
                title: Text(loc.devToolsSaveToFile),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _saveHtmlToFile();
                },
              ),
              ListTile(
                leading: const Icon(Icons.copy),
                title: Text(loc.devToolsCopyToClipboard),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _copyHtml();
                },
              ),
              ListTile(
                leading: const Icon(Icons.image_outlined),
                title: Text(loc.devToolsSaveIcon),
                enabled: !_isSavingIcon,
                onTap: () {
                  Navigator.pop(sheetContext);
                  _saveIconAsPng();
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSheetHandle() {
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        width: 32,
        height: 4,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.onSurfaceVariant.withAlpha(102),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }

  Future<String?> _fetchHtml() async {
    if (_isFetchingHtml) return _exportedHtml;
    final controller = widget.host!.controller;
    if (controller == null) return null;

    _isFetchingHtml = true;
    try {
      final html = await controller.getHtml();
      if (html == null || html.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(AppLocalizations.of(context).devToolsNoHtmlContent)),
          );
        }
        return null;
      }
      _exportedHtml = html;
      return html;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).devToolsHtmlFetchFailed(e.toString()))),
        );
      }
      return null;
    } finally {
      _isFetchingHtml = false;
    }
  }

  Future<void> _shareHtml() async {
    final html = _exportedHtml ?? await _fetchHtml();
    if (html == null || !mounted) return;

    final domain = extractDomain(widget.host!.currentUrl);
    final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-').split('.')[0];
    SharePlus.instance.share(ShareParams(
      text: html,
      title: '${domain}_$timestamp.html',
    ));
  }

  Future<void> _saveHtmlToFile() async {
    final html = _exportedHtml ?? await _fetchHtml();
    if (html == null || !mounted) return;

    try {
      final domain = extractDomain(widget.host!.currentUrl);
      final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-').split('.')[0];
      final fileName = '${domain}_$timestamp.html';
      final bytes = utf8.encode(html);

      final bool isMobile = !kIsWeb && (Platform.isIOS || Platform.isAndroid);
      final outputPath = await FilePicker.saveFile(
        dialogTitle: AppLocalizations.of(context).devToolsSaveHtmlDialogTitle,
        fileName: fileName,
        bytes: isMobile ? bytes : null,
      );

      if (outputPath != null && !isMobile) {
        final filePath = outputPath.endsWith('.html') ? outputPath : '$outputPath.html';
        await File(filePath).writeAsString(html);
      }

      if (mounted && outputPath != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).devToolsHtmlSaved)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).devToolsSaveFailed(e.toString()))),
        );
      }
    }
  }

  void _copyHtml() async {
    final html = _exportedHtml ?? await _fetchHtml();
    if (html == null || !mounted) return;
    Clipboard.setData(ClipboardData(text: html));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).devToolsHtmlCopied)),
      );
    }
  }

  // ── Save Icon as PNG ──

  Future<void> _saveIconAsPng() async {
    if (_isSavingIcon) return;
    setState(() => _isSavingIcon = true);
    final host = widget.host!;
    final loc = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(content: Text(loc.devToolsPreparingIcon)),
    );
    try {
      final png = await exportIconAsPng(
        host.iconUrl,
        resolvedIconUrl: FaviconUrlCache.get(host.iconUrl),
        proxy: host.proxy,
      );
      if (!mounted) return;
      if (png == null) {
        messenger.showSnackBar(
          SnackBar(content: Text(loc.devToolsNoIconToSave)),
        );
        return;
      }

      final domain = extractDomain(host.currentUrl);
      final fileName = '${domain}_icon.png';
      final bool isMobile = !kIsWeb && (Platform.isIOS || Platform.isAndroid);
      final outputPath = await FilePicker.saveFile(
        dialogTitle: loc.devToolsSaveIconDialogTitle,
        fileName: fileName,
        bytes: isMobile ? png : null,
      );

      if (outputPath != null && !isMobile) {
        final filePath = outputPath.endsWith('.png') ? outputPath : '$outputPath.png';
        await File(filePath).writeAsBytes(png);
      }

      if (mounted && outputPath != null) {
        messenger.showSnackBar(
          SnackBar(content: Text(loc.devToolsIconSaved)),
        );
      }
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text(loc.devToolsSaveFailed(e.toString()))),
        );
      }
    } finally {
      if (mounted) setState(() => _isSavingIcon = false);
    }
  }

  // ── DNS Tab ──

  Widget _buildDnsTab() {
    final loc = AppLocalizations.of(context);
    final stats = DnsBlockService.instance.statsForSite(widget.host!.siteId!);
    final allEntries = stats.log;
    List<DnsLogEntry> entries = _dnsFilter == null
        ? allEntries
        : allEntries.where((e) => e.blocked == _dnsFilter).toList();
    if (_searchQuery.isNotEmpty) {
      entries = entries.where((e) => _matchesSearch(e.domain)).toList();
    }

    return Column(
      children: [
        _buildDnsStats(stats),
        _buildDnsFilters(stats),
        _buildDnsActions(stats),
        Expanded(
          child: entries.isEmpty
              ? Center(child: Text(_searchQuery.isEmpty ? loc.devToolsDnsEmpty : loc.devToolsNoMatches))
              : ListView.builder(
                  controller: _dnsScrollController,
                  reverse: _searchQuery.isEmpty,
                  itemCount: entries.length,
                  itemBuilder: (context, index) {
                    final entry = entries[entries.length - 1 - index];
                    return _buildDnsEntry(entry);
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildDnsStats(DnsStats stats) {
    final loc = AppLocalizations.of(context);
    final blockRate = '${stats.blockRate.toStringAsFixed(1)}%';
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Row(
        children: [
          _buildDnsStatCard(loc.devToolsDnsTotal, stats.total.toString(), Colors.blue),
          const SizedBox(width: 8),
          _buildDnsStatCard(loc.devToolsDnsAllowed, stats.allowed.toString(), Colors.green),
          const SizedBox(width: 8),
          _buildDnsStatCard(loc.devToolsDnsBlocked, stats.blocked.toString(), Colors.red),
          const SizedBox(width: 8),
          _buildDnsStatCard(loc.devToolsDnsBlockRate, blockRate,
              stats.blockRate > 0 ? Colors.orange : Colors.grey),
        ],
      ),
    );
  }

  Widget _buildDnsStatCard(String label, String value, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        decoration: BoxDecoration(
          color: color.withAlpha(20),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withAlpha(60)),
        ),
        child: Column(
          children: [
            Text(value,
                style: TextStyle(
                    fontSize: 16, fontWeight: FontWeight.bold, color: color)),
            const SizedBox(height: 2),
            Text(label,
                style: TextStyle(fontSize: 10, color: color.withAlpha(180))),
          ],
        ),
      ),
    );
  }

  Widget _buildDnsFilters(DnsStats stats) {
    final loc = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          FilterChip(
            label: Text(loc.devToolsDnsFilterAll, style: const TextStyle(fontSize: 12)),
            selected: _dnsFilter == null,
            onSelected: (_) => setState(() => _dnsFilter = null),
            visualDensity: VisualDensity.compact,
          ),
          const SizedBox(width: 6),
          FilterChip(
            label: Text(loc.devToolsDnsFilterAllowed(stats.allowed),
                style: const TextStyle(fontSize: 12)),
            selected: _dnsFilter == false,
            onSelected: (_) =>
                setState(() => _dnsFilter = _dnsFilter == false ? null : false),
            visualDensity: VisualDensity.compact,
          ),
          const SizedBox(width: 6),
          FilterChip(
            label: Text(loc.devToolsDnsFilterBlocked(stats.blocked),
                style: const TextStyle(fontSize: 12)),
            selected: _dnsFilter == true,
            onSelected: (_) =>
                setState(() => _dnsFilter = _dnsFilter == true ? null : true),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  Widget _buildDnsActions(DnsStats stats) {
    final loc = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          TextButton.icon(
            onPressed: () {
              DnsBlockService.instance.clearStatsForSite(widget.host!.siteId!);
            },
            icon: const Icon(Icons.delete_outline, size: 18),
            label: Text(loc.devToolsClear),
          ),
          TextButton.icon(
            onPressed: stats.log.isEmpty
                ? null
                : () {
                    final text = stats.log
                        .map((e) =>
                            '[${_formatTimeMs(e.timestamp)}] ${e.blocked ? 'BLOCKED' : 'ALLOWED'} ${e.domain}')
                        .join('\n');
                    Clipboard.setData(ClipboardData(text: text));
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(loc.devToolsDnsLogCopied)),
                    );
                  },
            icon: const Icon(Icons.copy, size: 18),
            label: Text(loc.devToolsCopy),
          ),
        ],
      ),
    );
  }

  Widget _buildDnsEntry(DnsLogEntry entry) {
    final line = '[${_formatTimeMs(entry.timestamp)}] ${entry.domain}';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 1),
      child: Row(
        children: [
          Icon(
            entry.blocked ? Icons.block : Icons.check_circle_outline,
            size: 14,
            color: entry.blocked ? Colors.red : Colors.green,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SelectableText(
              line,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
                color: entry.blocked
                    ? Colors.red
                    : Theme.of(context).textTheme.bodyMedium?.color,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── ABP (Rust engine) Tab ──

  Widget _buildAbpTab() {
    final svc = ContentBlockerService.instance;
    final samples = svc.recentEngineDecisions;
    final reversed = samples.reversed.toList();
    // Compute summary stats over the window.
    int blockedCount = 0;
    int allowedCount = 0;
    int totalMicros = 0;
    int maxMicros = 0;
    for (final s in samples) {
      if (s.blocked) {
        blockedCount++;
      } else {
        allowedCount++;
      }
      totalMicros += s.micros;
      if (s.micros > maxMicros) maxMicros = s.micros;
    }
    final avgMicros = samples.isEmpty ? 0 : totalMicros ~/ samples.length;

    final timingOn = svc.engineTimingEnabled;
    final consulted = svc.engineConsultedSinceTimingOn;
    final loc = AppLocalizations.of(context);
    final avgValue = '$avgMicros µs';
    final maxValue = '$maxMicros µs';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              _abpStatChip(loc.devToolsAbpEngine, svc.usingRustEngine ? loc.devToolsAbpActive : loc.devToolsAbpOff,
                  svc.usingRustEngine ? Colors.green : Colors.grey),
              _abpStatChip(loc.devToolsAbpRecording,
                  timingOn ? loc.devToolsAbpOn : loc.devToolsAbpOff,
                  timingOn ? Colors.green : Colors.orange),
              _abpStatChip(loc.devToolsAbpConsulted, consulted.toString(), Colors.blueGrey),
              _abpStatChip(
                  loc.devToolsAbpAvg, avgValue, Colors.blueGrey),
              _abpStatChip(loc.devToolsAbpMax, maxValue,
                  maxMicros > 1000 ? Colors.orange : Colors.blueGrey),
              _abpStatChip(loc.devToolsAbpBlocked, blockedCount.toString(), Colors.red),
              _abpStatChip(loc.devToolsAbpAllowed, allowedCount.toString(), Colors.green),
              _abpStatChip('uBO', svc.useUboResources ? loc.devToolsAbpOn : loc.devToolsAbpOff,
                  svc.useUboResources ? Colors.green : Colors.grey),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12.0),
          child: Row(
            children: [
              TextButton.icon(
                icon: const Icon(Icons.refresh, size: 16),
                label: Text(loc.devToolsRefreshButton),
                onPressed: () => setState(() {}),
              ),
              const Spacer(),
              if (samples.isNotEmpty)
                Text(loc.devToolsAbpSampleCount(samples.length),
                    style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: samples.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      consulted == 0
                          ? loc.devToolsAbpEmptyNotConsulted
                          : loc.devToolsAbpEmptyBufferRolled(consulted),
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView.builder(
                  itemCount: reversed.length,
                  itemBuilder: (context, i) {
                    final s = reversed[i];
                    final urlForSearch = '${s.url} ${s.requestType}';
                    if (!_matchesSearch(urlForSearch)) {
                      return const SizedBox.shrink();
                    }
                    return _buildAbpRow(s);
                  },
                ),
        ),
      ],
    );
  }

  Widget _abpStatChip(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withAlpha(36),
        borderRadius: BorderRadius.circular(6),
      ),
      child: RichText(
        text: TextSpan(
          style: Theme.of(context).textTheme.bodySmall,
          children: [
            TextSpan(
              text: '$label ',
              style: TextStyle(color: color),
            ),
            TextSpan(
              text: value,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAbpRow(EngineDecisionSample s) {
    final color = s.blocked ? Colors.red.shade400 : Colors.green.shade600;
    final subtitle = '${s.requestType} · ${s.micros} µs';
    return ListTile(
      dense: true,
      leading: Icon(
        s.blocked ? Icons.block : Icons.check_circle_outline,
        color: color,
        size: 20,
      ),
      title: Text(
        s.url,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
      ),
      subtitle: Text(
        subtitle,
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }

  // ── App Logs Tab ──

  Widget _buildAppLogsTab() {
    final loc = AppLocalizations.of(context);
    final allEntries = _showSensitive
        ? LogService.instance.allEntriesMerged
        : LogService.instance.entries;
    var filtered = _activeFilters.length == LogLevel.values.length
        ? allEntries
        : allEntries.where((e) => _activeFilters.contains(e.level)).toList();
    if (_searchQuery.isNotEmpty) {
      filtered = filtered
          .where((e) => _matchesSearch(e.message) || _matchesSearch(e.tag))
          .toList();
    }

    return Column(
      children: [
        _buildLogActions(filtered),
        _buildLogFilters(),
        _buildSensitiveToggle(),
        Expanded(
          child: filtered.isEmpty
              ? Center(child: Text(_searchQuery.isEmpty ? loc.devToolsLogsEmpty : loc.devToolsNoMatches))
              : ListView.builder(
                  controller: _logScrollController,
                  reverse: _searchQuery.isEmpty,
                  itemCount: filtered.length,
                  itemBuilder: (context, index) {
                    return _buildLogEntry(filtered[filtered.length - 1 - index]);
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildSensitiveToggle() {
    final loc = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12.0),
      child: Row(
        children: [
          Switch(
            value: _showSensitive,
            onChanged: (v) => setState(() => _showSensitive = v),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              _showSensitive
                  ? loc.devToolsSensitiveShowing
                  : loc.devToolsSensitiveShow,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLogActions(List<LogEntry> filtered) {
    final loc = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
      child: Row(
        children: [
          TextButton.icon(
            onPressed: _exportLogs,
            icon: const Icon(Icons.save, size: 18),
            label: Text(loc.devToolsExport),
          ),
          TextButton.icon(
            onPressed: filtered.isEmpty
                ? null
                : () {
                    final text = filtered
                        .map((e) => '[${_formatTime(e.timestamp)}] [${e.tag}/${e.level.name}] ${e.message}')
                        .join('\n');
                    Clipboard.setData(ClipboardData(text: text));
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(loc.devToolsLogsCopied(filtered.length))),
                    );
                  },
            icon: const Icon(Icons.copy, size: 18),
            label: Text(loc.devToolsCopy),
          ),
          TextButton.icon(
            onPressed: () {
              LogService.instance.clear();
              setState(() {});
            },
            icon: const Icon(Icons.delete_outline, size: 18),
            label: Text(loc.devToolsClear),
          ),
        ],
      ),
    );
  }

  Widget _buildLogFilters() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12.0),
      child: Wrap(
        spacing: 6,
        children: LogLevel.values.map((level) {
          final isActive = _activeFilters.contains(level);
          return FilterChip(
            label: Text(level.name, style: const TextStyle(fontSize: 12)),
            selected: isActive,
            onSelected: (selected) {
              setState(() {
                if (selected) {
                  _activeFilters.add(level);
                } else {
                  _activeFilters.remove(level);
                }
              });
            },
            visualDensity: VisualDensity.compact,
          );
        }).toList(),
      ),
    );
  }

  Widget _buildLogEntry(LogEntry entry) {
    Color color;
    switch (entry.level) {
      case LogLevel.warning:
        color = Colors.amber;
        break;
      case LogLevel.error:
        color = Colors.red;
        break;
      case LogLevel.info:
        color = Colors.blue;
        break;
      default:
        color = Theme.of(context).textTheme.bodyMedium?.color ?? Colors.white;
    }
    final isSensitive = entry.sensitivity == LogSensitivity.sensitive;
    final prefix = isSensitive ? '[SENSITIVE] ' : '';
    final line =
        '[${_formatTime(entry.timestamp)}] $prefix[${entry.tag}] ${entry.message}';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 1.0),
      decoration: isSensitive
          ? BoxDecoration(
              border: Border(
                left: BorderSide(color: Colors.deepOrange.shade400, width: 3),
              ),
            )
          : null,
      child: SelectableText(
        line,
        style: TextStyle(fontFamily: 'monospace', fontSize: 11, color: color),
      ),
    );
  }

  Future<void> _exportLogs() async {
    final text = LogService.instance.export();
    if (text.isEmpty) return;

    final bytes = utf8.encode(text);
    final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-').split('.')[0];
    final fileName = 'webspace_logs_$timestamp.txt';

    final bool isMobile = !kIsWeb && (Platform.isIOS || Platform.isAndroid);
    if (!mounted) return;
    final outputPath = await FilePicker.saveFile(
      dialogTitle: AppLocalizations.of(context).devToolsExportLogsDialogTitle,
      fileName: fileName,
      bytes: isMobile ? bytes : null,
    );

    if (outputPath != null && !isMobile) {
      final filePath = outputPath.endsWith('.txt') ? outputPath : '$outputPath.txt';
      await File(filePath).writeAsString(text);
    }

    if (mounted && outputPath != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).devToolsLogsExported)),
      );
    }
  }

  // ── Helpers ──

  String _consoleLevelName(ConsoleMessageLevel level) {
    if (level == ConsoleMessageLevel.WARNING) return 'WARN';
    if (level == ConsoleMessageLevel.ERROR) return 'ERROR';
    if (level == ConsoleMessageLevel.DEBUG) return 'DEBUG';
    return 'LOG';
  }

  String _formatTime(DateTime dt) =>
      '${dt.hour.toString().padLeft(2, '0')}:'
      '${dt.minute.toString().padLeft(2, '0')}:'
      '${dt.second.toString().padLeft(2, '0')}';

  String _formatTimeMs(DateTime dt) =>
      '${_formatTime(dt)}.${dt.millisecond.toString().padLeft(3, '0')}';
}
