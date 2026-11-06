import 'package:webspace/services/page_js.dart';
import 'package:webspace/settings/web_view_theme.dart';

/// The theme shim telling a page to prefer [theme].
String buildThemeColorSchemeShim(WebViewTheme theme) =>
    PageJs.themeColorScheme.withConfig({'theme': theme.name});
