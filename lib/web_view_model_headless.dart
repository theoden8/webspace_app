import 'package:webspace/services/webview_config.dart';
import 'package:webspace/services/webview_host_hooks.dart';
import 'package:webspace/web_view_model.dart';

/// The site as a background wake checks it, with no one on screen.
extension WebViewModelHeadless on WebViewModel {
  /// The site as itself, at its home page, for a headless check in a
  /// background wake (NOTIF-016). Built from the same [sitePosture] as
  /// [getWebView]'s config, so every per-site field reaches the check, under
  /// [hooks] that answer no one: nothing is on screen.
  WebViewConfig headlessCheckConfig(WebViewHostHooks hooks) => WebViewConfig(
        posture: sitePosture(
            globalUserScripts: hooks.globalUserScripts(),
            isolation: hooks.isolation()),
        hooks: hooks.unattended(),
        initialUrl: initUrl,
        cacheFirst: false,
      );
}
