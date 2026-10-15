import 'dart:typed_data';

import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/site_tab.dart';
import 'package:webspace/services/step_table.dart';

/// A webview's back stack as `saveState` returned it, with the tab whose
/// history it is.
typedef CapturedNavState = ({TabId tab, Uint8List bytes});

/// Which tab's history a site's one webview shows (TAB-003): the tab it was
/// built for, and the back stack queued for the next build, tagged with the
/// tab it was read for. A build takes the bytes only when it is built for
/// that tab, so a back stack read before the active tab moved never lands in
/// another tab's webview, and a capture keys its bytes by the tab the
/// webview shows rather than by whatever tab is active when it returns.
final class WebViewTabBinding {
  TabId? _built;
  CapturedNavState? _queued;

  /// The tab the live webview was built for; null while there is none.
  TabId? get built => _built;

  /// The back stack queued for the next build, with the tab it was read for.
  CapturedNavState? get queued => _queued;

  /// The tab the queued back stack was read for, if one is queued.
  TabId? get queuedFor => _queued?.tab;

  /// Queues [bytes], read from [tab]'s file, for the next build: the
  /// model's `queued[s]`, written in a step's [commit].
  void queue(Uint8List bytes, {required TabId tab, required Commit commit}) =>
      _queued = (tab: tab, bytes: bytes);

  /// A webview is being built for [tab].
  void bind(TabId tab) => _built = tab;

  /// The webview is gone.
  void unbind() => _built = null;

  /// The back stack queued for [tab], handed over once. Bytes queued for
  /// another tab are dropped: that tab is no longer the one being built.
  Uint8List? take({required TabId tab}) {
    final queued = _queued;
    _queued = null;
    if (queued == null) return null;
    if (queued.tab != tab) {
      LogTag.webViewState.debug('Dropped a back stack queued for tab '
          '${queued.tab}: the webview is built for $tab');
      return null;
    }
    return queued.bytes;
  }
}
