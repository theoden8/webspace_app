import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/download_manager.dart';

void main() {
  setUp(() => DownloadsService.instance.resetForTest());

  test('start appends a task at the front, isActive', () {
    final s = DownloadsService.instance;
    expect(s.tasks, isEmpty);
    final t1 = s.start(filename: 'a.pdf');
    final t2 = s.start(filename: 'b.pdf');
    expect(s.tasks.first.id, t2.id);
    expect(s.tasks.last.id, t1.id);
    expect(s.hasActive, isTrue);
    expect(s.activeCount, 2);
  });

  test('updateProgress mutates task and notifies listeners', () {
    final s = DownloadsService.instance;
    var notifyCount = 0;
    s.addListener(() => notifyCount++);

    final t = s.start(filename: 'x', bytesTotal: 1000);
    final n0 = notifyCount;

    s.updateProgress(t.id, bytesDone: 500);
    expect(t.bytesDone, 500);
    expect(t.progress, closeTo(0.5, 1e-9));
    expect(notifyCount, n0 + 1);
  });

  test('complete flips state and sets savedPath', () {
    final s = DownloadsService.instance;
    final t = s.start(filename: 'x');
    s.complete(t.id, savedPath: '/tmp/x');
    expect(t.state, DownloadState.completed);
    expect(t.savedPath, '/tmp/x');
    expect(t.isActive, isFalse);
    expect(s.hasActive, isFalse);
  });

  test('fail sets error message, not active', () {
    final s = DownloadsService.instance;
    final t = s.start(filename: 'x');
    s.fail(t.id, 'HTTP 500');
    expect(t.state, DownloadState.failed);
    expect(t.errorMessage, 'HTTP 500');
  });

  test('cancel flips state', () {
    final s = DownloadsService.instance;
    final t = s.start(filename: 'x');
    s.cancel(t.id);
    expect(t.state, DownloadState.cancelled);
    expect(t.isActive, isFalse);
  });

  test('dismiss removes the task', () {
    final s = DownloadsService.instance;
    final a = s.start(filename: 'a');
    final b = s.start(filename: 'b');
    s.complete(b.id);
    s.dismiss(b.id);
    expect(s.tasks, hasLength(1));
    expect(s.tasks.first.id, a.id);
  });

  test('clearCompleted keeps active tasks', () {
    final s = DownloadsService.instance;
    final a = s.start(filename: 'a');
    final b = s.start(filename: 'b');
    s.complete(b.id);
    s.clearCompleted();
    expect(s.tasks, hasLength(1));
    expect(s.tasks.first.id, a.id);
  });

  test('progress is null when total is unknown or zero', () {
    final s = DownloadsService.instance;
    final t = s.start(filename: 'x');
    expect(t.progress, isNull);
    s.updateProgress(t.id, bytesTotal: 0, bytesDone: 10);
    expect(t.progress, isNull);
  });

  test('unknown id is a no-op', () {
    final s = DownloadsService.instance;
    s.updateProgress('missing', bytesDone: 100);
    s.complete('missing');
    s.fail('missing', 'err');
    s.cancel('missing');
    s.dismiss('missing');
    expect(s.tasks, isEmpty);
  });

  group('DownloadAggregateProgress.from', () {
    test('no tasks → no active, null ring', () {
      final agg = DownloadAggregateProgress.from(const []);
      expect(agg.hasActive, isFalse);
      expect(agg.value, isNull);
    });

    test('only finished tasks → no active', () {
      final s = DownloadsService.instance;
      final t = s.start(filename: 'a', bytesTotal: 100);
      s.complete(t.id);
      final agg = DownloadAggregateProgress.from(s.tasks);
      expect(agg.hasActive, isFalse);
      expect(agg.value, isNull);
    });

    test('single active task with known total → determinate', () {
      final s = DownloadsService.instance;
      final t = s.start(filename: 'a', bytesTotal: 1000);
      s.updateProgress(t.id, bytesDone: 250);
      final agg = DownloadAggregateProgress.from(s.tasks);
      expect(agg.hasActive, isTrue);
      expect(agg.value, closeTo(0.25, 1e-9));
    });

    test('single active task with null total → indeterminate', () {
      final s = DownloadsService.instance;
      s.start(filename: 'a');
      final agg = DownloadAggregateProgress.from(s.tasks);
      expect(agg.hasActive, isTrue);
      expect(agg.value, isNull);
    });

    test('single active task with zero total → indeterminate', () {
      final s = DownloadsService.instance;
      final t = s.start(filename: 'a', bytesTotal: 1000);
      s.updateProgress(t.id, bytesTotal: 0);
      final agg = DownloadAggregateProgress.from(s.tasks);
      expect(agg.hasActive, isTrue);
      expect(agg.value, isNull);
    });

    test('multiple active tasks, all known → weighted aggregate', () {
      final s = DownloadsService.instance;
      final a = s.start(filename: 'a', bytesTotal: 1000);
      final b = s.start(filename: 'b', bytesTotal: 3000);
      s.updateProgress(a.id, bytesDone: 1000); // done
      s.updateProgress(b.id, bytesDone: 500); // 1/6 of total
      final agg = DownloadAggregateProgress.from(s.tasks);
      expect(agg.hasActive, isTrue);
      // (1000 + 500) / 4000 = 0.375
      expect(agg.value, closeTo(0.375, 1e-9));
    });

    test('one active unknown poisons aggregate → indeterminate', () {
      final s = DownloadsService.instance;
      final a = s.start(filename: 'a', bytesTotal: 1000);
      s.start(filename: 'b'); // unknown total
      s.updateProgress(a.id, bytesDone: 500);
      final agg = DownloadAggregateProgress.from(s.tasks);
      expect(agg.hasActive, isTrue);
      expect(agg.value, isNull);
    });

    test('finished tasks do not affect aggregate', () {
      final s = DownloadsService.instance;
      final a = s.start(filename: 'a', bytesTotal: 1000);
      final b = s.start(filename: 'b', bytesTotal: 1000);
      s.updateProgress(a.id, bytesDone: 500);
      s.complete(b.id); // Finished; shouldn't enter the aggregate.
      final agg = DownloadAggregateProgress.from(s.tasks);
      expect(agg.hasActive, isTrue);
      expect(agg.value, closeTo(0.5, 1e-9));
    });
  });

  group('http download lifecycle replay', () {
    // Reproduces the sequence a real HTTP download produces so we spot
    // any regression where bytesTotal ends up null or the task stays
    // stuck in "downloading" state after fetch returns.
    test('task starts indeterminate then goes determinate on first progress',
        () {
      final s = DownloadsService.instance;
      // 1. Task starts without a known total (DownloadStartRequest
      //    contentLength was 0).
      final task = s.start(filename: 'file.pdf', bytesTotal: null);
      var agg = DownloadAggregateProgress.from(s.tasks);
      expect(agg.value, isNull,
          reason: 'no total known yet → indeterminate');
      expect(agg.hasActive, isTrue);

      // 2. Engine fires first progress with response.contentLength.
      s.updateProgress(task.id, bytesDone: 0, bytesTotal: 10000);
      agg = DownloadAggregateProgress.from(s.tasks);
      expect(agg.value, 0.0, reason: 'total known, nothing done yet');

      // 3. Chunks stream in.
      s.updateProgress(task.id, bytesDone: 2500, bytesTotal: 10000);
      expect(DownloadAggregateProgress.from(s.tasks).value,
          closeTo(0.25, 1e-9));
      s.updateProgress(task.id, bytesDone: 10000, bytesTotal: 10000);
      expect(DownloadAggregateProgress.from(s.tasks).value, 1.0);

      // 4. Save completes.
      s.complete(task.id, savedPath: '/tmp/file.pdf');
      agg = DownloadAggregateProgress.from(s.tasks);
      expect(agg.hasActive, isFalse);
      expect(agg.value, isNull);
      expect(task.state, DownloadState.completed);
    });

    test('null total from engine (chunked transfer) stays indeterminate '
        'without clobbering a known total', () {
      final s = DownloadsService.instance;
      final task = s.start(filename: 'f', bytesTotal: 1024);
      expect(task.bytesTotal, 1024);
      // Engine's onProgress for a chunked-transfer response: total is null.
      s.updateProgress(task.id, bytesDone: 256, bytesTotal: null);
      // bytesTotal should NOT have been overwritten to null.
      expect(task.bytesTotal, 1024);
      final agg = DownloadAggregateProgress.from(s.tasks);
      expect(agg.value, closeTo(0.25, 1e-9));
    });
  });
}
