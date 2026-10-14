import 'dart:io' show IOException;

import 'package:dbus/dbus.dart'
    show
        DBusClosedException,
        DBusMethodResponseException,
        DBusReplySignatureException,
        DBusSignalSignatureException;
import 'package:flutter/services.dart'
    show MissingPluginException, PlatformException;

import 'package:webspace/services/file_dialog.dart' show FileDialogFailure;

/// Runs a file_picker call, reporting each failure its implementations raise
/// as a [FileDialogFailure]: the platform channel on Android, iOS and macOS,
/// the files macOS reads back, and the xdg portal Linux reaches over D-Bus
/// (an unreachable bus is a SocketException, an absent portal a
/// DBusMethodResponseException, a malformed URI it returns a FormatException).
Future<T> guarded<T>(Future<T> Function() call) async {
  try {
    return await call();
  } on PlatformException catch (e, st) {
    _fail(e, st: st);
  } on MissingPluginException catch (e, st) {
    _fail(e, st: st);
  } on IOException catch (e, st) {
    _fail(e, st: st);
  } on FormatException catch (e, st) {
    _fail(e, st: st);
  } on DBusMethodResponseException catch (e, st) {
    _fail(e, st: st);
  } on DBusReplySignatureException catch (e, st) {
    _fail(e, st: st);
  } on DBusSignalSignatureException catch (e, st) {
    _fail(e, st: st);
  } on DBusClosedException catch (e, st) {
    _fail(e, st: st);
  } on String catch (e, st) {
    // dbus 0.7.12 throws bare strings when the bus address names no socket
    // it can open (dbus_client.dart:737-781).
    _fail(e, st: st);
  }
}

Never _fail(Object e, {required StackTrace st}) =>
    Error.throwWithStackTrace(FileDialogFailure('$e'), st);
