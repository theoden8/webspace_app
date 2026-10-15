import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:webspace/services/content_blocker_service.dart';
import 'package:webspace/services/dns_block_service.dart';
import 'package:webspace/services/dns_level_mask_engine.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/site_posture.dart';

/// What the platform reports of one webview's life, by the callback.
enum PageEvent {
  viewCreated,
  loadStarted,
  commitVisible,
  loadStopped,

  /// A main-frame load failed.
  loadFailed,
  rendererGone,
  unmounted,
}

/// Where one webview's view is in its life. [PagePhases.on] moves it, one
/// event at a time, and says whether the callback that reported it may act.
enum PagePhase {
  /// The widget, before its platform view exists.
  created,
  attached,
  loading,
  committed,
  loaded,
  failed,

  /// Its renderer died; the host remounts the widget, which builds a new
  /// view.
  gone,
  disposed;

  /// Where [event] moves a view here, or null when the callback that
  /// reported it must not act: one arriving after the renderer died or the
  /// view was disposed reports on a view the site no longer runs in. A view
  /// created starts a new life whatever the last one ended in.
  PagePhase? after(PageEvent event) => switch ((this, event)) {
    (_, PageEvent.viewCreated) => attached,
    (created, _) => null,
    (attached || loading || committed || loaded || failed, final e) =>
      switch (e) {
        PageEvent.viewCreated => attached,
        PageEvent.loadStarted => loading,
        PageEvent.commitVisible => committed,
        PageEvent.loadStopped => loaded,
        PageEvent.loadFailed => failed,
        PageEvent.rendererGone => gone,
        PageEvent.unmounted => disposed,
      },
    (gone, PageEvent.unmounted) => disposed,
    (gone || disposed, _) => null,
  };

  /// Whether a callback may still act on the view here.
  bool get live => switch (this) {
    created || attached || loading || committed || loaded || failed => true,
    gone || disposed => false,
  };
}

/// What a page needs in place before any load starts, each read from the
/// service that owns it.
enum PagePrerequisite {
  /// The engine built from the lists on disk (CB-001).
  contentBlocker,

  /// The level sets read from disk (DNS-003).
  dnsBlocklist;

  bool metBy(SiteBlocking blocking, {required int dnsLevel}) => switch (this) {
    contentBlocker =>
      !blocking.contentBlock || ContentBlockerService.instance.data.settled,
    dnsBlocklist =>
      dnsLevel == kDnsLevelOff || DnsBlockService.instance.data.settled,
  };
}

/// One advance of a webview's phase, as [PagePhases.sink] hears it.
typedef PageAdvance = ({PagePhase from, PageEvent event, PagePhase? to});

/// One document a view showed, numbered in the order they came: a new one
/// each time a load starts. A navigation only asked for may still be
/// cancelled (a link routed elsewhere, a blocked URL), and leaves the page
/// in place.
extension type const PageDocument._(int serial) {}

/// The document a script is decided for. [evaluate] runs it only while that
/// document is the one its view shows, so a script decided across an await
/// lands nowhere once the page has moved on, never in the next page.
final class PageScope {
  PageScope._(
    this._phases, {
    required this.document,
    required inapp.InAppWebViewController controller,
  }) : _controller = controller;

  final PagePhases _phases;
  final PageDocument document;

  /// The controller the callback that took this scope was handed, reached
  /// only through [evaluate].
  final inapp.InAppWebViewController _controller;

  /// Whether the view still shows [document].
  bool get current => _phases.shows(document, view: _controller.platform);

  /// Runs [js] in [document]'s main frame, or nothing once the view has
  /// moved on. The `;null;` tail keeps WebKit from reporting the last
  /// expression's value as an unsupported return type.
  Future<void> evaluate(String js) async {
    if (!current) return;
    try {
      await _controller.evaluateJavascript(source: '$js\n;null;');
    } on PlatformException catch (e) {
      LogTag.webView.debug('A page refused a script: $e', sensitive: true);
    } on MissingPluginException {
      return;
    }
  }
}

/// One webview's phase, advanced only through [on]. It follows one view at
/// a time, the last one created: the same widget remounted after its
/// renderer died builds a new view behind the same callbacks, and each
/// callback names its view by the platform controller under the one it
/// passes. Not by that controller itself: the plugin hands `onWebViewCreated`
/// one wrapper and every later callback another, over the same platform
/// controller.
final class PagePhases {
  PagePhases({required this.blocking, required this.dnsLevel});

  final SiteBlocking blocking;

  /// The level the page runs at, read when a load starts.
  final int Function() dnsLevel;

  PagePhase _phase = PagePhase.created;
  PagePhase get phase => _phase;
  inapp.PlatformInAppWebViewController? _view;
  int _asked = 0;
  int _serial = 0;

  /// Navigations asked for, in any frame: each one the engine asks about,
  /// its server redirects included. A frame it asks about is on its way out,
  /// and a script posted against one being torn down is bound to a frame
  /// Chromium frees under it (the SIGTRAP at `partition_alloc_support.cc`).
  int get asked => _asked;

  /// The engine asks whether a navigation may go ahead.
  void asks() => _asked++;

  /// The document [controller]'s view shows now, to evaluate in as long as
  /// it stays.
  PageScope page(inapp.InAppWebViewController controller) =>
      PageScope._(this, document: PageDocument._(_serial), controller: controller);

  /// Whether [view] still shows [document] and may be acted on.
  bool shows(
    PageDocument document, {
    required inapp.PlatformInAppWebViewController view,
  }) => live(view: view) && document.serial == _serial;

  /// Every advance, for a test that follows a webview's life; a dropped
  /// callback's `to` is null.
  static void Function(PageAdvance advance)? sink;

  /// Whether a callback from [view] may act: it reports on the view the
  /// site runs in, and that view is live.
  bool live({required inapp.PlatformInAppWebViewController view}) => identical(view, _view) && _phase.live;

  /// Moves the view by [event], reported by a callback from [view]; false
  /// when that callback must not act. A load that starts without what the
  /// page needs is an assert: the app let it start.
  bool on(
    PageEvent event, {
    required inapp.PlatformInAppWebViewController view,
  }) {
    if (event == PageEvent.viewCreated) _view = view;
    if (!identical(view, _view)) {
      sink?.call((from: _phase, event: event, to: null));
      return false;
    }
    return _advance(event);
  }

  /// The widget left the tree, taking the view it shows with it.
  void unmounted() => _advance(PageEvent.unmounted);

  bool _advance(PageEvent event) {
    final from = _phase;
    final to = from.after(event);
    sink?.call((from: from, event: event, to: to));
    if (to == null) return false;
    if (event == PageEvent.loadStarted) {
      final unmet = [
        for (final p in PagePrerequisite.values)
          if (!p.metBy(blocking, dnsLevel: dnsLevel())) p.name,
      ];
      assert(unmet.isEmpty, 'a page started loading before ${unmet.join(', ')}');
    }
    if (event == PageEvent.loadStarted || event == PageEvent.viewCreated) {
      _serial++;
    }
    _phase = to;
    return true;
  }
}
