import 'package:flutter/material.dart';
import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/services/download_manager.dart';

/// AppBar action that surfaces active downloads. Renders nothing when the
/// queue is empty. While any task is downloading, shows a spinning progress
/// ring (determinate if Content-Length is known). Tapping opens a bottom
/// sheet with per-task progress + errors.
class DownloadButton extends StatelessWidget {
  const DownloadButton({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: DownloadsService.instance,
      builder: (context, _) {
        final loc = AppLocalizations.of(context);
        final tasks = DownloadsService.instance.tasks;
        if (tasks.isEmpty) return const SizedBox.shrink();

        final active = tasks.where((t) => t.isActive).toList();
        final aggregate = DownloadAggregateProgress.from(tasks);

        final iconColor = IconTheme.of(context).color;
        // Tooltip reports bytes-received even when the ring is
        // indeterminate so the user can tell progress is happening when
        // the server didn't send Content-Length.
        final tooltip = () {
          if (active.isEmpty) return loc.downloadButtonRecentTooltip(tasks.length);
          final doneBytes = active.fold<int>(0, (a, t) => a + t.bytesDone);
          final doneStr = _DownloadTile._formatBytes(doneBytes);
          if (aggregate.value != null) {
            final pct = (aggregate.value! * 100).toStringAsFixed(0);
            return loc.downloadButtonActiveProgressTooltip(active.length, pct, doneStr);
          }
          return loc.downloadButtonActiveReceivedTooltip(active.length, doneStr);
        }();
        return Tooltip(
          message: tooltip,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: () => showModalBottomSheet<void>(
              context: context,
              showDragHandle: true,
              builder: (_) => const _DownloadsSheet(),
            ),
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: SizedBox(
                width: 28,
                height: 28,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    if (aggregate.hasActive)
                      SizedBox(
                        width: 28,
                        height: 28,
                        child: CircularProgressIndicator(
                          value: aggregate.value,
                          strokeWidth: 2.5,
                          color: iconColor,
                        ),
                      ),
                    Icon(
                      active.isEmpty
                          ? Icons.download_done
                          : Icons.download,
                      size: 16,
                      color: iconColor,
                    ),
                    if (active.length > 1)
                      Positioned(
                        right: -4,
                        top: -4,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 1),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.primary,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            active.length.toString(),
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.onPrimary,
                              fontSize: 9,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

}

class _DownloadsSheet extends StatelessWidget {
  const _DownloadsSheet();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: DownloadsService.instance,
      builder: (context, _) {
        final loc = AppLocalizations.of(context);
        final tasks = DownloadsService.instance.tasks;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
                child: Row(
                  children: [
                    Text(loc.downloadButtonSheetTitle,
                        style: Theme.of(context).textTheme.titleLarge),
                    const Spacer(),
                    if (tasks.any((t) => !t.isActive))
                      TextButton(
                        onPressed: DownloadsService.instance.clearCompleted,
                        child: Text(loc.downloadButtonClearFinished),
                      ),
                  ],
                ),
              ),
              if (tasks.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(loc.downloadButtonEmpty),
                )
              else
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: tasks.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (_, i) => _DownloadTile(task: tasks[i]),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _DownloadTile extends StatelessWidget {
  final DownloadTask task;
  const _DownloadTile({required this.task});

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final savedPath = task.savedPath;
    final scheme = Theme.of(context).colorScheme;
    final (IconData icon, String subtitle, Color? color) = switch (task.state) {
      DownloadState.downloading =>
        (Icons.downloading, _progressSubtitle(loc, task), null),
      DownloadState.completed => (
          Icons.check_circle,
          savedPath == null
              ? loc.downloadButtonSaved
              : loc.downloadButtonSavedToPath(savedPath),
          scheme.primary,
        ),
      DownloadState.failed => (
          Icons.error_outline,
          task.errorMessage ?? loc.downloadButtonFailed,
          scheme.error,
        ),
      DownloadState.cancelled => (
          Icons.cancel_outlined,
          loc.downloadButtonCancelled,
          scheme.onSurface.withValues(alpha: 0.6),
        ),
    };

    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(task.filename, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(subtitle, style: TextStyle(color: color)),
          if (task.isActive) ...[
            const SizedBox(height: 4),
            LinearProgressIndicator(value: task.progress),
          ],
        ],
      ),
      trailing: task.isActive
          ? null
          : IconButton(
              icon: const Icon(Icons.close, size: 18),
              tooltip: loc.downloadButtonDismiss,
              onPressed: () => DownloadsService.instance.dismiss(task.id),
            ),
    );
  }

  static String _progressSubtitle(AppLocalizations loc, DownloadTask t) {
    final done = _formatBytes(t.bytesDone);
    final total = t.bytesTotal;
    if (total == null || total <= 0) return loc.downloadButtonBytesReceived(done);
    return '$done / ${_formatBytes(total)}';
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }
}
