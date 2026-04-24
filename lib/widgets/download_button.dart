import 'package:flutter/material.dart';
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
        final tasks = DownloadsService.instance.tasks;
        if (tasks.isEmpty) return const SizedBox.shrink();

        final active = tasks.where((t) => t.isActive).toList();
        final aggregate = DownloadAggregateProgress.from(tasks);

        final iconColor = IconTheme.of(context).color;
        // Tooltip reports bytes-received even when the ring is
        // indeterminate so the user can tell progress is happening when
        // the server didn't send Content-Length.
        final tooltip = () {
          if (active.isEmpty) return '${tasks.length} recent downloads';
          final doneBytes = active.fold<int>(0, (a, t) => a + t.bytesDone);
          final doneStr = _DownloadTile._formatBytes(doneBytes);
          if (aggregate.value != null) {
            final pct = (aggregate.value! * 100).toStringAsFixed(0);
            return '${active.length} downloading — $pct% ($doneStr)';
          }
          return '${active.length} downloading — $doneStr received';
        }();
        return Tooltip(
          message: tooltip,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: () => _openSheet(context),
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
                            '${active.length}',
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

  void _openSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => const _DownloadsSheet(),
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
                    Text('Downloads',
                        style: Theme.of(context).textTheme.titleLarge),
                    const Spacer(),
                    if (tasks.any((t) => !t.isActive))
                      TextButton(
                        onPressed: DownloadsService.instance.clearCompleted,
                        child: const Text('Clear finished'),
                      ),
                  ],
                ),
              ),
              if (tasks.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('No downloads'),
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
    final subtitle = switch (task.state) {
      DownloadState.downloading => _progressSubtitle(task),
      DownloadState.completed => 'Saved${task.savedPath == null ? '' : ' • ${task.savedPath}'}',
      DownloadState.failed => task.errorMessage ?? 'Failed',
      DownloadState.cancelled => 'Cancelled',
    };
    final color = switch (task.state) {
      DownloadState.downloading => null,
      DownloadState.completed => Theme.of(context).colorScheme.primary,
      DownloadState.failed => Theme.of(context).colorScheme.error,
      DownloadState.cancelled =>
        Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
    };

    return ListTile(
      leading: Icon(_iconFor(task), color: color),
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
              tooltip: 'Dismiss',
              onPressed: () => DownloadsService.instance.dismiss(task.id),
            ),
    );
  }

  IconData _iconFor(DownloadTask t) => switch (t.state) {
        DownloadState.downloading => Icons.downloading,
        DownloadState.completed => Icons.check_circle,
        DownloadState.failed => Icons.error_outline,
        DownloadState.cancelled => Icons.cancel_outlined,
      };

  static String _progressSubtitle(DownloadTask t) {
    final done = _formatBytes(t.bytesDone);
    final total = t.bytesTotal;
    if (total == null || total <= 0) return '$done received';
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
