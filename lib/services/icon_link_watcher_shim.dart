import 'package:webspace/services/page_js.dart';

/// JS handler the watcher calls from the top document's load event.
const String kIconDocumentLoadedHandler = 'wsIconDocumentLoaded';

/// JS handler the watcher calls with the icon links Blink announced.
const String kIconLinksHandler = 'wsIconLinks';

/// JS handler the watcher calls when the top document edits its icon links.
const String kIconLinksChangedHandler = 'wsIconLinksChanged';

/// Follows the top document's icon links for the site-icon engine.
String buildIconLinkWatcherShim() => PageJs.iconLinkWatcher.withConfig({
      'documentLoadedHandler': kIconDocumentLoadedHandler,
      'linksHandler': kIconLinksHandler,
      'linksChangedHandler': kIconLinksChangedHandler,
    });
