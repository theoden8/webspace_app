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
}
