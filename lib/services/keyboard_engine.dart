import 'package:webspace/services/site_tab.dart';
import 'package:webspace/settings/site_ids.dart';

/// What the page shows: a site on one of its tabs, or the webspaces when
/// [site] is null.
typedef PageFace = ({SiteId? site, TabId? tab});

/// Whose the focus is as the keyboard is decided: the page's (its URL bar,
/// a site's webview, the drawer, or no field at all), or a screen pushed
/// over the page that focused a field of its own, whose keyboard it is.
enum FocusOwner { page, screenOver }

/// Why the page asks about the keyboard (NAV-021).
sealed class KeyboardEvent {
  const KeyboardEvent();
}

/// What the page shows changed, by any path: another site, another tab, the
/// webspaces.
final class FaceChanged extends KeyboardEvent {
  const FaceChanged({required this.from, required this.to});

  final PageFace from;
  final PageFace to;
}

/// The drawer opened over [face], or a screen was pushed over it: settings,
/// a sheet, a dialog, a nested site.
final class Covered extends KeyboardEvent {
  const Covered({required this.face});

  final PageFace face;
}

/// What the page does: blur the field focused in [blur]'s page, which keeps
/// the keyboard of a page still on screen up, and hide the keyboard.
typedef KeyboardPlan = ({SiteId? blur, bool hide});

const KeyboardPlan _keep = (blur: null, hide: false);

/// A keyboard raised for the page goes when the user stops facing what
/// raised it (NAV-021). A page that leaves the screen loses its native
/// focus with it, so only one still under the drawer or a screen is
/// blurred. A screen over the page that focused a field owns the keyboard,
/// and nothing the page does reaches it.
KeyboardPlan planKeyboard(KeyboardEvent event, {required FocusOwner focus}) =>
    switch (focus) {
      FocusOwner.screenOver => _keep,
      FocusOwner.page => switch (event) {
          FaceChanged(:final from, :final to) =>
            from == to ? _keep : (blur: null, hide: true),
          Covered(:final face) => (blur: face.site, hide: true),
        },
    };
