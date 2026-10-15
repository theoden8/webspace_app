import 'package:webspace/services/page_js.dart';
import 'package:webspace/settings/web_view_theme.dart';

/// The user-script group the theme shim is injected under, at creation and
/// on every later change, so a change replaces the script a page loads with.
const themeColorSchemeGroup = 'theme_color_scheme_shim';

/// The theme shim telling a page to prefer [theme].
String buildThemeColorSchemeShim(WebViewTheme theme) =>
    PageJs.themeColorScheme.withConfig({'theme': theme.name});
