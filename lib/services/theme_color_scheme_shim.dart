import 'package:flutter/widgets.dart' show Brightness, WidgetsBinding;
import 'package:webspace/services/page_js.dart';
import 'package:webspace/settings/web_view_theme.dart';

/// The theme shim telling a page to prefer [told].
String buildThemeColorSchemeShim(Brightness told) =>
    PageJs.themeColorScheme.withConfig({'theme': told.name});

/// What a page following [theme] is told now: `system` is the brightness
/// the platform last reported to Flutter, so the page and the chrome agree
/// (HINTS-001, A11Y-008).
Brightness toldScheme(WebViewTheme theme) =>
    theme.under(WidgetsBinding.instance.platformDispatcher.platformBrightness);
