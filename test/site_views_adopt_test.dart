import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/step_table.dart';
import 'package:webspace/web_view_model_site_views.dart';

import 'helpers/fake_webview_controller.dart';

/// A webview's build can land after its slot was unloaded: the frame that
/// built it unmounts it, but the slot must not take its controller, or it
/// keeps one until its next build and nothing tells it again. It is let go
/// of as a departing view instead, so the site's route waits for its page
/// to go (PROXY-008).
void main() {
  test('a controller built after its slot unloaded is let go of, not shown '
      '(PROXY-008)', () async {
    final views = SiteViews();
    final late = FakeWebViewController()..destroyGate = Completer<void>();

    expect(views.adopt(late, loaded: false), isFalse);
    expect(views.controller, isNull);

    final leaving = views.letGoOfAll(
      shown: null,
      commit: const Commit.fixture(),
    );
    expect(
      leaving,
      same(late),
      reason: 'the late view still sends until its page is gone',
    );
  });

  test('a controller built for a loaded slot is shown', () {
    final views = SiteViews();
    final built = FakeWebViewController();

    expect(views.adopt(built, loaded: true), isTrue);
    expect(views.controller, same(built));
  });
}
