import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/widgets/confirm_dialog.dart';
import 'package:webspace/widgets/toast.dart';

/// A text button in the action row above a Developer Tools list.
Widget toolButton(
  IconData icon, {
  required String label,
  required VoidCallback? onPressed,
  Key? key,
}) => TextButton.icon(
  key: key,
  onPressed: onPressed,
  icon: Icon(icon, size: 18),
  label: Text(label),
);

/// The action row above a Developer Tools list. [wrap] lets the buttons run
/// onto a second line instead of overflowing.
class ToolActions extends StatelessWidget {
  const ToolActions(this.buttons, {super.key, this.wrap = false});

  final List<Widget> buttons;
  final bool wrap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
    child: wrap ? Wrap(spacing: 4, children: buttons) : Row(children: buttons),
  );
}

/// The switch that shows a log's sensitive entries: consent to display them
/// only, and reset with the process.
class SensitiveSwitch extends StatelessWidget {
  const SensitiveSwitch({
    super.key,
    this.switchKey,
    required this.value,
    required this.onChanged,
    required this.label,
  });

  final Key? switchKey;
  final bool value;
  final ValueChanged<bool> onChanged;
  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12.0),
    child: Row(
      children: [
        Switch(key: switchKey, value: value, onChanged: onChanged),
        const SizedBox(width: 4),
        Expanded(
          child: Text(label, style: Theme.of(context).textTheme.bodySmall),
        ),
      ],
    ),
  );
}

/// A log's lines, newest at the bottom where the view opens; while a search
/// is on, newest at the top. [empty] is what the log says with no lines.
///
/// At the bottom it follows the log as lines arrive. Scrolled up, it holds
/// the lines it showed when the reader left the bottom, so a line arriving
/// moves nothing they are reading; back at the bottom it shows the log as it
/// stands and follows it again (DEVTOOLS-004).
class LogLines<T> extends StatefulWidget {
  const LogLines({
    super.key,
    required this.lines,
    required this.searching,
    required this.empty,
    required this.line,
    this.controller,
  });

  final List<T> lines;
  final bool searching;
  final String empty;
  final Widget Function(T) line;
  final ScrollController? controller;

  @override
  State<LogLines<T>> createState() => _LogLinesState<T>();
}

class _LogLinesState<T> extends State<LogLines<T>> {
  ScrollController? _own;
  ScrollController get _scroll => widget.controller ?? (_own ??= ScrollController());

  /// What the view showed when the reader scrolled away from the bottom;
  /// null while it follows the log.
  List<T>? _held;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(LogLines<T> old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      (old.controller ?? _own)?.removeListener(_onScroll);
      _scroll.addListener(_onScroll);
    }
    if (widget.searching) _held = null;
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _own?.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (widget.searching || !_scroll.hasClients) return;
    final away = _scroll.offset > 0;
    if (away && _held == null) {
      _held = List.of(widget.lines);
    } else if (!away && _held != null) {
      setState(() => _held = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final lines = widget.searching ? widget.lines : (_held ?? widget.lines);
    return lines.isEmpty
        ? Center(
            child: Text(
              widget.searching
                  ? AppLocalizations.of(context).devToolsNoMatches
                  : widget.empty,
            ),
          )
        : ListView.builder(
            controller: _scroll,
            reverse: !widget.searching,
            itemCount: lines.length,
            itemBuilder: (context, index) =>
                widget.line(lines[lines.length - 1 - index]),
          );
  }
}

/// Copies [entries] as [format] renders them. Sensitive entries reach the
/// clipboard only through a confirmation saying how many there are
/// ([consent]): the show-sensitive switch is consent to display them, not to
/// hand them to clipboard history, a cloud clipboard or a third-party
/// keyboard. Files written by Export never carry them at all.
Future<void> copyLogs(
  BuildContext context, {
  required List<LogEntry> entries,
  required Localized Function(int sensitive) consent,
  required String Function({required bool includeSensitive}) format,
}) async {
  final loc = AppLocalizations.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final sensitive = entries
      .where((e) => e.sensitivity == LogSensitivity.sensitive)
      .length;
  if (sensitive > 0 &&
      !await confirm(
        context,
        title: loc.devToolsLogsCopySensitiveTitle,
        body: consent(sensitive),
        confirmLabel: loc.devToolsCopy,
        destructive: false,
      )) {
    return;
  }
  if (!context.mounted) return;
  await Clipboard.setData(
      ClipboardData(text: format(includeSensitive: sensitive > 0)));
  if (!context.mounted) return;
  messenger.toast(loc.devToolsLogsCopied(entries.length));
}
