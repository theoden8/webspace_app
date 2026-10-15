import 'dart:typed_data';

import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/nav_capture.dart';
import 'package:webspace/services/site_tab.dart';
import 'package:webspace/services/webview_state_storage.dart';
import 'package:webspace/web_view_model.dart';

/// One capture of a site's back stack (TAB-003): read off the webview and
/// saved under the tab it was built for, unless that tab closed or moved
/// to another container meanwhile.
final class SiteNavCapture implements NavCapture {
  SiteNavCapture(this.model, {required this.tab, required WebViewStateStorage navStates})
    : key = model.stateKeyForTab(tab.id),
      _navStates = navStates;

  final WebViewModel model;
  final SiteTab tab;
  final String key;
  final WebViewStateStorage _navStates;

  @override
  Future<Uint8List?> read() async {
    final captured = await model.captureNavigationState();
    return captured?.bytes;
  }

  @override
  bool stillHolds() {
    if (model.tabs.contains(tab) && model.stateKeyForTab(tab.id) == key) {
      return true;
    }
    LogTag.webViewState.debug(
      'Dropped a capture for "${model.name}": its tab closed or moved '
      'to another container meanwhile',
      sensitive: true,
    );
    return false;
  }

  @override
  Future<bool> save(Uint8List bytes) async {
    if (!await _navStates.saveState(key, state: bytes)) return false;
    LogTag.webViewState.debug(
      'Captured ${bytes.length} bytes for "${model.name}" '
      '(state key: $key)',
      sensitive: true,
    );
    return true;
  }
}
