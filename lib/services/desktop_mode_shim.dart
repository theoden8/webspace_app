import 'package:webspace/services/page_js.dart';
import 'package:webspace/services/user_agent_classifier.dart';

/// The per-site desktop-mode shim for [userAgent]. The caller is
/// responsible for only invoking this when [isDesktopUserAgent] returns
/// true; the shim assumes the UA is desktop-shaped and uses
/// [inferDesktopUaPlatform] to pick the matching `navigator.platform`. The
/// UA text itself never reaches the page.
String buildDesktopModeShim(String userAgent) =>
    PageJs.desktopMode.withConfig({
      'platform': navigatorPlatformFor(inferDesktopUaPlatform(userAgent)),
    });
