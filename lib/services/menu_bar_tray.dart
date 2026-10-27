import 'dart:ui' as ui;

import 'package:flutter/services.dart';

import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/tray_icon.dart';
import 'package:webspace/services/tray_menu_engine.dart';

/// The tray on macOS: a status item in the menu bar, which the runner draws
/// from what this sends over the `tray` channel (NOTIF-019). Its picture is
/// a template image, so the menu bar tints it for its light or dark look.
class MenuBarTray implements TrayIcon {
  MenuBarTray({required TrayHandlers handlers, MethodChannel? channel})
      : _handlers = handlers,
        _channel = channel ?? _defaultChannel;

  static const _defaultChannel =
      MethodChannel('org.codeberg.theoden8.webspace/tray');

  final TrayHandlers _handlers;
  final MethodChannel _channel;
  TrayMenu? _menu;
  Uint8List? _icon;

  @override
  Future<bool> show(TrayMenu menu) async {
    _menu = menu;
    _channel.setMethodCallHandler(_answer);
    final icon = _icon ??= await _templateIcon();
    return _invoke('show', args: {
      'icon': icon,
      'title': menu.title,
      'entries': [
        for (final entry in menu.entries)
          switch (entry) {
            TrayItem(:final id, :final label, :final action) => {
                'id': id,
                'label': label,
                // The key the app menu answers too.
                'quits': action is TrayQuit,
              },
            TraySeparator(:final id) => {'id': id},
          },
      ],
    });
  }

  @override
  Future<void> remove() async {
    _menu = null;
    await _invoke('remove', args: null);
  }

  Future<Object?> _answer(MethodCall call) async {
    switch (call.method) {
      case 'pressed':
        if (call.arguments case {'id': final int id}) {
          if (_menu?.actionOf(id) case final action?) _handlers.pressed(action);
        }
      case 'opening':
        await _handlers.opening();
      default:
        throw MissingPluginException('tray: no ${call.method}');
    }
    return null;
  }

  Future<bool> _invoke(String method, {required Object? args}) async {
    try {
      await _channel.invokeMethod<void>(method, args);
      return true;
    } on PlatformException catch (e) {
      LogTag.lifecycle.error('Tray $method failed: ${e.code}');
    } on MissingPluginException {
      LogTag.lifecycle.warning('Tray $method: the runner has no channel');
    }
    return false;
  }
}

/// The app's monochrome glyph at 36 pixels, the menu bar's 18 points at 2x.
Future<Uint8List?> _templateIcon() async {
  final images =
      await trayGlyphs('assets/webspace_icon_monochrome.png', sizes: const [36]);
  if (images.isEmpty) return null;
  final png = await images.single.toByteData(format: ui.ImageByteFormat.png);
  return png?.buffer.asUint8List();
}
