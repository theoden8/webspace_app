import 'package:webspace/services/page_js.dart';

/// JS handler the watcher calls with the top document's search links.
const String kSearchLinksHandler = 'wsSearchLinks';

/// Reports the top document's OpenSearch links and generator (LIR-035).
String buildSearchLinkWatcherShim() =>
    PageJs.searchLinkWatcher.withConfig({'handler': kSearchLinksHandler});
