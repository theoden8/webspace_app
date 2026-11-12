import 'package:flutter/widgets.dart';

/// Route observer that every webview-hosting screen subscribes to, so that
/// returning from a pushed page recomposites the Android surface
/// (PAUSE-024 / BUG-001).
///
/// While an opaque route covers a screen, its hybrid-composition platform view
/// is not composited, and Android detaches it from the view hierarchy; popping
/// back re-attaches it, blank, through none of the existing nudge chokepoints.
///
/// Typed to [PageRoute] deliberately. `RouteObserver` only notifies a
/// subscriber when both the popped route and the revealed one are of its type,
/// so a dialog or any other [PopupRoute] — which leaves the webview composited
/// underneath — cannot trigger a repaint.
final RouteObserver<PageRoute<dynamic>> surfaceRouteObserver =
    RouteObserver<PageRoute<dynamic>>();

/// Tells the page every route pushed over it, a sheet's or a dialog's
/// included, which [surfaceRouteObserver] leaves out: anything over the page
/// takes the keyboard the page raised (NAV-021).
final RouteObserver<ModalRoute<dynamic>> coverRouteObserver =
    RouteObserver<ModalRoute<dynamic>>();
