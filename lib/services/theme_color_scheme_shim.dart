import 'package:webspace/services/page_js.dart';

/// The theme shim for [themeValue]: `'light'`, `'dark'` or `'system'`.
String buildThemeColorSchemeShim(String themeValue) =>
    PageJs.themeColorScheme.withConfig({'theme': themeValue});
