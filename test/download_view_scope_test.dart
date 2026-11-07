import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/download_manager.dart';
import 'package:webspace/services/view_key.dart';

import 'helpers/fake_platform_controller.dart';

// A page reports a blob download's progress and completion by handing its task
// id back through the bridge. The handlers run in every frame of every view, so
// without a check a frame could report on another view's download. A task is
// bound to the view that started it, and DownloadsService.pageTask answers a
// page's report only for that view's own tasks (policy R4, DL-008). The compile
// probe (test/policy_probe_test.dart) proves a handler cannot forge an id; this
// boundary test proves pageTask actually checks the view, by running the same
// check against a token-only lookup (the planted mistake) and showing it fails.

inapp.InAppWebViewController _wrapper(inapp.PlatformInAppWebViewController view) =>
    inapp.InAppWebViewController.fromPlatform(platform: view);

typedef Lookup = DownloadTaskId? Function(String token, {required ViewKey view});

void main() {
  final viewA = ViewKey.of(_wrapper(FakePlatformController()));
  final viewB = ViewKey.of(_wrapper(FakePlatformController()));
  final downloads = DownloadsService.instance;

  tearDown(() {
    for (final t in downloads.tasks.toList()) {
      downloads.dismiss(t.id);
    }
  });

  // The property under test: a lookup hands a view its own task's id and hands
  // another view nothing for that same token. pageTask must satisfy it; a
  // lookup that ignores the view must not.
  void expectViewScoped(Lookup lookup) {
    final task = downloads.start(filename: 'a.bin', view: viewA);
    expect(lookup(task.id.token, view: viewA), task.id,
        reason: "the starting view gets its own task");
    expect(lookup(task.id.token, view: viewB), isNull,
        reason: "another view gets nothing for the same token");
  }

  test('DL-008: pageTask is view-scoped', () {
    expectViewScoped(
        (token, {required view}) => downloads.pageTask(token, view: view));
  });

  test('DL-008: a token-only lookup (the planted mistake) fails the check', () {
    // The mistake: match on the token and ignore the view. Run the very check
    // pageTask passes; it must fail here, or the check proves nothing.
    DownloadTaskId? tokenOnly(String token, {required ViewKey view}) =>
        downloads.tasks.where((t) => t.id.token == token).firstOrNull?.id;
    expect(() => expectViewScoped(tokenOnly), throwsA(isA<TestFailure>()));
  });

  test('DL-008: another view cannot change a download it did not start', () {
    final task = downloads.start(filename: 'a.bin', view: viewA);
    // A handler on B guards on a null id, so it never reaches a mutation.
    final fromB = downloads.pageTask(task.id.token, view: viewB);
    if (fromB != null) downloads.fail(fromB, message: 'from B');
    expect(task.state, DownloadState.downloading,
        reason: "view B could not fail, complete or advance view A's task");
  });

  test('an app-driven download is reportable by no page', () {
    final task = downloads.start(filename: 'http.bin'); // view: null
    expect(downloads.pageTask(task.id.token, view: viewA), isNull);
  });

  test('an id no task was started for resolves to nothing', () {
    expect(downloads.pageTask('dl-999-0123456789abcdef', view: viewA), isNull);
  });
}
