/// Rows shared by App Settings and the category screens it opens.
library;

import 'package:flutter/material.dart';

import 'package:webspace/services/reentry_guard.dart';
import 'package:webspace/settings/app_prefs.dart';

/// One opener at a time on a settings screen. A tap that lands while an
/// earlier one is still opening a screen or dialog (an `await` before the
/// push, a file picker), or while what it opened is still on top, is dropped
/// rather than stacking a second copy.
mixin SettingsOpenGuard<T extends StatefulWidget> on State<T> {
  final _opening = ReentryGuard();

  Future<void> guardedOpen(Future<void> Function() open) async {
    if (ModalRoute.isCurrentOf(context) == false) return;
    await _opening.run(open);
  }
}

/// Rebuilds the screen whenever an app pref changes, so a row reading
/// `AppPref.x.value` shows what was just set.
mixin RebuildOnAppPref<T extends StatefulWidget> on State<T> {
  @override
  void initState() {
    super.initState();
    AppPref.anyChange.addListener(_rebuildOnAppPref);
  }

  @override
  void dispose() {
    AppPref.anyChange.removeListener(_rebuildOnAppPref);
    super.dispose();
  }

  void _rebuildOnAppPref() {
    if (mounted) setState(() {});
  }
}
