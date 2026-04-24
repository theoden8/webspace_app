import 'package:flutter/foundation.dart';

enum DownloadState { downloading, completed, failed, cancelled }

class DownloadTask {
  final String id;
  final String? url;
  String filename;
  int bytesDone;
  int? bytesTotal;
  DownloadState state;
  String? errorMessage;
  String? savedPath;
  final DateTime startedAt;

  DownloadTask({
    required this.id,
    required this.filename,
    this.url,
    this.bytesDone = 0,
    this.bytesTotal,
    this.state = DownloadState.downloading,
    this.errorMessage,
    this.savedPath,
    DateTime? startedAt,
  }) : startedAt = startedAt ?? DateTime.now();

  /// 0.0–1.0 if [bytesTotal] is known, otherwise null (caller should render
  /// an indeterminate indicator).
  double? get progress {
    final total = bytesTotal;
    if (total == null || total <= 0) return null;
    return (bytesDone / total).clamp(0.0, 1.0);
  }

  bool get isActive => state == DownloadState.downloading;
}

/// Tracks in-flight and recently-completed downloads for the app-bar
/// progress button. Pure `ChangeNotifier` — no Flutter widgets, so it can
/// be driven from any callback layer (webview handlers, blob JS handler,
/// data-URI decode, etc.).
class DownloadsService extends ChangeNotifier {
  DownloadsService._();
  static final DownloadsService instance = DownloadsService._();

  final List<DownloadTask> _tasks = [];
  int _counter = 0;

  List<DownloadTask> get tasks => List.unmodifiable(_tasks);
  bool get hasActive => _tasks.any((t) => t.isActive);
  int get activeCount => _tasks.where((t) => t.isActive).length;

  /// Creates and registers a new task. Returns the task so the caller can
  /// mutate it directly; after any mutation call [emit] to notify
  /// listeners.
  DownloadTask start({
    required String filename,
    String? url,
    int? bytesTotal,
  }) {
    final task = DownloadTask(
      id: 'dl-${++_counter}',
      filename: filename,
      url: url,
      bytesTotal: bytesTotal,
    );
    _tasks.insert(0, task);
    notifyListeners();
    return task;
  }

  /// Updates progress fields on an already-started task and notifies.
  /// Silent if the id is unknown (task may have been cleared from history).
  void updateProgress(String id, {int? bytesDone, int? bytesTotal}) {
    final task = _tasks.where((t) => t.id == id).firstOrNull;
    if (task == null) return;
    if (bytesDone != null) task.bytesDone = bytesDone;
    if (bytesTotal != null) task.bytesTotal = bytesTotal;
    notifyListeners();
  }

  void complete(String id, {String? savedPath}) {
    final task = _tasks.where((t) => t.id == id).firstOrNull;
    if (task == null) return;
    task.state = DownloadState.completed;
    task.savedPath = savedPath;
    task.bytesTotal ??= task.bytesDone;
    notifyListeners();
  }

  void fail(String id, String message) {
    final task = _tasks.where((t) => t.id == id).firstOrNull;
    if (task == null) return;
    task.state = DownloadState.failed;
    task.errorMessage = message;
    notifyListeners();
  }

  void cancel(String id) {
    final task = _tasks.where((t) => t.id == id).firstOrNull;
    if (task == null) return;
    task.state = DownloadState.cancelled;
    notifyListeners();
  }

  /// Remove a single finished/failed/cancelled task.
  void dismiss(String id) {
    _tasks.removeWhere((t) => t.id == id);
    notifyListeners();
  }

  /// Remove all non-active tasks.
  void clearCompleted() {
    _tasks.removeWhere((t) => !t.isActive);
    notifyListeners();
  }

  @visibleForTesting
  void resetForTest() {
    _tasks.clear();
    _counter = 0;
    notifyListeners();
  }
}

/// Pure helper for the app-bar progress ring. Given the list of tasks
/// currently surfaced by [DownloadsService], computes what the ring
/// should display.
///
/// Extracted so it's unit-testable without mounting a widget.
class DownloadAggregateProgress {
  /// Resulting ring value — null means "render indeterminate".
  final double? value;

  /// Whether anything is currently in flight. When false, the caller
  /// should render the "download done" glyph without a ring.
  final bool hasActive;

  const DownloadAggregateProgress({
    required this.value,
    required this.hasActive,
  });

  /// Aggregate across all active tasks: [value] is done/total if every
  /// active task has a positive known total; otherwise null so the ring
  /// falls back to an indeterminate spin. Completed/failed/cancelled
  /// tasks don't contribute.
  static DownloadAggregateProgress from(Iterable<DownloadTask> tasks) {
    final active = tasks.where((t) => t.isActive).toList(growable: false);
    if (active.isEmpty) {
      return const DownloadAggregateProgress(value: null, hasActive: false);
    }
    if (!active.every((t) => (t.bytesTotal ?? 0) > 0)) {
      return const DownloadAggregateProgress(value: null, hasActive: true);
    }
    final total = active.fold<int>(0, (a, t) => a + t.bytesTotal!);
    if (total <= 0) {
      return const DownloadAggregateProgress(value: null, hasActive: true);
    }
    final done = active.fold<int>(0, (a, t) => a + t.bytesDone);
    return DownloadAggregateProgress(
      value: (done / total).clamp(0.0, 1.0),
      hasActive: true,
    );
  }
}
