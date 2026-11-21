import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/services/web_extension_grants_engine.dart'
    show refusedPermissions;

/// What an extension asks for, as every summary of it says it (WEBEXT-015):
/// its API permissions, those it is never given here, and the pages it asks
/// to reach.
List<Localized> extensionAsks({
  required Iterable<String> permissions,
  required Iterable<String> hosts,
  required AppLocalizations loc,
}) {
  final asked = permissions.toList()..sort();
  final refused = refusedPermissions(asked).toList()..sort();
  final pages = hosts.toList()..sort();
  return [
    asked.isEmpty
        ? loc.extensionsAsksNothing
        : loc.extensionsAsks(asked.join(', ')),
    if (refused.isNotEmpty) loc.extensionsNotGiven(refused.join(', ')),
    pages.isEmpty
        ? loc.extensionsReachesNothing
        : loc.extensionsReaches(pages.join(', ')),
  ];
}
