import 'package:webspace/services/isolation.dart';
import 'package:webspace/services/web_extension_attach_engine.dart';
import 'package:webspace/services/web_extension_library.dart';
import 'package:webspace/web_view_model.dart';

/// Which imported web extensions the site runs, and where.
extension WebViewModelExtensions on WebViewModel {
  /// What the site's webviews load of the extension library (WEBEXT-016),
  /// and why none when none: the posture's and the Extensions row's answer.
  ExtensionAttach get extensionPlan => planExtensionAttach((
        offered: webExtensionsOffered,
        archived: isArchiveTier,
        kiosk: effectiveKioskMode,
        incognito: effectiveIncognito,
        choices: webExtensionChoices,
        library: WebExtensionLibrary.instance.loadable,
        claims: effectiveDomainClaims,
      ));

  /// Where this site's extensions keep what they store and open their pages
  /// under [isolation] (WEBEXT-008); null where they keep nothing.
  ExtensionHome? extensionHome(Isolation isolation) => extensionHomeOf(
        extensionPlan,
        container: boundContainerId(isolation),
      );
}
