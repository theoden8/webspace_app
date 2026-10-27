import 'dart:ui' as ui;

import 'package:flutter/services.dart' show rootBundle;

import 'package:webspace/services/tray_menu_engine.dart';

/// What the desktop's status area hands back: a press on a line, and the menu
/// about to open, which the tray brings up to date first.
typedef TrayHandlers = ({
  void Function(TrayAction action) pressed,
  Future<void> Function() opening,
});

/// The desktop's status area, where the app keeps an icon and a menu while
/// it runs with its window closed (NOTIF-019).
abstract interface class TrayIcon {
  /// Shows [menu] in place of what was shown. False where the desktop has no
  /// status area to show it in, or none yet.
  Future<bool> show(TrayMenu menu);

  /// Takes the icon away.
  Future<void> remove();
}

/// The picture in [asset] cropped to the square around what it draws and
/// scaled to each of [sizes] pixels: launcher artwork keeps a margin a status
/// area has no room for. Empty where the engine could not read the pixels.
Future<List<ui.Image>> trayGlyphs(String asset,
    {required List<int> sizes}) async {
  final data = await rootBundle.load(asset);
  final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
  final source = (await codec.getNextFrame()).image;
  final pixels =
      await source.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
  if (pixels == null) return const [];
  var left = source.width, top = source.height, right = -1, bottom = -1;
  for (var y = 0; y < source.height; y++) {
    for (var x = 0; x < source.width; x++) {
      if (pixels.getUint8((y * source.width + x) * 4 + 3) == 0) continue;
      if (x < left) left = x;
      if (x > right) right = x;
      if (y < top) top = y;
      if (y > bottom) bottom = y;
    }
  }
  if (right < 0) return const [];
  final side = (right - left > bottom - top ? right - left : bottom - top) + 1;
  final crop = ui.Rect.fromCenter(
    center: ui.Offset((left + right + 1) / 2, (top + bottom + 1) / 2),
    width: side.toDouble(),
    height: side.toDouble(),
  );
  Future<ui.Image> scaled(int size) {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawImageRect(
      source,
      crop,
      ui.Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
      ui.Paint()..filterQuality = ui.FilterQuality.high,
    );
    return recorder.endRecording().toImage(size, size);
  }

  return [for (final size in sizes) await scaled(size)];
}
