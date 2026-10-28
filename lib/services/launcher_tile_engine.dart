import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'package:webspace/services/untrusted_image.dart';

/// Edge of a home screen tile's bitmap in px: an adaptive icon's 108dp at
/// 4px per dp.
const int kLauncherTileEdge = 432;

/// Edge of the square a site icon is fitted into: the largest square inside
/// the 66dp circle of the 108dp tile that no launcher's mask cuts into.
final int kLauncherTileIconBox = (kLauncherTileEdge * 66 / 108 / math.sqrt2)
    .floor();

/// Contrast against white from which a pixel stands out from it: #E6E6E6
/// and darker.
const double kStandsOutFromWhite = 1.25;

/// Share of an icon's visible pixels under which what stands out from white
/// is too little to make the icon out on white.
const double kLostOnWhiteShare = 0.1;

/// The background a tile puts behind a site icon (HS-018).
enum TilePlate {
  /// Launcher3's own background for an icon that brings none, so a tile
  /// whose icon reads on it looks as it did.
  light(r: 0xFF, g: 0xFF, b: 0xFF),
  dark(r: 0x20, g: 0x21, b: 0x24);

  const TilePlate({required this.r, required this.g, required this.b});

  final int r;
  final int g;
  final int b;
}

/// [siteIcon] (any format the `image` package decodes) centred on the
/// background [plateFor] picks, as an opaque PNG of [kLauncherTileEdge]
/// square: an adaptive icon's full bleed, so a launcher adds no background
/// of its own (HS-018). Null when [siteIcon] does not decode.
Uint8List? launcherTileIcon(Uint8List siteIcon) {
  final icon = decodeUntrustedImage(siteIcon);
  if (icon == null) return null;
  final plate = plateFor(icon);
  final color = img.ColorRgba8(plate.r, plate.g, plate.b, 0xFF);
  // Flattened before it is scaled, so the scaling blends the icon with the
  // plate and not with whatever colour its transparent pixels hold.
  final flat = img.Image(width: icon.width, height: icon.height, numChannels: 4)
    ..clear(color);
  img.compositeImage(flat, icon);
  final scale = kLauncherTileIconBox / math.max(icon.width, icon.height);
  final scaled = img.copyResize(
    flat,
    width: math.max(1, (icon.width * scale).round()),
    height: math.max(1, (icon.height * scale).round()),
    interpolation: img.Interpolation.linear,
  );
  final tile = img.Image(
    width: kLauncherTileEdge,
    height: kLauncherTileEdge,
    numChannels: 4,
  )..clear(color);
  img.compositeImage(
    tile,
    scaled,
    dstX: (kLauncherTileEdge - scaled.width) ~/ 2,
    dstY: (kLauncherTileEdge - scaled.height) ~/ 2,
    blend: img.BlendMode.direct,
  );
  return img.encodePng(tile);
}

/// The plate for [icon]: light, the launcher's own, unless the icon is lost
/// on white, which is when less than [kLostOnWhiteShare] of its visible
/// pixels stand out from white (a white logo drawn for a dark page). Only
/// those turn dark, so every icon that showed on the launcher's white wrap
/// keeps it.
TilePlate plateFor(img.Image icon) {
  var visible = 0;
  var standsOut = 0;
  for (final p in icon) {
    if (p.aNormalized < 0.5) continue;
    visible++;
    final l = _relativeLuminance(
      r: p.rNormalized,
      g: p.gNormalized,
      b: p.bNormalized,
    );
    if ((1 + 0.05) / (l + 0.05) >= kStandsOutFromWhite) standsOut++;
  }
  return visible > 0 && standsOut < visible * kLostOnWhiteShare
      ? TilePlate.dark
      : TilePlate.light;
}

double _relativeLuminance({required num r, required num g, required num b}) {
  double linear(num c) =>
      c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b);
}
