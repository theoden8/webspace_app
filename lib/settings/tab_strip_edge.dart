import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/settings/app_prefs.dart';

/// The screen edge the site tab strip runs along (FS-012).
enum TabStripEdge {
  top,
  bottom;

  static TabStripEdge get current =>
      of(AppPref.tabStripEdge.value, desktop: hostIsDesktop);

  /// The edge [stored] names, else the platform's: top where desktop
  /// browsers keep their tabs, bottom within a thumb's reach on a phone.
  static TabStripEdge of(String stored, {required bool desktop}) =>
      values.asNameMap()[stored] ?? (desktop ? top : bottom);
}
