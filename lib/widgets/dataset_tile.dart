import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/theme/design_tokens.dart';
import 'package:webspace/widgets/root_messenger.dart';
import 'package:webspace/widgets/setting_tile.dart';

/// Data the app fetches only when the user asks: a blocklist, a rule set, a
/// polygon file. One [DatasetTile] renders any of them.
abstract interface class DownloadableDataset implements Listenable {
  /// Whether a download would refresh what is there rather than fetch it.
  bool get ready;

  /// When the data on disk was fetched; null hides the row's date.
  DateTime? get lastUpdated;

  /// The row's first line: what the data holds, or that there is none.
  String? status(AppLocalizations loc);

  /// Fetches or refreshes the data. The result is the SnackBar's text.
  Future<String> download(AppLocalizations loc);

  void dispose();
}

/// A dataset the row can also delete.
abstract interface class ClearableDataset implements DownloadableDataset {
  /// The SnackBar's text, or null for none.
  Future<String?> clear(AppLocalizations loc);
}

/// `2025-01-31 14:05:09`, in local time.
String formatTimestamp(DateTime when) =>
    when.toLocal().toString().split('.').first;

/// `950`, `1K`, `297.8K`.
String compactCount(int n) => n >= 1000
    ? '${(n / 1000).toStringAsFixed(n % 1000 == 0 ? 0 : 1)}K'
    : '$n';

/// The App Settings row for one [DownloadableDataset]: what is on disk, when
/// it was fetched, and the buttons to fetch, refresh or delete it.
class DatasetTile<D extends DownloadableDataset> extends StatefulWidget {
  const DatasetTile({
    super.key,
    required this.create,
    required this.icon,
    required this.title,
    required this.hint,
    this.below,
  });

  /// Called once; the tile disposes what it returns.
  final D Function() create;
  final IconData icon;
  final String title;
  final String hint;

  /// Controls under the row. `download` is null while one is running.
  final Widget Function(D dataset, VoidCallback? download)? below;

  @override
  State<DatasetTile<D>> createState() => _DatasetTileState<D>();
}

class _DatasetTileState<D extends DownloadableDataset>
    extends State<DatasetTile<D>> {
  late final D _dataset = widget.create()..addListener(_changed);
  bool _busy = false;

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _dataset.removeListener(_changed);
    _dataset.dispose();
    super.dispose();
  }

  Future<void> _run(Future<String?> Function(AppLocalizations) action) async {
    if (_busy) return;
    final loc = AppLocalizations.of(context);
    final messenger =
        rootScaffoldMessengerKey.currentState ?? ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    final message = await action(loc);
    if (mounted) setState(() => _busy = false);
    if (message != null) {
      messenger.showSnackBar(SnackBar(content: Text(message)));
    }
  }

  void _download() => _run(_dataset.download);

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final ready = _dataset.ready;
    final status = _dataset.status(loc);
    final updated = _dataset.lastUpdated;
    final dataset = _dataset;
    final row = ListTile(
      leading: Icon(widget.icon),
      title: HintedTitle(widget.title, hint: widget.hint),
      subtitle: status == null && updated == null
          ? null
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (status != null) Text(status),
                if (updated != null)
                  Text(loc.appSettingsUpdatedAt(formatTimestamp(updated)),
                      style: const TextStyle(fontSize: 12)),
              ],
            ),
      trailing: _busy
          ? const SizedBox.square(
              dimension: IconSizes.floating,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (dataset is ClearableDataset && ready)
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: loc.appSettingsClearDataset,
                    onPressed: () => _run(dataset.clear),
                  ),
                IconButton(
                  icon: Icon(ready ? Icons.sync : Icons.download),
                  tooltip: ready
                      ? loc.appSettingsRefreshDataset
                      : loc.appSettingsDownloadDataset,
                  onPressed: _download,
                ),
              ],
            ),
    );
    final below = widget.below;
    if (below == null) return row;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [row, below(_dataset, _busy ? null : _download)],
    );
  }
}
