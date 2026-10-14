import 'package:flutter/services.dart'
    show MissingPluginException, PlatformException;

import 'package:webspace/services/file_dialog.dart' show FileDialogFailure;

/// Runs a file_picker call, reporting a failure as a [FileDialogFailure].
/// The browser's dialog reports none of its own; only the platform channel
/// that stands in where no web plugin registered can fail.
Future<T> guarded<T>(Future<T> Function() call) async {
  try {
    return await call();
  } on PlatformException catch (e, st) {
    _fail(e, st: st);
  } on MissingPluginException catch (e, st) {
    _fail(e, st: st);
  }
}

Never _fail(Object e, {required StackTrace st}) =>
    Error.throwWithStackTrace(FileDialogFailure('$e'), st);
