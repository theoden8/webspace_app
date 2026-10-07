import 'package:flutter/material.dart';

/// The one way a screen shows a SnackBar. On the messenger rather than a
/// context, so a caller past an await can use the one it captured before it.
extension Toast on ScaffoldMessengerState {
  /// [replace] drops the SnackBar on screen first, for a message that
  /// supersedes the last one rather than queueing behind it.
  void toast(
    String message, {
    Duration duration = const Duration(seconds: 4),
    bool replace = false,
    bool floating = false,
    SnackBarAction? action,
  }) {
    if (replace) hideCurrentSnackBar();
    showSnackBar(SnackBar(
      content: Text(message),
      duration: duration,
      behavior: floating ? SnackBarBehavior.floating : null,
      action: action,
    ));
  }
}
