import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' show ConsoleMessageLevel;
import 'package:share_plus/share_plus.dart';

import 'package:webspace/web_view_model.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/settings/user_script.dart';

typedef VoidAsyncCallback = Future<void> Function();

class DevToolsScreen extends StatefulWidget {
  final WebViewModel? webViewModel;
  final CookieManager cookieManager;
  final VoidAsyncCallback? onSave;

  const DevToolsScreen({
    super.key,
    this.webViewModel,
    required this.cookieManager,
    this.onSave,
  });

  @override
  State<DevToolsScreen> createState() => _DevToolsScreenState();
}

class _DevToolsScreenState extends State<DevToolsScreen> {
  bool _loadingCookies = false;
  String? _exportedHtml;
  bool _isFetchingHtml = false;
  final Set<LogLevel> _activeFilters = LogLevel.values.toSet();

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

  bool get _hasSite => widget.webViewModel != null;

  int get _tabCount => _hasSite ? 3 : 1;

  @override
  void initState() {
    super.initState();
    _initialBlockedCookies = _hasSite
        ? Set<BlockedCookie>.of(widget.webViewModel!.blockedCookies)
        : <BlockedCookie>{};
    LogService.instance.addListener(_onLogUpdate);
    if (_hasSite) {
      widget.webViewModel!.onConsoleLogChanged = _onConsoleUpdate;
    }
  }

