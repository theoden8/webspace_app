import 'dart:convert';
import 'package:webspace/platform/host_platform.dart';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' show ConsoleMessageLevel;
import 'package:share_plus/share_plus.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/services/reentry_guard.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/screens/add_site.dart' show FaviconUrlCache;
import 'package:webspace/services/container_cookie_manager.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/services/icon_png_export.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/notification_service.dart';
import 'package:webspace/services/content_blocker_service.dart';
import 'package:webspace/services/developer_mode_service.dart';
import 'package:webspace/services/dns_block_service.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/settings/user_script.dart';
import 'package:webspace/widgets/background_log_view.dart';
import 'package:webspace/widgets/dev_tools_parts.dart';
import 'package:webspace/widgets/log_entry_line.dart';
import 'package:webspace/widgets/stat_chip.dart';
import 'package:webspace/widgets/toast.dart';

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
  /// The user-chosen icon, which the drawer shows over any other.
  Uint8List? get customIcon;
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
  Uint8List? get customIcon => model.customIconPng;
  @override
  UserProxySettings? get proxy => model.outboundProxySettings;
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
  @override
  String currentUrl;
  @override
  WebViewController? controller;
  @override
  final List<ConsoleLogEntry> consoleLogs = [];
  @override
  VoidCallback? onConsoleLogChanged;
  @override
  List<Cookie> cookies = const [];

  NestedDevToolsHost({
    required this.name,
    required this.siteId,
    required this.currentUrl,
  });

  @override
  String get iconUrl => currentUrl;
  @override
  Uint8List? get customIcon => null;
  @override
  UserProxySettings? get proxy => null;

  static const _maxConsoleLogs = 500;

  void appendConsole(String message, {required ConsoleMessageLevel level}) {
    consoleLogs.add(ConsoleLogEntry(
      timestamp: DateTime.now(),
      message: message,
      level: level,
    ));
    if (consoleLogs.length > _maxConsoleLogs) {
      consoleLogs.removeAt(0);
    }
    onConsoleLogChanged?.call();
  }

  @override
  Set<BlockedCookie>? get blockedCookies => null;
  @override
  List<UserScriptConfig>? get siteUserScripts => null;
  @override
  Set<String> get enabledGlobalScriptIds => const {};
  @override
  void reload() => controller?.reload();
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

  /// When non-null and developer mode is on, the App Logs tab shows a
  /// diagnostics row that triggers the same wake the OS background task
  /// would run, plus a test notification for the host's site.
  /// Lets the wake-up chain (reload -> page JS -> webNotification handler ->
  /// NotificationService.show) be exercised in the foreground without
  /// waiting on iOS BGAppRefreshTask / Android WorkManager. Wired only from
  /// the top-level (per-site) launch; null for nested webviews.
  final VoidAsyncCallback? onSimulateBackgroundRefresh;

  /// Open on the Background tab (DEVTOOLS-011) when developer mode shows it.
  final bool startOnBackground;

  const DevToolsScreen({
    super.key,
    this.host,
    required this.cookieManager,
    this.containerCookieManager,
    this.onSave,
    this.globalUserScripts = const [],
    this.onSimulateBackgroundRefresh,
    this.startOnBackground = false,
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

  /// Guards `_copyLogs` against re-entry: a second tap while its confirmation
  /// dialog is up would stack a second dialog (or pop the first).
  final _copyLogsGuard = ReentryGuard();

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

  /// Gates the Background tab and the notification diagnostics row. Read
  /// once: a tab that appears or vanishes under an open TabController would
  /// leave its length wrong.
  final bool _developerMode = DeveloperModeService.instance.enabled;

  /// Filter for DNS log: null = all, true = blocked only, false = allowed only.
  bool? _dnsFilter;
  final ScrollController _dnsScrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _initialBlockedCookies = {...?widget.host?.blockedCookies};
    LogService.instance.addListener(_rebuild);
    DnsBlockService.instance.addDnsLogListener(_rebuild);
    widget.host?.onConsoleLogChanged = _rebuild;
  }

  @override
  void dispose() {
    LogService.instance.removeListener(_rebuild);
    DnsBlockService.instance.removeDnsLogListener(_rebuild);
    widget.host?.onConsoleLogChanged = null;
    // If blocked cookies changed while DevTools was open, reload the page
    // so the webview re-fetches cookies with the new rules applied.
    if (_hasSiteState &&
        !setEquals(widget.host!.blockedCookies, _initialBlockedCookies)) {
      widget.host!.reload();
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

  void _rebuild() {
    if (mounted) setState(() {});
  }

  /// A toast from a handler that may outlive the screen.
  void _toast(String Function(AppLocalizations loc) message) {
    if (mounted) {
      ScaffoldMessenger.of(context).toast(message(AppLocalizations.of(context)));
    }
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

  bool _matchesSearch(String text) =>
      text.toLowerCase().contains(_searchQuery.toLowerCase());

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final tabs = <(IconData, String, Widget)>[
      if (_hasHost) (Icons.terminal, loc.devToolsTabConsole, _buildConsoleTab()),
      if (_hasSiteState)
        (Icons.cookie_outlined, loc.devToolsTabCookies, _buildCookiesTab()),
      if (_hasSiteState && DnsBlockService.instance.hasBlocklist)
        (Icons.shield_outlined, loc.devToolsTabDns, _buildDnsTab()),
      if (ContentBlockerService.instance.usingRustEngine)
        (Icons.speed, loc.devToolsTabAbp, _buildAbpTab()),
      (Icons.list_alt, loc.devToolsTabLogs, _buildAppLogsTab()),
      if (_developerMode)
        (
          Icons.bedtime_outlined,
          loc.devToolsTabBackground,
          BackgroundLogView(searchQuery: _searchQuery),
        ),
    ];
    return DefaultTabController(
      length: tabs.length,
      initialIndex:
          widget.startOnBackground && _developerMode ? tabs.length - 1 : 0,
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
            tabs: [
              for (final (icon, label, _) in tabs)
                Tab(icon: Icon(icon, size: 18), text: label),
            ],
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
                  onChanged: (value) => setState(() => _searchQuery = value),
                ),
              ),
            Expanded(
              child: TabBarView(
                children: [for (final (_, _, body) in tabs) body],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConsoleTab() {
    final loc = AppLocalizations.of(context);
    final logs = widget.host!.consoleLogs
        .where((e) => _matchesSearch(e.message))
        .toList();
    return Column(
      children: [
        ToolActions([
          toolButton(Icons.delete_outline, label: loc.devToolsClear,
              onPressed: () => setState(widget.host!.consoleLogs.clear)),
          toolButton(Icons.copy, label: loc.devToolsCopy, onPressed: logs.isEmpty ? null : () {
            final text = logs
                .map((e) => '[${_formatTime(e.timestamp)}] [${_consoleLevelName(e.level)}] ${e.message}')
                .join('\n');
            Clipboard.setData(ClipboardData(text: text));
            ScaffoldMessenger.of(context).toast(
              loc.devToolsConsoleCopied(logs.length),
            );
          }),
        ]),
        Expanded(
          child: LogLines(
            lines: logs,
            searching: _searchQuery.isNotEmpty,
            empty: loc.devToolsConsoleEmpty,
            line: _buildConsoleEntry,
            controller: _consoleScrollController,
          ),
        ),
        _buildEvalInput(),
      ],
    );
  }

  Widget _buildConsoleEntry(ConsoleLogEntry entry) {
    // ConsoleMessageLevel is a class of constants, not an enum.
    final color = entry.isEvalInput
        ? Theme.of(context).colorScheme.primary
        : switch (entry.level) {
            ConsoleMessageLevel.WARNING => Colors.amber,
            ConsoleMessageLevel.ERROR => Colors.red,
            _ => Theme.of(context).textTheme.bodyMedium?.color ?? Colors.white,
          };
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
            if (_evalHistory.isNotEmpty)
              for (final (icon, tooltip, step) in [
                (Icons.keyboard_arrow_up, loc.devToolsEvalPrevCommand, _historyUp),
                (Icons.keyboard_arrow_down, loc.devToolsEvalNextCommand, _historyDown),
              ])
                SizedBox(
                  width: 28,
                  height: 28,
                  child: IconButton(
                    icon: Icon(icon, size: 18),
                    padding: EdgeInsets.zero,
                    tooltip: tooltip,
                    onPressed: hasController ? step : null,
                  ),
                ),
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
      _rebuild();

      // Directly embed code (no eval/Function) to respect CSP.
      // Phase 1: set sentinel. Phase 2: try as expression.
      // Phase 3: if expression had a parse error, try as statements.
      await controller.evaluateJavascript('window.__wsEvalOk=false');
      await controller.evaluateJavascript(_buildExprJs(source));
      await controller.evaluateJavascript(_buildStmtJs(source));

      _evalController.clear();
    } finally {
      if (mounted) setState(() => _isEvaluating = false);
    }
  }

  String _buildExprJs(String source) =>
      '(function(){try{var __r=(\n$source\n);if(__r!==undefined){if(typeof __r==="object"&&__r!==null){try{console.log(JSON.stringify(__r,null,2))}catch(e){console.log(String(__r))}}else{console.log(String(__r))}}window.__wsEvalOk=true}catch(__e){console.error((__e&&__e.message)?__e.message:String(__e));window.__wsEvalOk=true}})()';

  String _buildStmtJs(String source) =>
      'if(!window.__wsEvalOk){try{\n$source\n}catch(__e){console.error((__e&&__e.message)?__e.message:String(__e))}delete window.__wsEvalOk}else{delete window.__wsEvalOk}';

  void _historyUp() {
    if (_evalHistory.isEmpty) return;
    _evalHistoryIndex = _evalHistoryIndex == -1
        ? _evalHistory.length - 1
        : _evalHistoryIndex > 0 ? _evalHistoryIndex - 1 : 0;
    _showEval(_evalHistory[_evalHistoryIndex]);
  }

  /// Past the newest command the input is empty again.
  void _historyDown() {
    if (_evalHistoryIndex == -1) return;
    _evalHistoryIndex =
        _evalHistoryIndex < _evalHistory.length - 1 ? _evalHistoryIndex + 1 : -1;
    _showEval(_evalHistoryIndex == -1 ? '' : _evalHistory[_evalHistoryIndex]);
  }

  void _showEval(String source) => _evalController.value = TextEditingValue(
        text: source,
        selection: TextSelection.collapsed(offset: source.length),
      );

  Widget _buildCookiesTab() {
    final loc = AppLocalizations.of(context);
    final cookies = widget.host!.cookies
        .where((c) => <String>[c.name, c.value, c.domain ?? ''].any(_matchesSearch))
        .toList();
    final filteredBlocked = widget.host!.blockedCookies!
        .where((b) => _matchesSearch(b.name) || _matchesSearch(b.domain))
        .toList();
    return Column(
      children: [
        ToolActions([
          toolButton(Icons.refresh, label: loc.devToolsRefresh, onPressed: _refreshCookies),
          if (cookies.isNotEmpty)
            toolButton(Icons.copy, label: loc.devToolsCopyAsJson, onPressed: () {
              final json = cookies.map((c) => c.toJson()).toList();
              Clipboard.setData(
                  ClipboardData(text: const JsonEncoder.withIndent('  ').convert(json)));
              ScaffoldMessenger.of(context).toast(
                loc.devToolsCookiesCopiedJson(cookies.length),
              );
            }),
        ]),
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
        LogTag.devTools.debug('Cookie inspector via ContainerCookieManager: '
            'siteId=${widget.host!.siteId} url=$url '
            'count=${cookies.length}', sensitive: true);
      } else {
        cookies = await widget.cookieManager.getCookies(url: Uri.parse(url));
        LogTag.devTools.debug('Cookie inspector via legacy CookieManager: '
            'siteId=${widget.host!.siteId} url=$url '
            'count=${cookies.length} '
            '(container=${container != null} ctrl=${controller != null})',
            sensitive: true);
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
    if (!mounted) return;
    _toast((loc) => loc.devToolsCookieDeleted(cookie.name));
    _refreshCookies();
  }

  Future<void> _blockCookie(Cookie cookie) async {
    final domain = cookie.domain ?? extractDomain(widget.host!.currentUrl);
    final rule = BlockedCookie(name: cookie.name, domain: domain);
    setState(() {
      widget.host!.blockedCookies!.add(rule);
    });
    await _deleteCookie(cookie);
    await widget.onSave?.call();
  }

  Future<void> _unblockCookie(BlockedCookie rule) async {
    setState(() {
      widget.host!.blockedCookies!.remove(rule);
    });
    await widget.onSave?.call();
    _toast((loc) => loc.devToolsCookieUnblocked(rule.name));
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
                    color: cookie.isSecure == true ? Colors.green : Colors.red,
                  ),
                  if (cookie.isHttpOnly == true)
                    _buildSecurityChip('HttpOnly', color: Colors.green),
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

  Widget _buildSecurityChip(String label, {required Color color}) {
    return Chip(
      label: Text(label, style: TextStyle(fontSize: 11, color: color)),
      backgroundColor: color.withAlpha(25),
      side: BorderSide(color: color.withAlpha(76)),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }

  Widget _buildSameSiteChip(String value) {
    final (label, color) = value.contains('STRICT')
        ? ('SameSite=Strict', Colors.green)
        : value.contains('LAX')
            ? ('SameSite=Lax', Colors.blue)
            : ('SameSite=None', Colors.amber);
    return _buildSecurityChip(label, color: color);
  }

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
                                      ScaffoldMessenger.of(context).toast(
                                        loc.devToolsScriptCopied(script.name),
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
              for (final (icon, label, export, enabled) in [
                (Icons.share, loc.devToolsShareHtml, _shareHtml, true),
                (Icons.save, loc.devToolsSaveToFile, _saveHtmlToFile, true),
                (Icons.copy, loc.devToolsCopyToClipboard, _copyHtml, true),
                (Icons.image_outlined, loc.devToolsSaveIcon, _saveIconAsPng,
                    !_isSavingIcon),
              ])
                ListTile(
                  leading: Icon(icon),
                  title: Text(label),
                  enabled: enabled,
                  onTap: () {
                    Navigator.pop(sheetContext);
                    export();
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
        _toast((loc) => loc.devToolsNoHtmlContent);
        return null;
      }
      return _exportedHtml = html;
    } catch (e) {
      _toast((loc) => loc.devToolsHtmlFetchFailed(e.toString()));
      return null;
    } finally {
      _isFetchingHtml = false;
    }
  }

  String get _htmlFileName {
    final domain = extractDomain(widget.host!.currentUrl);
    final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-').split('.')[0];
    return '${domain}_$timestamp.html';
  }

  /// Saves [bytes] as [fileName] through the platform dialog: on mobile the
  /// picker takes the bytes, on desktop they go to the path it returns. False
  /// when the user picked no place.
  Future<bool> _saveAs(String fileName,
      {required String dialogTitle, required Uint8List bytes}) async {
    final isMobile = !kIsWeb && (hostIsIOS || hostIsAndroid);
    final outputPath = await FilePicker.saveFile(
      dialogTitle: dialogTitle,
      fileName: fileName,
      bytes: isMobile ? bytes : null,
    );
    if (outputPath == null) return false;
    if (!isMobile) {
      final ext = fileName.substring(fileName.lastIndexOf('.'));
      await hostWriteFileBytes(
          outputPath.endsWith(ext) ? outputPath : '$outputPath$ext',
          bytes: bytes);
    }
    return true;
  }

  Future<void> _shareHtml() async {
    final html = _exportedHtml ?? await _fetchHtml();
    if (html == null || !mounted) return;
    SharePlus.instance.share(ShareParams(text: html, title: _htmlFileName));
  }

  Future<void> _saveHtmlToFile() async {
    final html = _exportedHtml ?? await _fetchHtml();
    if (html == null || !mounted) return;
    final title = AppLocalizations.of(context).devToolsSaveHtmlDialogTitle;
    try {
      if (await _saveAs(_htmlFileName,
          dialogTitle: title, bytes: utf8.encode(html))) {
        _toast((loc) => loc.devToolsHtmlSaved);
      }
    } catch (e) {
      _toast((loc) => loc.devToolsSaveFailed(e.toString()));
    }
  }

  void _copyHtml() async {
    final html = _exportedHtml ?? await _fetchHtml();
    if (html == null || !mounted) return;
    Clipboard.setData(ClipboardData(text: html));
    _toast((loc) => loc.devToolsHtmlCopied);
  }

  Future<void> _saveIconAsPng() async {
    if (_isSavingIcon) return;
    setState(() => _isSavingIcon = true);
    final host = widget.host!;
    final loc = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    messenger.toast(loc.devToolsPreparingIcon);
    try {
      final png = await displayedSiteIconAsPng(
        host.iconUrl,
        customIcon: host.customIcon,
        resolvedIconUrl: FaviconUrlCache.get(host.iconUrl),
        proxy: host.proxy,
      );
      if (!mounted) return;
      if (png == null) {
        messenger.toast(loc.devToolsNoIconToSave);
        return;
      }
      final fileName = '${extractDomain(host.currentUrl)}_icon.png';
      if (await _saveAs(fileName,
              dialogTitle: loc.devToolsSaveIconDialogTitle, bytes: png) &&
          mounted) {
        messenger.toast(loc.devToolsIconSaved);
      }
    } catch (e) {
      if (mounted) messenger.toast(loc.devToolsSaveFailed(e.toString()));
    } finally {
      if (mounted) setState(() => _isSavingIcon = false);
    }
  }

  Widget _buildDnsTab() {
    final loc = AppLocalizations.of(context);
    final stats = DnsBlockService.instance.statsForSite(widget.host!.siteId!);
    final entries = stats.log
        .where((e) =>
            (_dnsFilter == null || e.blocked == _dnsFilter) &&
            _matchesSearch(e.domain))
        .toList();

    return Column(
      children: [
        DnsStatChips(stats, padding: const EdgeInsets.fromLTRB(12, 8, 12, 4)),
        _buildDnsFilters(stats),
        ToolActions([
          toolButton(Icons.delete_outline, label: loc.devToolsClear,
              onPressed: () => DnsBlockService.instance.clearStatsForSite(widget.host!.siteId!)),
          toolButton(
            Icons.copy,
            label: loc.devToolsCopy,
            onPressed: entries.isEmpty ? null : () {
              final text = entries
                  .map((e) =>
                      '[${_formatTimeMs(e.timestamp)}] ${e.blocked ? 'BLOCKED' : 'ALLOWED'} ${e.domain}')
                  .join('\n');
              Clipboard.setData(ClipboardData(text: text));
              ScaffoldMessenger.of(context).toast(loc.devToolsDnsLogCopied);
            },
            key: const Key('devtools-dns-copy'),
          ),
        ]),
        Expanded(
          child: LogLines(
            lines: entries,
            searching: _searchQuery.isNotEmpty,
            empty: loc.devToolsDnsEmpty,
            line: _buildDnsEntry,
            controller: _dnsScrollController,
          ),
        ),
      ],
    );
  }

  Widget _buildDnsFilters(DnsStats stats) {
    final loc = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        spacing: 6,
        children: [
          for (final (filter, label) in [
            (null, loc.devToolsDnsFilterAll),
            (false, loc.devToolsDnsFilterAllowed(stats.allowed)),
            (true, loc.devToolsDnsFilterBlocked(stats.blocked)),
          ])
            FilterChip(
              label: Text(label, style: const TextStyle(fontSize: 12)),
              selected: _dnsFilter == filter,
              onSelected: (_) =>
                  setState(() => _dnsFilter = _dnsFilter == filter ? null : filter),
              visualDensity: VisualDensity.compact,
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

  Widget _buildAbpTab() {
    final svc = ContentBlockerService.instance;
    final samples = svc.recentEngineDecisions;
    final reversed = samples.reversed.toList();
    // Timing stats come from the sample window; blocked/allowed use the
    // cumulative counters so they don't decay when the ring rolls over
    // and include natively-decided blocks that carry no timing.
    final blockedCount = svc.engineBlockedSinceTimingOn;
    final allowedCount = svc.engineAllowedSinceTimingOn;
    int totalMicros = 0;
    int maxMicros = 0;
    int timedCount = 0;
    for (final s in samples) {
      final micros = s.micros;
      if (micros == null) continue;
      timedCount++;
      totalMicros += micros;
      if (micros > maxMicros) maxMicros = micros;
    }
    final avgMicros = timedCount == 0 ? 0 : totalMicros ~/ timedCount;

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
              StatChip(
                  svc.usingRustEngine
                      ? loc.devToolsAbpActive
                      : loc.devToolsAbpOff,
                  label: loc.devToolsAbpEngine,
                  color: svc.usingRustEngine ? Colors.green : Colors.grey),
              StatChip(timingOn ? loc.devToolsAbpOn : loc.devToolsAbpOff,
                  label: loc.devToolsAbpRecording,
                  color: timingOn ? Colors.green : Colors.orange),
              StatChip('$consulted', label: loc.devToolsAbpConsulted,
                  color: Colors.blueGrey),
              StatChip(avgValue, label: loc.devToolsAbpAvg, color: Colors.blueGrey),
              StatChip(maxValue, label: loc.devToolsAbpMax,
                  color: maxMicros > 1000 ? Colors.orange : Colors.blueGrey),
              StatChip('$blockedCount', label: loc.devToolsAbpBlocked, color: Colors.red),
              StatChip('$allowedCount', label: loc.devToolsAbpAllowed, color: Colors.green),
              StatChip(
                  svc.useUboResources ? loc.devToolsAbpOn : loc.devToolsAbpOff,
                  label: 'uBO',
                  color: svc.useUboResources ? Colors.green : Colors.grey),
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

  Widget _buildAbpRow(EngineDecisionSample s) {
    final color = s.blocked ? Colors.red.shade400 : Colors.green.shade600;
    final micros = s.micros;
    final subtitle =
        micros == null ? s.requestType : '${s.requestType} · $micros µs';
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

  Widget _buildAppLogsTab() {
    final loc = AppLocalizations.of(context);
    final allEntries = _showSensitive
        ? LogService.instance.allEntriesMerged
        : LogService.instance.entries;
    final filtered = allEntries
        .where((e) =>
            _activeFilters.contains(e.level) &&
            (_matchesSearch(e.message) || _matchesSearch(e.tag)))
        .toList();

    return Column(
      children: [
        ToolActions([
          toolButton(
            Icons.save,
            label: loc.devToolsExport,
            onPressed: () => saveLogText(context, text: LogService.instance.export(),
                fileNamePrefix: 'webspace_logs'),
          ),
          toolButton(Icons.copy, label: loc.devToolsCopy,
              onPressed: filtered.isEmpty ? null : () => _copyLogs(filtered),
              key: const Key('devtools-logs-copy')),
          toolButton(Icons.delete_outline, label: loc.devToolsClear,
              onPressed: () => setState(LogService.instance.clear)),
        ]),
        _buildLogFilters(),
        SensitiveSwitch(
          value: _showSensitive,
          onChanged: (v) => setState(() => _showSensitive = v),
          label: _showSensitive
              ? loc.devToolsSensitiveShowing
              : loc.devToolsSensitiveShow,
        ),
        if (_developerMode && widget.onSimulateBackgroundRefresh != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8.0),
            child: Wrap(
              spacing: 4,
              children: [
                toolButton(Icons.refresh, label: loc.devToolsSimulateRefresh,
                    onPressed: _simulateBackgroundRefresh),
                toolButton(Icons.notifications_active, label: loc.devToolsTestNotification,
                    onPressed: widget.host?.siteId != null ? _sendTestNotification : null),
              ],
            ),
          ),
        Expanded(
          child: LogLines(
            lines: filtered,
            searching: _searchQuery.isNotEmpty,
            empty: loc.devToolsLogsEmpty,
            line: (entry) =>
                LogEntryLine(entry: entry, time: _formatTime(entry.timestamp)),
            controller: _logScrollController,
          ),
        ),
      ],
    );
  }

  Future<void> _simulateBackgroundRefresh() async {
    await widget.onSimulateBackgroundRefresh!();
    _rebuild();
    _toast((loc) => loc.devToolsSimulateRefreshDone);
  }

  Future<void> _sendTestNotification() async {
    final loc = AppLocalizations.of(context);
    final siteId = widget.host?.siteId;
    if (siteId == null) return;
    await NotificationService.instance.show(
      siteId: siteId,
      title: loc.devToolsTestNotificationTitle,
      body: loc.devToolsTestNotificationBody,
      origin: NotificationOrigin.test,
    );
    _rebuild();
    _toast((loc) => loc.devToolsTestNotificationSent);
  }

  /// Copies exactly what the Logs tab shows.
  Future<void> _copyLogs(List<LogEntry> filtered) => _copyLogsGuard.run(
        () => copyLogs(
          context,
          entries: filtered,
          consent: AppLocalizations.of(context).devToolsLogsCopySensitiveBody,
          format: ({required includeSensitive}) =>
              LogService.formatForClipboard(filtered,
                  includeSensitive: includeSensitive),
        ),
      );

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
