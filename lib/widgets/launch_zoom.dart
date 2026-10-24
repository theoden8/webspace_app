import 'dart:async';
import 'dart:ui' show lerpDouble;
import 'package:flutter/material.dart';
import 'package:webspace/screens/add_site.dart' show UnifiedFaviconImage;
import 'package:webspace/theme/design_tokens.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/container_mark.dart';
import 'package:webspace/widgets/site_grid_tile.dart';

/// A site's card between its icon in the library and the full screen: it
/// grows out of the icon as the site opens and shrinks back into it as the
/// library returns, as a phone opens and closes an app (WEBSPACE-008). It
/// covers the screen while the page underneath switches, so the switch is
/// never seen, and takes no input while it moves.
class LaunchZoom extends StatefulWidget {
  const LaunchZoom({super.key, required this.sites});

  /// Every saved site, which says whether another shows a site's icon, and so
  /// whether its card is marked in its container's colour as its tile is.
  final List<WebViewModel> sites;

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

  /// Whether another site shows [_site]'s icon.
  bool _lookalike = false;

  /// Its icon's well, in this widget's coordinates; null where no icon is in
  /// view to land on, and the card fades out where it is instead.
  Rect? _icon;

  /// Whether the card, with no icon, shrinks a little as it fades out (and
  /// grows as it fades in), as Material's fade-through does. A card fading
  /// in to shrink into an icon next keeps its size.
  bool _fadeScales = false;

  /// Grows [site]'s card out of its icon at [from], in global coordinates,
  /// until it covers the screen, then runs [show] and fades off the site
  /// once [shown] says it is on screen. With no icon to grow from (a tab
  /// picked in a list, a site picked in the tab strip) the card fades in
  /// over the screen instead, so every switch passes through it.
  Future<void> open(
    WebViewModel site, {
    required Rect? from,
    required Future<void> Function() show,
    required bool Function() shown,
  }) async {
    if (_site != null || MediaQuery.disableAnimationsOf(context)) {
      return show();
    }
    _fade.value = from == null ? 0 : 1;
    _size.value = from == null ? 1 : 0;
    setState(() {
      _site = site;
      _lookalike = _sharesAnIcon(site);
      _icon = from == null ? null : _local(from);
      _fadeScales = true;
    });
    await _play(from == null ? _fade.forward() : _size.forward());
    if (!mounted) return;
    final showing = show();
    await _hold(until: shown);
    if (mounted) await _play(_fade.reverse());
    _done();
    await showing;
  }

  /// Fades [site]'s card in over the screen, runs [show] to bring the
  /// library back under it, and once [shown] says it is on screen shrinks
  /// the card into the icon [into] finds there.
  Future<void> close(
    WebViewModel site, {
    required Future<void> Function() show,
    required bool Function() shown,
    required Rect? Function() into,
  }) async {
    if (_site != null || MediaQuery.disableAnimationsOf(context)) {
      return show();
    }
    _fade.value = 0;
    _size.value = 1;
    setState(() {
      _site = site;
      _lookalike = _sharesAnIcon(site);
      _icon = null;
      _fadeScales = false;
    });
    await _play(_fade.forward());
    if (!mounted) return show();
    final showing = show();
    await _hold(until: shown);
    // The library lays its icons out in the frame that shows it.
    if (mounted) await WidgetsBinding.instance.endOfFrame;
    if (mounted) {
      final icon = into();
      if (icon == null) {
        setState(() => _fadeScales = true);
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

  bool _sharesAnIcon(WebViewModel site) =>
      sitesSharingAnIcon(widget.sites).contains(site.siteId);

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
            builder: (context, _) => _card(
              context,
              site: site,
              screen: Offset.zero & constraints.biggest,
            ),
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
    // A card out of a smaller well than a grid's (a folder's rows) starts
    // with its icon and corners at that well's scale.
    final start = icon == null ? 1.0 : icon.width / LibraryStyle.siteWell;
    final rect = icon == null
        ? Rect.fromCenter(
            center: screen.center,
            width:
                screen.width *
                (_fadeScales ? lerpDouble(.92, 1, _fade.value)! : 1),
            height:
                screen.height *
                (_fadeScales ? lerpDouble(.92, 1, _fade.value)! : 1),
          )
        : Rect.lerp(icon, screen, t)!;
    return Stack(
      children: [
        Positioned.fromRect(
          rect: rect,
          child: Opacity(
            opacity: _fade.value,
            child: UnifiedFaviconImage.site(
              site,
              size: LibraryStyle.siteIcon,
              frame: (context, {required missing, required icon}) => Material(
                color: Color.lerp(
                  SiteGridTile.wellColor(
                    SiteGridTile.markOf(
                      site,
                      brightness: theme.brightness,
                      lookalike: _lookalike,
                      missing: missing,
                    ),
                    theme: theme,
                  ),
                  theme.colorScheme.surface,
                  shown,
                ),
                elevation: Elevations.floatingActive * (1 - shown),
                borderRadius: BorderRadius.circular(
                  lerpDouble(LibraryStyle.radius * start, 0, shown)!,
                ),
                clipBehavior: Clip.antiAlias,
                child: Center(
                  child: Transform.scale(
                    scale: lerpDouble(start, 1, t)!,
                    // At its own size, which the scale shrinks, rather than
                    // squeezed into a card smaller than the icon.
                    child: OverflowBox(
                      maxWidth: LibraryStyle.siteIcon,
                      maxHeight: LibraryStyle.siteIcon,
                      child: icon,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
