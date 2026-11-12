import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;

/// Names one native webview while it lives. The plugin hands each callback a
/// wrapper of its own over one platform controller, so the key is taken from
/// that controller: every callback of one view agrees on it, which a wrapper's
/// own identity does not.
///
/// Minted from a counter and memoised weakly on the platform controller, so two
/// live views never read the same key (identityHashCode is not unique: two live
/// objects can share one, a value is reused after a collection). The key is a
/// String, never the controller, so a stored key holds no controller, and the
/// [Expando] entry is dropped when the controller is collected.
extension type const ViewKey._(String raw) implements String {
  /// The stable key for [controller]'s view, the same on every call for one
  /// view. The only way to a [ViewKey]: there is no construction from a String.
  static ViewKey of(inapp.InAppWebViewController controller) {
    final platform = controller.platform;
    return _byController[platform] ??= ViewKey._('wv${_next++}');
  }
}

/// Weak so a minted key never pins the platform controller (and its native
/// view) in memory: the entry goes when the controller is collected.
final Expando<ViewKey> _byController = Expando<ViewKey>('ViewKey');
int _next = 0;
