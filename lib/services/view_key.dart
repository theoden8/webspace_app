import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;

/// Names one native webview while it lives. The plugin hands each callback a
/// wrapper of its own over one platform controller, so the key is taken from
/// that controller: every callback of one view agrees on it, which a
/// wrapper's own identity does not.
extension type const ViewKey._(String raw) implements String {
  ViewKey.of(inapp.InAppWebViewController controller)
      : this._('wv${identityHashCode(controller.platform)}');
}
