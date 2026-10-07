import 'dart:async';

import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/services/background_log.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/reentry_guard.dart';
import 'package:webspace/widgets/dev_tools_parts.dart';
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
  final _copyGuard = ReentryGuard();
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
    return _entries
        .where(
          (e) =>
              e.message.toLowerCase().contains(q) ||
              e.tag.toLowerCase().contains(q),
        )
        .toList();
  }

  Future<void> _copy(List<LogEntry> visible) => _copyGuard.run(
    () => copyLogs(
      context,
      visible,
      consent: AppLocalizations.of(context).devToolsBackgroundCopySensitiveBody,
      format: (includeSensitive) => BackgroundLog.format(
        visible,
        includeSensitive: includeSensitive,
        state: _state,
      ),
    ),
  );

  Future<void> _export() async {
    final entries = await _log.entries(includeSensitive: false);
    final state = await _log.systemState();
    if (!mounted) return;
    await saveLogText(
      context,
      BackgroundLog.format(entries, state: state),
      fileNamePrefix: 'webspace_background_log',
    );
  }

  Future<void> _clear() async {
    await _log.clear();
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final visible = _visible;
    return LayoutBuilder(
      builder: (context, constraints) => Column(
        children: [
          // The controls and the system state share at most this much of
          // the tab and scroll inside it: on a short or landscape screen
          // they would otherwise leave the log no height at all.
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: constraints.maxHeight * 0.45,
            ),
            child: SingleChildScrollView(
              child: Column(
                children: [
                  ToolActions(wrap: true, [
                    toolButton(
                      Icons.refresh,
                      loc.devToolsRefresh,
                      () => _load(withState: true),
                      key: const Key('background-log-refresh'),
                    ),
                    toolButton(
                      Icons.save,
                      loc.devToolsExport,
                      _entries.isEmpty ? null : _export,
                    ),
                    toolButton(
                      Icons.copy,
                      loc.devToolsCopy,
                      visible.isEmpty ? null : () => _copy(visible),
                      key: const Key('background-log-copy'),
                    ),
                    toolButton(
                      Icons.delete_outline,
                      loc.devToolsClear,
                      _entries.isEmpty ? null : _clear,
                    ),
                  ]),
                  SensitiveSwitch(
                    switchKey: const Key('background-log-sensitive'),
                    value: _showSensitive,
                    onChanged: (v) {
                      setState(() => _showSensitive = v);
                      unawaited(_load());
                    },
                    label: _showSensitive
                        ? loc.devToolsBackgroundSensitiveShowing
                        : loc.devToolsBackgroundSensitiveShow,
                  ),
                  if (_state.isNotEmpty)
                    ExpansionTile(
                      title: Text(loc.devToolsBackgroundSystemState),
                      initiallyExpanded: true,
                      dense: true,
                      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      expandedCrossAxisAlignment: CrossAxisAlignment.start,
                      children: [for (final row in _state) _stateRow(row)],
                    ),
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: !_loaded
                ? const Center(child: CircularProgressIndicator())
                : LogLines(
                    lines: visible,
                    searching: widget.searchQuery.isNotEmpty,
                    empty: loc.devToolsBackgroundEmpty,
                    line: (entry) => LogEntryLine(
                      entry: entry,
                      time: BackgroundLog.formatShortTimestamp(entry.timestamp),
                    ),
                  ),
          ),
        ],
      ),
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
