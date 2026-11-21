import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webspace/theme/design_tokens.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/launch_zoom.dart';

/// A plain surface over the page while the app is entered from outside it,
/// so neither the webspace list nor the site the app was left on is seen on
/// the way to the screen it was entered for (HS-006). A launch starts
/// covered: until the restore has read the shortcut, it does not know
/// whether one names a site.
class EntryCover {
  /// Covered until [until], the launch's end, whatever it decided.
  EntryCover({
    required this.card,
    required this.shown,
    required Future<Object?> until,
  }) {
    unawaited(until.then((_) => lift()));
  }

  /// The library's card a site's entry runs under; null in the legacy design.
  final LaunchZoomState? Function() card;

  /// The site on screen.
  final WebViewModel? Function() shown;

  final _covering = ValueNotifier(true);
  Timer? _cap;
  bool _disposed = false;

  /// The launch knows its screen: the list shows at once, a [site] once its
  /// activation ends ([lift]), and no later than [Motion.launchHold], as a
  /// switch whose platform call is slow shows as it is.
  void decided(WebViewModel? site) {
    if (site == null) return lift();
    _cap?.cancel();
    _cap = Timer(Motion.launchHold, lift);
  }

  void lift() {
    _cap?.cancel();
    if (!_disposed) _covering.value = false;
  }

  /// Runs [show], which puts [site] on screen, covered until it ends.
  Future<void> over(
    WebViewModel site, {
    required Future<void> Function() show,
  }) async {
    _covering.value = true;
    decided(site);
    Future<void> uncover() => show().whenComplete(lift);
    final zoom = card();
    if (zoom == null) return uncover();
    await zoom.cover(site,
        to: (show: uncover, shown: () => identical(shown(), site)));
  }

  /// Under the card, over everything else.
  Widget view() => ValueListenableBuilder(
        valueListenable: _covering,
        builder: (context, covering, _) => covering
            ? AbsorbPointer(
                child: ColoredBox(
                    color: Theme.of(context).scaffoldBackgroundColor),
              )
            : const IgnorePointer(child: SizedBox.expand()),
      );

  void dispose() {
    _disposed = true;
    _cap?.cancel();
    _covering.dispose();
  }
}
