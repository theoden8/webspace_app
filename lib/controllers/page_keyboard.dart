import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:webspace/services/keyboard_engine.dart';
import 'package:webspace/services/surface_route_observer.dart';
import 'package:webspace/services/webview_controller.dart';
import 'package:webspace/settings/site_ids.dart';

/// The keyboard the page raised, gone once the user stops facing what
/// raised it (NAV-021): [planKeyboard] decides, this carries it out.
final class PageKeyboard with RouteAware {
  PageKeyboard({required this.pageOf});

  /// The webview showing [site]'s page, if it has one; never builds one.
  final WebViewController? Function(SiteId site) pageOf;

  static const _blurScript =
      'document.activeElement && document.activeElement.blur && '
      'document.activeElement.blur();';

  FocusScopeNode? _scope;
  PageFace? _face;

  /// Hears of the routes pushed over [route], the page's own, whose focus
  /// is all under [scope].
  void watch(ModalRoute<dynamic> route, {required FocusScopeNode scope}) {
    _scope = scope;
    coverRouteObserver.subscribe(this, route);
  }

  void dispose() => coverRouteObserver.unsubscribe(this);

  /// From the page's build, as the screenshot guard follows the site on
  /// screen: every path that moves it rebuilds the page.
  void follow(PageFace face) {
    final from = _face;
    _face = face;
    if (from != null) _apply(FaceChanged(from: from, to: face));
  }

  /// The drawer opened over the page.
  void covered() => _apply(Covered(face: _face ?? (site: null, tab: null)));

  /// Before the pushed route's own field asks for the keyboard: its focus
  /// is still being moved, so the hide sent here lands ahead of its show.
  @override
  void didPushNext() => covered();

  void _apply(KeyboardEvent event) {
    final plan = planKeyboard(event, focus: _focusOwner());
    if (plan.hide) {
      unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.hide'));
    }
    if (plan.blur case final site?) {
      if (pageOf(site) case final page?) {
        unawaited(page.evaluateJavascript(_blurScript));
      }
    }
  }

  FocusOwner _focusOwner() {
    final primary = FocusManager.instance.primaryFocus;
    final scope = _scope;
    if (primary == null || scope == null || primary is FocusScopeNode) {
      return FocusOwner.page;
    }
    return identical(primary, scope) || primary.ancestors.contains(scope)
        ? FocusOwner.page
        : FocusOwner.screenOver;
  }
}
