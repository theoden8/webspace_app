import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/services/file_import_document.dart';
import 'package:webspace/services/url_host.dart';

/// What a site or a tab shows of [url] under its name: the host it opens, or
/// that it is a file the user imported, whose handle names nothing a reader
/// can use.
String addressOf(String url, {required AppLocalizations loc}) =>
    isFileImportUrl(url) ? loc.siteImportedFile : extractDomain(url);
