import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/download_manager.dart';
import 'package:webspace/services/view_key.dart';

import 'helpers/fake_platform_controller.dart';

// A page reports a blob download's progress and completion by handing its task
// id back through the bridge. The handlers run in every frame of every view, so
// without a check a frame could report on another view's download. A task is
// bound to the view that started it, and DownloadsService.pageTask answers a
// page's report only for that view's own tasks (policy R4, DL-008). The
// compile probe (test/policy_probe_test.dart) proves a handler cannot forge an
// id; this boundary test proves pageTask actually checks the view, which a
// token-only lookup (the planted mistake below) would not.

inapp.InAppWebViewController _wrapper(inapp.PlatformInAppWebViewController view) =>
    inapp.InAppWebViewController.fromPlatform(platform: view);

void main() {
  final viewA = ViewKey.of(_wrapper(FakePlatformController()));
  final viewB = ViewKey.of(_wrapper(FakePlatformController()));
  final downloads = DownloadsService.instance;

  tearDown(() {
    for (final t in downloads.tasks.toList()) {
      downloads.dismiss(t.id);
    }
  });

  test('a view may report on a download it started', () {
    final task = downloads.start(filename: 'a.bin', view: viewA);
    expect(downloads.pageTask(task.id.token, view: viewA), task.id);
  });

  test('DL-008: another view cannot reach, nor change, a download it did not '
      'start', () {
    final task = downloads.start(filename: 'a.bin', view: viewA);
    expect(downloads.pageTask(task.id.token, view: viewB), isNull,
        reason: "view B gets no id for view A's task");
    // So a handler on B, which guards on a null id, changes nothing of A's.
    final fromB = downloads.pageTask(task.id.token, view: viewB);
    if (fromB != null) downloads.fail(fromB, message: 'from B');
    expect(task.state, DownloadState.downloading,
        reason: "view B could not fail, complete or advance view A's task");
  });

  test('DL-008: the planted token-only lookup is caught here', () {
    final task = downloads.start(filename: 'a.bin', view: viewA);
    // The mistake: matching on the token alone, ignoring the view. It would
    // hand view B view A's task, which every probe would still pass.
    final tokenOnly = downloads.tasks
        .where((t) => t.id.token == task.id.token)
        .firstOrNull
        ?.id;
    expect(tokenOnly, task.id,
        reason: 'a token-only lookup WOULD match for any view');
    // The real, view-checked pageTask does not, so this test fails if pageTask
    // ever drops its view check.
    expect(downloads.pageTask(task.id.token, view: viewB), isNull);
  });

  test('an app-driven download is reportable by no page', () {
    final task = downloads.start(filename: 'http.bin'); // view: null
    expect(downloads.pageTask(task.id.token, view: viewA), isNull);
  });

  test('an id no task was started for resolves to nothing', () {
    expect(downloads.pageTask('dl-999-0123456789abcdef', view: viewA), isNull);
  });
}