  @override
  void dispose() {
    LogService.instance.removeListener(_onLogUpdate);
    if (_hasSite) {
      widget.webViewModel!.onConsoleLogChanged = null;
      // If blocked cookies changed while DevTools was open, reload the page
      // so the webview re-fetches cookies with the new rules applied.
      final current = widget.webViewModel!.blockedCookies;
      if (!_setEquals(current, _initialBlockedCookies)) {
        widget.webViewModel!.controller?.reload();
      }
    }
    _consoleScrollController.dispose();
    _logScrollController.dispose();
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

  List<Tab> get _tabs => [
        if (_hasSite)
          const Tab(icon: Icon(Icons.terminal, size: 18), text: 'Console'),
        if (_hasSite)
          const Tab(icon: Icon(Icons.cookie_outlined, size: 18), text: 'Cookies'),
        const Tab(icon: Icon(Icons.list_alt, size: 18), text: 'Logs'),
      ];

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
    return DefaultTabController(
      length: _tabCount,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Developer Tools'),
          actions: [
            if (_hasSite)
              IconButton(
                icon: const Icon(Icons.code, size: 20),
                tooltip: 'Scripts',
                onPressed: _showScriptsSheet,
              ),
            if (_hasSite)
              IconButton(
                icon: const Icon(Icons.share, size: 20),
                tooltip: 'Share HTML',
                onPressed: _showShareSheet,
              ),
            IconButton(
              icon: Icon(_isSearchVisible ? Icons.search_off : Icons.search),
              tooltip: 'Search',
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
                    hintText: 'Filter...',
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
                  if (_hasSite) _buildConsoleTab(),
                  if (_hasSite) _buildCookiesTab(),
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
    final allLogs = widget.webViewModel!.consoleLogs;
    final logs = _searchQuery.isEmpty
        ? allLogs
        : allLogs.where((e) => _matchesSearch(e.message)).toList();
    return Column(
      children: [
        _buildConsoleActions(logs),
        Expanded(
          child: logs.isEmpty
              ? Center(child: Text(_searchQuery.isEmpty ? 'No console messages' : 'No matches'))
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
      child: Row(
        children: [
          TextButton.icon(
            onPressed: () {
              setState(() {
                widget.webViewModel!.consoleLogs.clear();
              });
            },
            icon: const Icon(Icons.delete_outline, size: 18),
            label: const Text('Clear'),
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
                      SnackBar(content: Text('Copied ${logs.length} console log${logs.length == 1 ? '' : 's'}')),
                    );
                  },
            icon: const Icon(Icons.copy, size: 18),
            label: const Text('Copy'),
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

  Widget _buildEvalInput() {
    final hasController = widget.webViewModel?.controller != null;
    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      padding: const EdgeInsets.only(left: 8.0, right: 4.0, top: 4.0, bottom: 4.0),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            Text('>', style: TextStyle(
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
                decoration: const InputDecoration(
                  hintText: 'Evaluate JavaScript...',
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(vertical: 8.0, horizontal: 8.0),
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
                  tooltip: 'Previous command',
                  onPressed: hasController ? _historyUp : null,
                ),
              ),
              SizedBox(
                width: 28,
                height: 28,
                child: IconButton(
                  icon: const Icon(Icons.keyboard_arrow_down, size: 18),
                  padding: EdgeInsets.zero,
                  tooltip: 'Next command',
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
                tooltip: 'Run',
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

    final controller = widget.webViewModel?.controller;
    if (controller == null) return;

    if (_isEvaluating) return;
    setState(() => _isEvaluating = true);

    try {
      if (_evalHistory.isEmpty || _evalHistory.last != source) {
        _evalHistory.add(source);
      }
      _evalHistoryIndex = -1;

      widget.webViewModel!.consoleLogs.add(ConsoleLogEntry(
        timestamp: DateTime.now(),
        message: source,
        level: ConsoleMessageLevel.LOG,
        isEvalInput: true,
      ));
      widget.webViewModel!.onConsoleLogChanged?.call();

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
    final allCookies = widget.webViewModel!.cookies;
    final blocked = widget.webViewModel!.blockedCookies;
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
                  ? Center(child: Text(_searchQuery.isEmpty ? 'No cookies' : 'No matches'))
                  : ListView(
                      children: [
                        if (filteredBlocked.isNotEmpty) ...[
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                            child: Text(
                              'Blocked (${filteredBlocked.length})',
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
      child: Row(
        children: [
          TextButton.icon(
            onPressed: _refreshCookies,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('Refresh'),
          ),
          if (cookies.isNotEmpty)
            TextButton.icon(
              onPressed: () {
                final json = cookies.map((c) => c.toJson()).toList();
                Clipboard.setData(
                    ClipboardData(text: const JsonEncoder.withIndent('  ').convert(json)));
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Copied ${cookies.length} cookie${cookies.length == 1 ? '' : 's'} as JSON')),
                );
              },
              icon: const Icon(Icons.copy, size: 18),
              label: const Text('Copy as JSON'),
            ),
        ],
      ),
    );
  }

  Future<void> _refreshCookies() async {
    final url = widget.webViewModel!.currentUrl;
    if (url.isEmpty) return;
    setState(() => _loadingCookies = true);
    try {
      final cookies = await widget.cookieManager.getCookies(url: Uri.parse(url));
      if (mounted) {
        widget.webViewModel!.cookies = cookies;
        setState(() => _loadingCookies = false);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loadingCookies = false);
      }
    }
  }

  Future<void> _deleteCookie(Cookie cookie) async {
    final url = Uri.parse(widget.webViewModel!.currentUrl);
    await widget.cookieManager.deleteCookie(
      url: url,
      name: cookie.name,
      domain: cookie.domain,
      path: cookie.path ?? '/',
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Deleted cookie "${cookie.name}"')),
      );
      _refreshCookies();
    }
  }

  Future<void> _blockCookie(Cookie cookie) async {
    final domain = cookie.domain ?? extractDomain(widget.webViewModel!.currentUrl);
    final rule = BlockedCookie(name: cookie.name, domain: domain);
    setState(() {
      widget.webViewModel!.blockedCookies.add(rule);
    });
    // Delete the cookie immediately from the webview
    await _deleteCookie(cookie);
    await widget.onSave?.call();
  }

  Future<void> _unblockCookie(BlockedCookie rule) async {
    setState(() {
      widget.webViewModel!.blockedCookies.remove(rule);
    });
    await widget.onSave?.call();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Unblocked cookie "${rule.name}"')),
      );
    }
  }

  Widget _buildCookieTile(Cookie cookie) {
    return ExpansionTile(
      title: Text(cookie.name, style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
      subtitle: Text(
        cookie.value.length > 60 ? '${cookie.value.substring(0, 60)}...' : cookie.value,
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
                Text('Domain: ${cookie.domain}', style: const TextStyle(fontSize: 12)),
              if (cookie.path != null)
                Text('Path: ${cookie.path}', style: const TextStyle(fontSize: 12)),
              if (cookie.expiresDate != null)
                Text(
                  'Expires: ${DateTime.fromMillisecondsSinceEpoch(cookie.expiresDate!)}',
                  style: const TextStyle(fontSize: 12),
                ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  _buildSecurityChip(
                    cookie.isSecure == true ? 'Secure' : 'Not Secure',
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
                    label: const Text('Delete', style: TextStyle(color: Colors.red, fontSize: 12)),
                  ),
                  const SizedBox(width: 8),
                  TextButton.icon(
                    onPressed: () => _blockCookie(cookie),
                    icon: const Icon(Icons.block, size: 16, color: Colors.orange),
                    label: const Text('Block', style: TextStyle(color: Colors.orange, fontSize: 12)),
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
    return ListTile(
      leading: Icon(Icons.block, color: Colors.red.shade300, size: 20),
      title: Text(rule.name, style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
      subtitle: Text(rule.domain, style: const TextStyle(fontSize: 11)),
      trailing: TextButton.icon(
        onPressed: () => _unblockCookie(rule),
        icon: const Icon(Icons.check_circle_outline, size: 16, color: Colors.green),
        label: const Text('Unblock', style: TextStyle(color: Colors.green, fontSize: 12)),
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
    final scripts = widget.webViewModel!.userScripts;
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
                    child: Text('No user scripts configured',
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
                      Text('Scripts', style: Theme.of(context).textTheme.titleMedium),
                      const Spacer(),
                      Text('${scripts.length}',
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
                      return ExpansionTile(
                        leading: Icon(
                          script.enabled ? Icons.code : Icons.code_off,
                          color: script.enabled ? Colors.green : Colors.grey,
                          size: 20,
                        ),
                        title: Text(script.name,
                            style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
                        subtitle: Text(
                          script.injectionTime == UserScriptInjectionTime.atDocumentStart
                              ? 'document start'
                              : 'document end',
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
                                  script.source.isEmpty ? '// (empty script)' : script.source,
                                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                                ),
                                Positioned(
                                  top: 0,
                                  right: 0,
                                  child: IconButton(
                                    icon: const Icon(Icons.copy, size: 16),
                                    tooltip: 'Copy source',
                                    onPressed: () {
                                      Clipboard.setData(ClipboardData(text: script.source));
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(content: Text('Copied "${script.name}"')),
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
                title: const Text('Share HTML'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _shareHtml();
                },
              ),
              ListTile(
                leading: const Icon(Icons.save),
                title: const Text('Save to file'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _saveHtmlToFile();
                },
              ),
              ListTile(
                leading: const Icon(Icons.copy),
                title: const Text('Copy to clipboard'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _copyHtml();
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
    final controller = widget.webViewModel!.controller;
    if (controller == null) return null;

    _isFetchingHtml = true;
    try {
      final html = await controller.getHtml();
      if (html == null || html.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No HTML content available')),
          );
        }
        return null;
      }
      _exportedHtml = html;
      return html;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to get HTML: $e')),
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

    final domain = extractDomain(widget.webViewModel!.currentUrl);
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
      final domain = extractDomain(widget.webViewModel!.currentUrl);
      final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-').split('.')[0];
      final fileName = '${domain}_$timestamp.html';
      final bytes = utf8.encode(html);

      final bool isMobile = !kIsWeb && (Platform.isIOS || Platform.isAndroid);
      final outputPath = await FilePicker.saveFile(
        dialogTitle: 'Save HTML',
        fileName: fileName,
        bytes: isMobile ? bytes : null,
      );

      if (outputPath != null && !isMobile) {
        final filePath = outputPath.endsWith('.html') ? outputPath : '$outputPath.html';
        await File(filePath).writeAsString(html);
      }

      if (mounted && outputPath != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('HTML saved')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Save failed: $e')),
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
        const SnackBar(content: Text('HTML copied to clipboard')),
      );
    }
  }

  // ── App Logs Tab ──

  Widget _buildAppLogsTab() {
    final allEntries = LogService.instance.entries;
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
        Expanded(
          child: filtered.isEmpty
              ? Center(child: Text(_searchQuery.isEmpty ? 'No log entries' : 'No matches'))
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

  Widget _buildLogActions(List<LogEntry> filtered) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
      child: Row(
        children: [
          TextButton.icon(
            onPressed: _exportLogs,
            icon: const Icon(Icons.save, size: 18),
            label: const Text('Export'),
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
                      SnackBar(content: Text('Copied ${filtered.length} log entr${filtered.length == 1 ? 'y' : 'ies'}')),
                    );
                  },
            icon: const Icon(Icons.copy, size: 18),
            label: const Text('Copy'),
          ),
          TextButton.icon(
            onPressed: () {
              LogService.instance.clear();
              setState(() {});
            },
            icon: const Icon(Icons.delete_outline, size: 18),
            label: const Text('Clear'),
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 1.0),
      child: SelectableText(
        '[${_formatTime(entry.timestamp)}] [${entry.tag}] ${entry.message}',
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
    final outputPath = await FilePicker.saveFile(
      dialogTitle: 'Export Logs',
      fileName: fileName,
      bytes: isMobile ? bytes : null,
    );

    if (outputPath != null && !isMobile) {
      final filePath = outputPath.endsWith('.txt') ? outputPath : '$outputPath.txt';
      await File(filePath).writeAsString(text);
    }

    if (mounted && outputPath != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Logs exported')),
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
