import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/services/background_log.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/widgets/log_entry_line.dart';

/// DEVTOOLS-011: the Background tab of Developer Tools. Shows what the
/// background log kept, across restarts and native steps, under the OS state
/// a refresh and a notification depend on.
class BackgroundLogView extends StatefulWidget {
  const BackgroundLogView({super.key, this.searchQuery = '', this.log});

  final String searchQuery;

  /// Defaults to [BackgroundLog.instance]; tests pass their own.
  final BackgroundLog? log;

  @override
  State<BackgroundLogView> createState() => _BackgroundLogViewState();
}

class _BackgroundLogViewState extends State<BackgroundLogView> {
  late final BackgroundLog _log = widget.log ?? BackgroundLog.instance;

  /// Consent to display only: memory-only entries, reset with the process.
  bool _showSensitive = false;
  List<LogEntry> _entries = const [];
  List<MapEntry<String, String>> _state = const [];
  bool _loaded = false;
  bool _isCopying = false;
  Timer? _reloadDebounce;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _log.addListener(_onLogChanged);
    unawaited(_load(withState: true));
  }

  @override
  void dispose() {
    _log.removeListener(_onLogChanged);
    _reloadDebounce?.cancel();
    super.dispose();
  }

  void _onLogChanged() {
    _reloadDebounce?.cancel();
    _reloadDebounce = Timer(BackgroundLog.burstQuiet, _load);
  }

  Future<void> _load({bool withState = false}) async {
    final generation = ++_loadGeneration;
    final entries = await _log.entries(includeSensitive: _showSensitive);
    final state = withState ? await _log.systemState() : _state;
    if (!mounted || generation != _loadGeneration) return;
    setState(() {
      _entries = entries;
      _state = state;
      _loaded = true;
    });
  }

  List<LogEntry> get _visible {
    final q = widget.searchQuery.toLowerCase();
    if (q.isEmpty) return _entries;
    return _entries
        .where((e) =>
            e.message.toLowerCase().contains(q) ||
            e.tag.toLowerCase().contains(q))
        .toList();
  }

  /// Sensitive entries reach the clipboard only through this confirmation:
  /// the switch is consent to show them, not to hand them to clipboard
  /// history or a cloud clipboard.
  Future<void> _copy(List<LogEntry> visible) async {
    if (_isCopying) return;
    final loc = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final sensitive =
        visible.where((e) => e.sensitivity == LogSensitivity.sensitive).length;
    var includeSensitive = false;
    _isCopying = true;
    try {
      if (sensitive > 0) {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(loc.devToolsLogsCopySensitiveTitle),
            content: Text(loc.devToolsBackgroundCopySensitiveBody(sensitive)),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: Text(loc.commonCancel),
              ),
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: Text(loc.devToolsCopy),
              ),
            ],
          ),
        );
        if (confirmed != true || !mounted) return;
        includeSensitive = true;
      }
      await Clipboard.setData(ClipboardData(
        text: BackgroundLog.format(visible, includeSensitive: includeSensitive),
      ));
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(loc.devToolsLogsCopied(visible.length))),
      );
    } finally {
      _isCopying = false;
    }
  }

  Future<void> _export() async {
    final entries = await _log.entries(includeSensitive: false);
    if (!mounted) return;
    await saveLogText(context, BackgroundLog.format(entries),
        fileNamePrefix: 'webspace_background_log');
  }

  Future<void> _clear() async {
    await _log.clear();
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final visible = _visible;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
          child: Wrap(
            spacing: 4,
            children: [
              TextButton.icon(
                key: const Key('background-log-refresh'),
                onPressed: () => _load(withState: true),
                icon: const Icon(Icons.refresh, size: 18),
                label: Text(loc.devToolsRefresh),
              ),
              TextButton.icon(
                onPressed: _entries.isEmpty ? null : _export,
                icon: const Icon(Icons.save, size: 18),
                label: Text(loc.devToolsExport),
              ),
              TextButton.icon(
                key: const Key('background-log-copy'),
                onPressed: visible.isEmpty ? null : () => _copy(visible),
                icon: const Icon(Icons.copy, size: 18),
                label: Text(loc.devToolsCopy),
              ),
              TextButton.icon(
                onPressed: _entries.isEmpty ? null : _clear,
                icon: const Icon(Icons.delete_outline, size: 18),
                label: Text(loc.devToolsClear),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12.0),
          child: Row(
            children: [
              Switch(
                key: const Key('background-log-sensitive'),
                value: _showSensitive,
                onChanged: (v) {
                  setState(() => _showSensitive = v);
                  unawaited(_load());
                },
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  _showSensitive
                      ? loc.devToolsBackgroundSensitiveShowing
                      : loc.devToolsBackgroundSensitiveShow,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
        if (_state.isNotEmpty)
          ExpansionTile(
            title: Text(loc.devToolsBackgroundSystemState),
            initiallyExpanded: true,
            dense: true,
            childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            expandedCrossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final row in _state) _stateRow(row),
            ],
          ),
        Expanded(
          child: !_loaded
              ? const Center(child: CircularProgressIndicator())
              : visible.isEmpty
                  ? Center(
                      child: Text(widget.searchQuery.isEmpty
                          ? loc.devToolsBackgroundEmpty
                          : loc.devToolsNoMatches),
                    )
                  : ListView.builder(
                      reverse: widget.searchQuery.isEmpty,
                      itemCount: visible.length,
                      itemBuilder: (context, index) {
                        final entry = visible[visible.length - 1 - index];
                        return LogEntryLine(
                          entry: entry,
                          time: BackgroundLog.formatTimestamp(entry.timestamp),
                        );
                      },
                    ),
        ),
      ],
    );
  }

  Widget _stateRow(MapEntry<String, String> row) {
    final line = '${row.key}: ${row.value}';
    return SelectableText(
      line,
      style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
    );
  }
}
