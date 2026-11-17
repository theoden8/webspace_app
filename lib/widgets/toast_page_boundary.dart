import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Keeps a snackbar with the page that was visible when it was shown.
/// Call before rebuilding after the active site or tab changes.
class ToastPageBoundary {
  Object? _site;
  Object? _tab;
  Object? _scope;
  List<Object?> _tabs = const [];

  void follow({
    required Object? site,
    required Object? tab,
    required Object? scope,
    required Iterable<Object?> tabs,
    required ScaffoldMessengerState? messenger,
  }) {
    final nextTabs = tabs.toList();
    if (identical(site, _site) &&
        tab == _tab &&
        scope == _scope &&
        listEquals(nextTabs, _tabs)) {
      return;
    }
    _site = site;
    _tab = tab;
    _scope = scope;
    _tabs = nextTabs;
    // A queued snackbar must not appear on the next page after the current
    // one disappears.
    messenger?.clearSnackBars();
    messenger?.removeCurrentSnackBar();
  }
}
