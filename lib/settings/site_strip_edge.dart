import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/settings/app_prefs.dart';

/// The screen edge the site site strip runs along (FS-012).
enum SiteStripEdge {
  top,
  bottom;

  static SiteStripEdge get current =>
      of(AppPref.tabStripEdge.value, desktop: hostIsDesktop);

  /// The edge [stored] names, else the platform's: top where desktop
  /// browsers keep their tabs, bottom within a thumb's reach on a phone.
  static SiteStripEdge of(String stored, {required bool desktop}) =>
      values.asNameMap()[stored] ?? (desktop ? top : bottom);
}
