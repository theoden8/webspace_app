import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' show ConsoleMessageLevel;

import 'package:webspace/web_view_model.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/settings/user_script.dart';

class DevToolsScreen extends StatefulWidget {
  final WebViewModel? webViewModel;
  final CookieManager cookieManager;

  const DevToolsScreen({
    super.key,
    this.webViewModel,
    required this.cookieManager,
  });

  @override
  State<DevToolsScreen> createState() => _DevToolsScreenState();
}

class _DevToolsScreenState extends State<DevToolsScreen> {
  bool _loadingCookies = false;
  String? _exportedHtml;
  bool _loadingHtml = false;
  final Set<LogLevel> _activeFilters = LogLevel.values.toSet();

  bool get _hasSite => widget.webViewModel != null;

  int get _tabCount => _hasSite ? 5 : 1;

  List<Tab> get _tabs => [
        if (_hasSite) const Tab(text: 'Console'),
        if (_hasSite) const Tab(text: 'Cookies'),
        if (_hasSite) const Tab(text: 'Scripts'),
        if (_hasSite) const Tab(text: 'Export'),
        const Tab(text: 'App Logs'),
      ];

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: _tabCount,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Developer Tools'),
          bottom: TabBar(
            tabs: _tabs,
            isScrollable: true,
            tabAlignment: TabAlignment.start,
          ),
        ),
        body: TabBarView(
          children: [
            if (_hasSite) _buildConsoleTab(),
            if (_hasSite) _buildCookiesTab(),
            if (_hasSite) _buildScriptsTab(),
            if (_hasSite) _buildExportTab(),
            _buildAppLogsTab(),
          ],
        ),
      ),
    );
  }

  // ── Console Tab ──

  Widget _buildConsoleTab() {
    final logs = widget.webViewModel!.consoleLogs;
    return Column(
      children: [
        _buildConsoleActions(),
        Expanded(
          child: logs.isEmpty
              ? const Center(child: Text('No console messages'))
              : ListView.builder(
                  itemCount: logs.length,
                  itemBuilder: (context, index) {
                    final entry = logs[index];
                    return _buildConsoleEntry(entry);
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildConsoleActions() {
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
            onPressed: () {
              final text = widget.webViewModel!.consoleLogs
                  .map((e) => '[${_formatTime(e.timestamp)}] [${_consoleLevelName(e.level)}] ${e.message}')
                  .join('\n');
              Clipboard.setData(ClipboardData(text: text));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Console logs copied')),
              );
            },
            icon: const Icon(Icons.copy, size: 18),
            label: const Text('Copy All'),
          ),
        ],
      ),
    );
  }

  Widget _buildConsoleEntry(ConsoleLogEntry entry) {
    Color color;
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 2.0),
      child: Text(
        '[${_formatTimeMs(entry.timestamp)}] ${entry.message}',
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 12,
          color: color,
        ),
      ),
    );
  }

  // ── Cookies Tab ──

  Widget _buildCookiesTab() {
    final cookies = widget.webViewModel!.cookies;
    return Column(
      children: [
        _buildCookieActions(cookies),
        Expanded(
          child: _loadingCookies
              ? const Center(child: CircularProgressIndicator())
              : cookies.isEmpty
                  ? const Center(child: Text('No cookies'))
                  : ListView.builder(
                      itemCount: cookies.length,
                      itemBuilder: (context, index) =>
                          _buildCookieTile(cookies[index]),
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
                  const SnackBar(content: Text('Cookies copied as JSON')),
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
              TextButton.icon(
                onPressed: () => _deleteCookie(cookie),
                icon: const Icon(Icons.delete_outline, size: 16, color: Colors.red),
                label: const Text('Delete', style: TextStyle(color: Colors.red, fontSize: 12)),
              ),
            ],
          ),
        ),
      ],
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

  // ── Scripts Tab ──

  Widget _buildScriptsTab() {
    final scripts = widget.webViewModel!.userScripts;
    if (scripts.isEmpty) {
      return const Center(child: Text('No user scripts configured'));
    }
    return ListView.builder(
      itemCount: scripts.length,
      itemBuilder: (context, index) {
        final script = scripts[index];
        return ExpansionTile(
          leading: Icon(
            script.enabled ? Icons.code : Icons.code_off,
            color: script.enabled ? Colors.green : Colors.grey,
            size: 20,
          ),
          title: Text(script.name, style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
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
    );
  }

  // ── Export Tab ──

  Widget _buildExportTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _loadingHtml ? null : _exportHtml,
                  icon: const Icon(Icons.save),
                  label: const Text('Export HTML'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _exportedHtml != null ? _copyHtml : null,
                  icon: const Icon(Icons.copy),
                  label: const Text('Copy to Clipboard'),
                ),
              ),
            ],
          ),
          if (_loadingHtml)
            const Padding(
              padding: EdgeInsets.all(16.0),
              child: Center(child: CircularProgressIndicator()),
            ),
          if (_exportedHtml != null) ...[
            const SizedBox(height: 16),
            Text(
              'Preview (first 200 lines):',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(8.0),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                _getPreview(_exportedHtml!, 200),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _exportHtml() async {
    final controller = widget.webViewModel!.controller;
    if (controller == null) return;

    setState(() => _loadingHtml = true);
    try {
      final html = await controller.getHtml();
      if (html == null || html.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No HTML content available')),
          );
        }
        setState(() => _loadingHtml = false);
        return;
      }

      setState(() {
        _exportedHtml = html;
        _loadingHtml = false;
      });

      // Save to file
      final domain = extractDomain(widget.webViewModel!.currentUrl);
      final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-').split('.')[0];
      final fileName = '${domain}_$timestamp.html';
      final bytes = utf8.encode(html);

      final bool isMobile = !kIsWeb && (Platform.isIOS || Platform.isAndroid);
      final outputPath = await FilePicker.platform.saveFile(
        dialogTitle: 'Export HTML',
        fileName: fileName,
        bytes: isMobile ? bytes : null,
      );

      if (outputPath != null && !isMobile) {
        final filePath = outputPath.endsWith('.html') ? outputPath : '$outputPath.html';
        await File(filePath).writeAsString(html);
      }

      if (mounted && outputPath != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('HTML exported')),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loadingHtml = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export failed: $e')),
        );
      }
    }
  }

  void _copyHtml() {
    if (_exportedHtml == null) return;
    Clipboard.setData(ClipboardData(text: _exportedHtml!));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('HTML copied to clipboard')),
    );
  }

  String _getPreview(String text, int maxLines) {
    final lines = text.split('\n');
    if (lines.length <= maxLines) return text;
    return lines.take(maxLines).join('\n');
  }

  // ── App Logs Tab ──

  Widget _buildAppLogsTab() {
    final allEntries = LogService.instance.entries;
    final filtered = _activeFilters.length == LogLevel.values.length
        ? allEntries
        : allEntries.where((e) => _activeFilters.contains(e.level)).toList();

    return Column(
      children: [
        _buildLogActions(),
        _buildLogFilters(),
        Expanded(
          child: filtered.isEmpty
              ? const Center(child: Text('No log entries'))
              : ListView.builder(
                  itemCount: filtered.length,
                  itemBuilder: (context, index) {
                    final entry = filtered[index];
                    return _buildLogEntry(entry);
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildLogActions() {
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
            onPressed: () {
              Clipboard.setData(ClipboardData(text: LogService.instance.export()));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Logs copied to clipboard')),
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
      child: Text(
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
    final outputPath = await FilePicker.platform.saveFile(
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
