import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:webspace/services/view_key.dart';

/// A download's identity: the [view] that started it (null for an app-driven
/// download the page never reports on) and an unguessable [token]. The page's
/// blob handlers hand the token back, so this is a class, not a string a page
/// can mint into an id: the only id a handler can obtain is one
/// [DownloadsService.pageTask] returns for a token a task was started with for
/// that same view, so a frame cannot name another view's download (policy R4).
/// In memory only; never serialised. The token's 64-bit secure-random suffix
/// also keeps it unguessable, defence in depth behind the view check.
final class DownloadTaskId {
  const DownloadTaskId._({required this.view, required this.token});

  /// The webview the download was started for; null for an app-driven one.
  final ViewKey? view;

  /// The string the page round-trips. Not an id on its own: it names a task
  /// only together with the view, through [DownloadsService.pageTask].
  final String token;

  static final Random _rng = Random.secure();
  static final RegExp _tokenPattern = RegExp(r'^dl-[0-9]+-[0-9a-f]{16}$');

  /// A fresh id for the [serial]th download of this run, started for [view].
  factory DownloadTaskId.mint({required int serial, required ViewKey? view}) {
    final a = _rng.nextInt(1 << 32).toRadixString(16).padLeft(8, '0');
    final b = _rng.nextInt(1 << 32).toRadixString(16).padLeft(8, '0');
    return DownloadTaskId._(view: view, token: 'dl-$serial-$a$b');
  }

  /// Whether [raw] is shaped like a token this run could have minted.
  static bool isToken(Object? raw) =>
      raw is String && _tokenPattern.hasMatch(raw);

  @override
  bool operator ==(Object other) =>
      other is DownloadTaskId && other.view == view && other.token == token;

  @override
  int get hashCode => Object.hash(view, token);

  @override
  String toString() => token;
}

enum DownloadState { downloading, completed, failed, cancelled }

class DownloadTask {
  final DownloadTaskId id;
  final String? url;

  /// The webview that started this download, when a page drives it (a blob
  /// read the page hands back); null for an app-driven download (an HTTP or
  /// data-URI fetch the page never reports on). A page may report progress or
  /// completion only for its own view's tasks (policy R4): [DownloadsService.pageTask].
  final ViewKey? view;
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
    this.view,
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

  /// Creates and registers a new task. Returns the task so the caller can
  /// mutate it directly; after any mutation call [emit] to notify
  /// listeners.
  DownloadTask start({
    required String filename,
    String? url,
    int? bytesTotal,
    ViewKey? view,
  }) {
    final task = DownloadTask(
      id: DownloadTaskId.mint(serial: ++_counter, view: view),
      filename: filename,
      url: url,
      view: view,
      bytesTotal: bytesTotal,
    );
    _tasks.insert(0, task);
    notifyListeners();
    return task;
  }

  /// The id of a download a page reported on by its [rawToken], but only when a
  /// task with that token was started for [view]: a page may report progress,
  /// completion or failure for its own view's downloads, never another view's
  /// (policy R4). Null for a malformed or forged token, or one belonging to
  /// another view or to an app-driven download. This is the only page-reachable
  /// way to obtain a [DownloadTaskId], so a handler cannot name a task the
  /// calling view did not start.
  DownloadTaskId? pageTask(Object? rawToken, {required ViewKey view}) {
    if (!DownloadTaskId.isToken(rawToken)) return null;
    return _tasks
        .where((t) => t.id.token == rawToken && t.id.view == view)
        .firstOrNull
        ?.id;
  }

  /// Updates progress fields on an already-started task and notifies.
  /// Silent if the id is unknown (task may have been cleared from history).
  void updateProgress(DownloadTaskId id, {int? bytesDone, int? bytesTotal}) {
    final task = _tasks.where((t) => t.id == id).firstOrNull;
    if (task == null) return;
    if (bytesDone != null) task.bytesDone = bytesDone;
    if (bytesTotal != null) task.bytesTotal = bytesTotal;
    notifyListeners();
  }

  void complete(DownloadTaskId id, {String? savedPath}) {
    final task = _tasks.where((t) => t.id == id).firstOrNull;
    if (task == null) return;
    task.state = DownloadState.completed;
    task.savedPath = savedPath;
    task.bytesTotal ??= task.bytesDone;
    notifyListeners();
  }

  void fail(DownloadTaskId id, {required String message}) {
    final task = _tasks.where((t) => t.id == id).firstOrNull;
    if (task == null) return;
    task.state = DownloadState.failed;
    task.errorMessage = message;
    notifyListeners();
  }

  void cancel(DownloadTaskId id) {
    final task = _tasks.where((t) => t.id == id).firstOrNull;
    if (task == null) return;
    task.state = DownloadState.cancelled;
    notifyListeners();
  }

  /// Remove a single finished/failed/cancelled task.
  void dismiss(DownloadTaskId id) {
    _tasks.removeWhere((t) => t.id == id);
    notifyListeners();
  }

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
