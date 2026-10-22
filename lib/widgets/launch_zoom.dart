import 'dart:async';
import 'dart:ui' show lerpDouble;
import 'package:flutter/material.dart';
import 'package:webspace/screens/add_site.dart' show UnifiedFaviconImage;
import 'package:webspace/theme/design_tokens.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/site_grid_tile.dart';

/// A site's card between its icon in the library and the full screen: it
/// grows out of the icon as the site opens and shrinks back into it as the
/// library returns, as a phone opens and closes an app (WEBSPACE-008). It
/// covers the screen while the page underneath switches, so the switch is
/// never seen, and takes no input while it moves.
class LaunchZoom extends StatefulWidget {
  const LaunchZoom({super.key});

  @override
  State<LaunchZoom> createState() => LaunchZoomState();
}

class LaunchZoomState extends State<LaunchZoom> with TickerProviderStateMixin {
  late final AnimationController _size;
  late final CurvedAnimation _growth;
  late final AnimationController _fade;

  @override
  void initState() {
    super.initState();
    _size = AnimationController(
      vsync: this,
      duration: Motion.launch,
      reverseDuration: Motion.launchBack,
    );
    _growth = CurvedAnimation(
      parent: _size,
      curve: Motion.launchCurve,
      reverseCurve: Motion.launchCurve.flipped,
    );
    _fade = AnimationController(vsync: this, duration: Motion.reveal);
  }

  /// The site whose card is on screen; null while none is.
  WebViewModel? _site;

  /// Its icon's well, in this widget's coordinates; null where no icon is in
  /// view to land on, and the card fades out where it is instead.
  Rect? _icon;

  /// Grows [site]'s card out of its icon at [from], in global coordinates,
  /// until it covers the screen, then runs [show] and fades off the site
  /// once [shown] says it is on screen.
  Future<void> open(
    WebViewModel site, {
    required Rect from,
    required Future<void> Function() show,
    required bool Function() shown,
  }) async {
    if (_site != null || MediaQuery.disableAnimationsOf(context)) {
      return show();
    }
    _fade.value = 1;
    _size.value = 0;
    setState(() {
      _site = site;
      _icon = _local(from);
    });
    await _play(_size.forward());
    if (!mounted) return;
    final showing = show();
    await _hold(until: shown);
    if (mounted) await _play(_fade.reverse());
    _done();
    await showing;
  }

  /// Covers the screen with [site]'s card at once, runs [show] to bring the
  /// library back, and once [shown] says it is on screen shrinks the card
  /// into the icon [into] finds there.
  Future<void> close(
    WebViewModel site, {
    required Future<void> Function() show,
    required bool Function() shown,
    required Rect? Function() into,
  }) async {
    if (_site != null || MediaQuery.disableAnimationsOf(context)) {
      return show();
    }
    _fade.value = 1;
    _size.value = 1;
    setState(() {
      _site = site;
      _icon = null;
    });
    final showing = show();
    await _hold(until: shown);
    // The library lays its icons out in the frame that shows it.
    if (mounted) await WidgetsBinding.instance.endOfFrame;
    if (mounted) {
      final icon = into();
      if (icon == null) {
        await _play(_fade.reverse());
      } else {
        setState(() => _icon = _local(icon));
        await _play(_size.reverse());
      }
    }
    _done();
    await showing;
  }

  /// The card stays over the screen until [until] holds, as a splash does
  /// until an app's first frame, but no longer than [Motion.launchHold]: a
  /// switch whose platform call is slow, or never answers, shows as it is.
  Future<void> _hold({required bool Function() until}) async {
    var waiting = true;
    final cap = Timer(Motion.launchHold, () => waiting = false);
    while (mounted && waiting && !until()) {
      await WidgetsBinding.instance.endOfFrame;
    }
    cap.cancel();
  }

  void _done() {
    if (mounted) setState(() => _site = null);
  }

  Rect _local(Rect global) {
    final box = context.findRenderObject()! as RenderBox;
    return box.globalToLocal(global.topLeft) & global.size;
  }

  /// [run] to its end, or to the controller's disposal with the page.
  Future<void> _play(TickerFuture run) async {
    try {
      await run.orCancel;
    } on TickerCanceled {
      return;
    }
  }

  @override
  void dispose() {
    _growth.dispose();
    _size.dispose();
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final site = _site;
    if (site == null) return const IgnorePointer(child: SizedBox.expand());
    return AbsorbPointer(
      child: ExcludeSemantics(
        child: LayoutBuilder(
          builder: (context, constraints) => AnimatedBuilder(
            animation: Listenable.merge([_growth, _fade]),
            builder: (context, _) =>
                _card(context, site: site, screen: Offset.zero & constraints.biggest),
          ),
        ),
      ),
    );
  }

  Widget _card(
    BuildContext context, {
    required WebViewModel site,
    required Rect screen,
  }) {
    final theme = Theme.of(context);
    final t = _growth.value;
    final shown = t.clamp(0.0, 1.0);
    final icon = _icon;
    final rect = icon == null
        ? Rect.fromCenter(
            center: screen.center,
            width: screen.width * lerpDouble(.92, 1, _fade.value)!,
            height: screen.height * lerpDouble(.92, 1, _fade.value)!,
          )
        : Rect.lerp(icon, screen, t)!;
    return Stack(
      children: [
        Positioned.fromRect(
          rect: rect,
          child: Opacity(
            opacity: _fade.value,
            child: Material(
              color: Color.lerp(
                SiteGridTile.wellColor(site, theme: theme),
                theme.colorScheme.surface,
                shown,
              ),
              elevation: Elevations.floatingActive * (1 - shown),
              borderRadius: BorderRadius.circular(
                lerpDouble(LibraryStyle.radius, 0, shown)!,
              ),
              clipBehavior: Clip.antiAlias,
              child: Center(
                child: UnifiedFaviconImage.site(
                  site,
                  size: LibraryStyle.siteIcon,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
