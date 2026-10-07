import 'package:webspace/controllers/site_set_change.dart';
import 'package:webspace/l10n/gen/app_localizations.dart';

/// What every controller of the page asks of it.
abstract interface class PageHost {
  bool get mounted;
  void rebuild();

  /// A SnackBar, built only while the page is mounted.
  void toast(
    String Function(AppLocalizations loc) message, {
    Duration duration,
  });

  /// The one way the set of sites changes (`_commitSites`).
  Future<void> commitSites(SiteSetChange change);
}
