import 'dart:async';

import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/media_session_service.dart';
import 'package:webspace/services/page_js.dart';
import 'package:webspace/services/process_route.dart';
import 'package:webspace/services/screen_share.dart';
import 'package:webspace/services/site_tab.dart';
import 'package:webspace/services/step_table.dart';
import 'package:webspace/web_view_model.dart';

/// Ends a page's real camera and microphone capture, as the site leaving
/// the screen does (MIC-014, CAM-005).
const stopCaptureScript =
    "if (typeof globalThis.__wsStopRealCapture === 'function') "
    'globalThis.__wsStopRealCapture();';

/// How a site's webviews come and go: the shown one let go of, kept warm or
/// shown again, and what each move takes with it (TAB-023, TAB-025).
extension WebViewModelViews on WebViewModel {
  /// The webviews and their controllers go, and with them what they held:
  /// the route, once [view] and every warm view are quiet and destroyed (at
  /// once with none to wait for), the tab the shown one was built for, the
  /// resume reload, the site's media session and its screen share.
  void letGoOfViews({required LeavingView? view, required Commit commit}) {
    final leaving = views.letGoOfAll(shown: view, commit: commit);
    unawaited(ProcessRoute.instance.leave(routeClaim.occupant, view: leaving));
    _shownGone(commit: commit);
  }

  /// The view shown now kept live and paused as [tab]'s warm view (TAB-023,
  /// TAB-025): its captures end, and the frame builds the next. It keeps the
  /// site's claim on the route, which it runs on still.
  void keepShownWarm({required TabId tab, required Commit commit}) {
    final shown = views.keepShown(tab: tab, commit: commit);
    if (shown == null) return;
    _shownGone(commit: commit);
    // Before the pause, which on iOS blocks the page's JS thread: only the
    // active tab captures or plays (TAB-025).
    unawaited(shown.evaluateJavascript(stopCaptureScript));
    unawaited(shown.evaluateJavascript(PageJs.mediaPause.script));
    unawaited(shown.pause());
  }

  /// The view shown now let go of while the site's warm views stay: a switch
  /// away from a tab that does not stay warm. With none warm it is
  /// [disposeWebView].
  void dropShown({required Commit commit}) {
    if (!views.dropShown()) {
      disposeWebView(commit: commit);
      return;
    }
    _shownGone(commit: commit);
  }

  /// [tab]'s warm view shown again as it is (TAB-003): no build, no reload.
  void showWarm({required TabId tab, required Commit commit}) {
    final shown = views.show(tab: tab, commit: commit);
    tabBinding.bind(tab, commit: commit);
    unawaited(shown.resume());
  }

  /// [tab]'s warm view let go of: over the limit, closed, or running as
  /// another site than the slot (TAB-023, TAB-026).
  void dropWarm({required TabId tab, required Commit commit}) =>
      views.drop(tab: tab, commit: commit);

  /// What goes with the shown view: its binding, the resume reload, and the
  /// player and screen share it was speaking for, which would otherwise
  /// outlive it (BGAUDIO-006, SHARE-017).
  void _shownGone({required Commit commit}) {
    tabBinding.unbind(commit: commit);
    resumeReload.reset();
    unawaited(MediaSessionService.instance.stopForSite(siteId));
    unawaited(ScreenShare.instance.endSite(siteId));
  }
}
