import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;

/// Names one native webview while it lives. The plugin hands each callback a
/// wrapper of its own over one platform controller, so the key is taken from
/// that controller: every callback of one view agrees on it, which a wrapper's
/// own identity does not.
///
/// The key is minted unique and memoised weakly on the platform controller, so
/// every callback of one view reads the same key and two live views never
/// share one. It is never `identityHashCode`, which is not unique — two live
/// objects can share one and a value is reused after a collection: DL-008 and
/// SHARE-017 compare views by this key, so a shared key would let one view
/// report on another's download or end another's screen share. The mint is a
/// value (a String), never the controller, so a stored key cannot keep a dead
/// controller alive; the memo is an [Expando], so the entry is dropped when the
/// controller is collected.
extension type const ViewKey._(String raw) implements String {
  /// The stable key for [controller]'s view, the same object on every call for
  /// one view. The only way to a [ViewKey]: there is no construction from a
  /// String.
  static ViewKey of(inapp.InAppWebViewController controller) {
    final platform = controller.platform;
    return _byController[platform] ??= ViewKey._('wv${_next++}');
  }
}

/// Weak so a minted key never pins the platform controller (and its native
/// view) in memory: the entry goes when the controller is collected.
final Expando<ViewKey> _byController = Expando<ViewKey>('ViewKey');
int _next = 0;
