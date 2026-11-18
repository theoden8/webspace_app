import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp
    show WebUri;
import 'package:meta/meta.dart';
import 'package:webspace/services/cookie_manager.dart';
import 'package:webspace/services/webview_controller.dart';

/// The cookies queued for a site's container, written once its webview
/// exists: an archive's open queues the saved login its state holds
/// ([`ArchiveHandle.state.cookies`]), and a settings import the backup's
/// cookies (BACKUP-003). Without them a site on native containers loads with
/// a jar that has never seen them.
final class ContainerCookieQueue {
  List<Cookie>? _queued;

  /// What the next controller will be handed, if anything.
  @visibleForTesting
  List<Cookie>? get queued => _queued;

  /// Replaces the queue, as each re-open of the archive does.
  void queue(List<Cookie> cookies) => _queued = List<Cookie>.from(cookies);

  /// Writes the queued cookies into [controller]'s container and empties the
  /// queue.
  Future<void> pushInto(WebViewController controller) async {
    final pending = _queued;
    if (pending == null || pending.isEmpty) return;
    _queued = null;
    for (final cookie in pending) {
      if (cookie.name.isEmpty || cookie.value.isEmpty) continue;
      final dom = cookie.domain ?? '';
      final cleanDomain = dom.startsWith('.') ? dom.substring(1) : dom;
      if (cleanDomain.isEmpty) continue;
      final path = cookie.path ?? '/';
      // The plugin asserts both are non-empty.
      if (path.isEmpty) continue;
      try {
        await cookieChannel((plugin) => plugin.setCookie(
              url: inapp.WebUri('https://$cleanDomain$path'),
              name: cookie.name,
              value: cookie.value.toString(),
              domain: cookie.domain,
              path: path,
              expiresDate: cookie.expiresDate,
              isSecure: cookie.isSecure,
              isHttpOnly: cookie.isHttpOnly,
              webViewController: controller.nativeController,
            ));
      } on CookieJarFailure {
        // Best effort. A cookie that fails to insert (malformed attributes from
        // a legacy import, expired, etc.) is simply dropped from the runtime
        // jar; archive state still has it for future round-trips.
      }
    }
  }
}
