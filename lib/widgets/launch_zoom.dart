import 'dart:async';
import 'dart:ui' show lerpDouble;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:webspace/screens/add_site.dart' show UnifiedFaviconImage;
import 'package:webspace/theme/design_tokens.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/container_mark.dart';
import 'package:webspace/widgets/site_grid_tile.dart';

/// A switch a card covers: [show] makes it, and [shown] says it is on
/// screen.
typedef CardSwitch = ({Future<void> Function() show, bool Function() shown});

/// The library a site's card returns to: [show] brings it back under the
/// card, [shown] says it is on screen, and [into] finds the site's icon
/// there for the card to land in, null where none is in view.
typedef CardLanding = ({
  Future<void> Function() show,
  bool Function() shown,
  Rect? Function() into,
});

/// A site's card between its icon in the library and the full screen: it
/// grows out of the icon as the site opens and shrinks back into it as the
/// library returns, as a phone opens and closes an app (WEBSPACE-008). It
/// covers the screen while the page underneath switches, so the switch is
/// never seen, and takes no input while it moves. A hold on the site's top
/// bar lifts it, and the finger carries it until let go.
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

  /// A held card coming off the screen once the library is under it, so
  /// the site is never seen around it.
  late final AnimationController _raise;

  /// A card let go short of closing, on its way back over the screen.
  late final AnimationController _settle;

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
    _raise = AnimationController(vsync: this, duration: Motion.settle);
    _settle = AnimationController(vsync: this, duration: Motion.settle);
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

  /// The finger holding the card, null while none does.
  _Grip? _grip;

  /// Grows [site]'s card out of its icon at [from], in global coordinates,
  /// until it covers the screen, then switches [to] the site and fades off
  /// it once it is on screen. With no icon to grow from (a tab picked in a
  /// list, a site picked in the tab strip) the card fades in over the screen
  /// instead, so every switch passes through it.
  Future<void> open(
    WebViewModel site, {
    required Rect? from,
    required CardSwitch to,
  }) async {
    if (_site != null ||
        _grip != null ||
        MediaQuery.disableAnimationsOf(context)) {
      return to.show();
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
    final showing = to.show();
    await _hold(until: to.shown);
    if (mounted) await _play(_fade.reverse());
    _done();
    await showing;
  }

  /// Fades [site]'s card in over the screen, brings the library back under
  /// it, and once the library is on screen lands the card in the site's
  /// icon there.
  Future<void> close(WebViewModel site, {required CardLanding to}) async {
    if (_site != null ||
        _grip != null ||
        MediaQuery.disableAnimationsOf(context)) {
      return to.show();
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
    if (!mounted) return to.show();
    final showing = to.show();
    await _land(to);
    _done();
    await showing;
  }

  /// Lifts [site]'s card off the screen by the point a finger holds at [at],
  /// in global coordinates, and brings the library back under it; the
  /// returned hold carries the card until the finger lets go, when it lands
  /// in the site's icon or goes back over the site, which [back] shows
  /// again. With reduced motion nothing lifts, and the library comes back
  /// only once a let-go closes. Null while a card is on screen already.
  CardHold? hold(
    WebViewModel site, {
    required Offset at,
    required CardLanding to,
    required CardSwitch back,
  }) {
    if (_site != null || _grip != null) return null;
    final grip = _Grip(zoom: this, by: _localPoint(at), to: to, back: back);
    _grip = grip;
    if (!MediaQuery.disableAnimationsOf(context)) {
      _fade.value = 0;
      _size.value = 1;
      _raise.value = 0;
      _settle.value = 0;
      setState(() {
        _site = site;
        _lookalike = _sharesAnIcon(site);
        _icon = null;
        _fadeScales = false;
      });
      grip.showing = _lift(to);
    }
    return CardHold._(grip);
  }

  Future<void> _lift(CardLanding to) async {
    await _play(_fade.forward());
    if (!mounted) return;
    final showing = to.show();
    await _hold(until: to.shown);
    if (mounted) unawaited(_play(_raise.forward()));
    await showing;
  }

  void _move(_Grip grip, {required Offset to}) {
    if (!identical(grip, _grip) || grip.letGo || !mounted) return;
    setState(() => grip.at = _localPoint(to));
  }

  Future<void> _letGo(_Grip grip, {required Offset velocity}) async {
    if (!identical(grip, _grip) || grip.letGo || !mounted) return;
    grip.letGo = true;
    final closes = LibraryStyle.pullCloses(
      pulled: grip.at.dy - grip.by.dy,
      extent: (context.findRenderObject()! as RenderBox).size.height,
      velocity: velocity.dy,
    );
    final showing = grip.showing;
    if (showing == null) {
      _grip = null;
      if (closes) await grip.to.show();
      return;
    }
    if (closes) {
      await _land(grip.to);
    } else {
      await _play(_settle.forward());
      // The site comes back after the library has, as a tap would bring it.
      await _hold(until: grip.to.shown);
      if (mounted) {
        final reopening = grip.back.show();
        await _hold(until: grip.back.shown);
        if (mounted) await _play(_fade.reverse());
        _done();
        await Future.wait([showing, reopening]);
        return;
      }
    }
    _done();
    await showing;
  }

  /// Once [to] says the library is on screen, shrinks the card into the
  /// site's icon there, or fades it where it is with no icon in view.
  Future<void> _land(CardLanding to) async {
    await _hold(until: to.shown);
    // The library lays its icons out in the frame that shows it.
    if (mounted) await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    final icon = to.into();
    if (icon == null) {
      setState(() => _fadeScales = true);
      await _play(_fade.reverse());
    } else {
      setState(() => _icon = _local(icon));
      await _play(_size.reverse());
    }
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
    _grip = null;
    if (mounted) setState(() => _site = null);
  }

  Offset _localPoint(Offset global) =>
      (context.findRenderObject()! as RenderBox).globalToLocal(global);

  Rect _local(Rect global) => _localPoint(global.topLeft) & global.size;

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
    _raise.dispose();
    _settle.dispose();
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
            animation: Listenable.merge([_growth, _fade, _raise, _settle]),
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

  /// Where the card is once grown: the screen, or where a finger holds it,
  /// by the point it lifted the card by, smaller the further down it is
  /// pulled, from the moment the library is under it; and on its way back
  /// over the screen once let go short of closing.
  Rect _top(Rect screen) {
    final grip = _grip;
    if (grip == null) return screen;
    final pulled = ((grip.at.dy - grip.by.dy) / screen.height).clamp(0.0, 1.0);
    final scale =
        LibraryStyle.cardLift * (1 - LibraryStyle.cardPullShrink * pulled);
    final held = Rect.fromLTWH(
      grip.at.dx - grip.by.dx * scale,
      grip.at.dy - grip.by.dy * scale,
      screen.width * scale,
      screen.height * scale,
    );
    final raised = Rect.lerp(
      screen,
      held,
      Motion.launchCurve.transform(_raise.value),
    )!;
    return Rect.lerp(
      raised,
      screen,
      Motion.launchCurve.transform(_settle.value),
    )!;
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
    final top = _top(screen);
    // How far a held card is off the screen, which its corners and its
    // shadow show.
    final lifted =
        ((1 - top.width / screen.width) / (1 - LibraryStyle.cardLift)).clamp(
          0.0,
          1.0,
        );
    final rect = icon == null
        ? Rect.fromCenter(
            center: top.center,
            width:
                top.width *
                (_fadeScales ? lerpDouble(.92, 1, _fade.value)! : 1),
            height:
                top.height *
                (_fadeScales ? lerpDouble(.92, 1, _fade.value)! : 1),
          )
        : Rect.lerp(icon, top, t)!;
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
                elevation: lerpDouble(
                  Elevations.floatingActive,
                  Elevations.floatingActive * lifted,
                  shown,
                )!,
                borderRadius: BorderRadius.circular(
                  lerpDouble(
                    LibraryStyle.radius * start,
                    LibraryStyle.cardRadius * lifted,
                    shown,
                  )!,
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

/// A finger holding a site's card: the point of the card it lifted it by
/// and where it is now, in the card's coordinates, and where a let-go takes
/// the card.
final class _Grip {
  _Grip({
    required this.zoom,
    required this.by,
    required this.to,
    required this.back,
  }) : at = by;

  final LaunchZoomState zoom;
  final Offset by;
  Offset at;
  final CardLanding to;
  final CardSwitch back;

  /// The library's switch under the lifted card; null where motion is
  /// reduced and nothing switches until a let-go closes.
  Future<void>? showing;
  bool letGo = false;
}

/// A site's card held by a finger (WEBSPACE-008), from the hold that lifted
/// it to the finger let go: [move] carries it, and [letGo] lands it in the
/// site's icon where [LibraryStyle.pullCloses] says so, or puts it back over
/// the site.
final class CardHold {
  CardHold._(this._grip);

  final _Grip _grip;

  /// The finger moved to [to], in global coordinates.
  void move({required Offset to}) => _grip.zoom._move(_grip, to: to);

  /// The finger let go, moving at [velocity] in logical pixels a second.
  Future<void> letGo({required Offset velocity}) =>
      _grip.zoom._letGo(_grip, velocity: velocity);
}

/// A site's top bar, which a hold lifts the site's card by (WEBSPACE-008).
/// A pull with no hold first is left to what is under it. The finger is
/// followed to its let-go through the pointer itself, since the bar leaves
/// the screen as the library comes back under the card.
class CardHandle extends StatefulWidget implements PreferredSizeWidget {
  const CardHandle({super.key, required this.onHold, required this.child});

  /// Lifts the card for a hold at a point, in global coordinates; null
  /// where the bar lifts nothing.
  final CardHold? Function(Offset at)? onHold;
  final PreferredSizeWidget child;

  @override
  Size get preferredSize => child.preferredSize;

  @override
  State<CardHandle> createState() => _CardHandleState();
}

class _CardHandleState extends State<CardHandle> {
  int? _pointer;

  @override
  Widget build(BuildContext context) {
    final onHold = widget.onHold;
    if (onHold == null) return widget.child;
    return Listener(
      onPointerDown: (event) => _pointer = event.pointer,
      child: GestureDetector(
        onLongPressStart: (details) {
          final pointer = _pointer;
          final hold = onHold(details.globalPosition);
          if (pointer != null && hold != null) _follow(pointer, hold: hold);
        },
        child: widget.child,
      ),
    );
  }

  static void _follow(int pointer, {required CardHold hold}) {
    final router = GestureBinding.instance.pointerRouter;
    final velocity = VelocityTracker.withKind(PointerDeviceKind.touch);
    void route(PointerEvent event) {
      velocity.addPosition(event.timeStamp, event.position);
      if (event is PointerMoveEvent) {
        hold.move(to: event.position);
      } else if (event is PointerUpEvent || event is PointerCancelEvent) {
        router.removeRoute(pointer, route);
        unawaited(
          hold.letGo(
            velocity: event is PointerUpEvent
                ? velocity.getVelocity().pixelsPerSecond
                : Offset.zero,
          ),
        );
      }
    }

    router.addRoute(pointer, route);
  }
}
