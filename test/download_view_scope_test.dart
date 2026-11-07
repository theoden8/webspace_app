import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/download_manager.dart';
import 'package:webspace/services/view_key.dart';

import 'helpers/fake_platform_controller.dart';

// A page reports a blob download's progress and completion by handing its task
// id back through the bridge. The handlers run in every frame of every view, so
// without a check a frame could report on another view's download. A task is
// bound to the view that started it, and DownloadsService.pageTask answers a
// page's report only for that view's own tasks (policy R4).

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
    expect(downloads.pageTask(task.id, view: viewA), task.id);
  });

  test('another view cannot reach a download it did not start', () {
    final task = downloads.start(filename: 'a.bin', view: viewA);
    expect(downloads.pageTask(task.id, view: viewB), isNull,
        reason: "view B cannot fail, complete or advance view A's task");
  });

  test('an app-driven download is reportable by no page', () {
    final task = downloads.start(filename: 'http.bin'); // view: null
    expect(downloads.pageTask(task.id, view: viewA), isNull);
  });

  test('an id no task was started for resolves to nothing', () {
    final forged = DownloadTaskId.parse('dl-999-0123456789abcdef');
    expect(forged, isNotNull);
    expect(downloads.pageTask(forged, view: viewA), isNull);
  });
}
