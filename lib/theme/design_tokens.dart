// Shared design values. Edit here, not in the widgets: both the app and the
// design gallery (tool/design_gallery/) read these, so a change shows up in
// the app and in the gallery's cards at once.
//
// A value earns a token when more than one widget needs it, or when the number
// is a design decision rather than an implementation detail. One-off geometry
// that only makes sense inside a single widget stays where it is.
//
// Colours that follow the user's accent live in accent_theme.dart; the ones
// here are the fixed chrome that does not.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:webspace/utils/stable_palette.dart';
import 'package:webspace/webspace_model.dart';

/// Corner radii, smallest to largest. A neutral scale rather than semantic
/// names: the existing 22 call sites do not agree on what each step means, so
/// naming them by role would be inventing intent.
abstract final class Radii {
  static const double xs = 2;
  static const double sm = 4;
  static const double md = 6;
  static const double lg = 8;
  static const double xl = 12;

  /// Every radius the app uses, for the gallery's scale card.
  static const List<double> scale = [xs, sm, md, lg, xl];
}

abstract final class Spacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
}

/// Appearance of settings that inherit an app default.
abstract final class SettingStyle {
  static const double inheritedOpacity = 0.72;
}

/// The site launcher's surfaces and geometry, shared by groups and sites.
abstract final class LibraryStyle {
  static const light = Color(0xFFFBFCFE);
  static const dark = Color(0xFF171B22);
  static const fieldLight = Color(0xFFF0F3F8);
  static const fieldDark = Color(0xFF252C36);
  static const groupLight = [
    Color(0xFFEAF0F6),
    Color(0xFFE5EFFF),
    Color(0xFFE8F3EC),
    Color(0xFFEEEFF2),
  ];
  static const groupDark = [
    Color(0xFF2B3441),
    Color(0xFF263B58),
    Color(0xFF293F37),
    Color(0xFF363440),
  ];
  static const double radius = 20;
  static const double selectionWidth = 2;
  static const int siteTintAlpha = 26;
  static const int membershipLimit = 2;
  static const double maxWidth = 1440;
  static const int maxColumns = 8;
  static const double tileMinWidth = 112;

  /// The narrowest column an icon keeps its full caption in, wider as the
  /// text grows; Grid lays icons out no narrower.
  static double iconColumnMin(TextScaler scaler) =>
      tileMinWidth * math.max(1, scaler.scale(1) * .7);
  static const double siteIcon = 64;
  static const double siteWell = 80;
  static const double previewIcon = 24;
  static const double titleSize = 30;
  static const double logoSize = 36;
  static const double siteTitleSize = 14;

  /// An open group: a panel over the dimmed grid, as a phone opens a folder.
  static const double panelMaxWidth = 880;
  static const double panelRadius = 32;
  static const double scrimOpacity = .32;
  static const double scrimBlur = 12;
  static const panelLight = Color(0xFFFFFFFF);
  static const panelDark = Color(0xFF222833);

  /// An open folder pulled down by its top bar: the share of its height that
  /// closes it when let go, the downward fling that closes it from anywhere
  /// (logical pixels a second), and how much it shrinks as it goes.
  static const double pullToClose = .25;
  static const double pullFling = 700;
  static const double pullShrink = .1;

  /// Whether a pull let go [pulled] down a surface [extent] tall, moving at
  /// [velocity], closes it: flung down, or let go past [pullToClose] of it
  /// and not flung back up. An open folder and a site's held card both close
  /// by it.
  static bool pullCloses({
    required double pulled,
    required double extent,
    required double velocity,
  }) =>
      velocity > pullFling ||
      (velocity > -pullFling && pulled > extent * pullToClose);

  /// A site's card held by its top bar (WEBSPACE-008): the size it lifts to,
  /// how much more of it a pull down the whole screen takes away, and the
  /// corners it has once lifted.
  static const double cardLift = .94;
  static const double cardPullShrink = .6;
  static const double cardRadius = 32;

  /// The open folder's page dots: the row under its pages, and one dot.
  static const double pageDots = 28;
  static const double pageDot = 6;

  /// A folder's sites as rows (WEBSPACE-015): a row's icon well and its
  /// name's size; a tile turning into a row loses its name under the icon
  /// early in the way and gains the row's late.
  static const double rowWell = 44;
  static const double rowTitleSize = 15;
  static const Curve gridCaptionOut = Interval(0, .4, curve: Curves.easeOut);
  static const Curve rowCaptionIn = Interval(.5, 1, curve: Curves.easeOut);

  /// A webspace's glyph beside its name, against the name's font size.
  static const double glyphScale = 1.15;

  /// The narrowest a row may be before rows flow into fewer columns.
  static const double rowMinWidth = 360;

  /// Automatic layout, as the drawer packs its sites: the narrowest a row
  /// may be once rows take more columns to hold every item, and the most
  /// columns it takes before the items scroll, as the drawer's four.
  static const double packedRowMinWidth = 150;
  static const int packedColumns = 4;

  /// An icon's well in a column [width] wide: its full size, or smaller
  /// where Automatic layout packs icons into narrower columns.
  static double wellFor({required double width}) =>
      (width - Spacing.lg).clamp(0, siteWell);

  /// The switch between a level's layouts: each of its segments, and the
  /// track around them.
  static const Size layoutSwitchSegment = Size(32, 28);
  static const double layoutSwitchInset = 2;

  /// An icon held down, lifted, and the gap it leaves while dragged.
  static const double pressScale = .94;
  static const double liftScale = 1.08;
  static const double dragGhost = .3;

  static Color background(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;

  static Color field(Brightness brightness) =>
      brightness == Brightness.dark ? fieldDark : fieldLight;

  static Color panel(Brightness brightness) =>
      brightness == Brightness.dark ? panelDark : panelLight;

  static Color group(Brightness brightness, {required WebspaceId id}) {
    final palette = brightness == Brightness.dark ? groupDark : groupLight;
    return palette[stablePaletteIndex(id, paletteSize: palette.length)];
  }
}

/// The outline around whatever has focus where a TV remote drives the device
/// (NAV-016): a tint made for a keyboard at arm's length does not carry across
/// a room.
abstract final class RemoteStyle {
  static const double ringWidth = 3;

  /// The line inside the ring, in the surface colour, so the ring still reads
  /// on a control filled with the accent.
  static const double ringInner = 1;
  static const double ringRadius = Radii.xl;
}

/// Fixed chrome around web content: not accent-derived, so these stay put when
/// the user picks a different accent colour.
abstract final class Chrome {
  static const Color barLight = Color(0xFFF5F5F5);
  static const Color barDark = Color(0xFF1E1E1E);
  static const Color hairlineLight = Color(0xFFE0E0E0);
  static const Color hairlineDark = Color(0xFF3E3E3E);
  static const double hairlineWidth = 0.5;

  /// A chip that is not selected, on the dark bar; white on the light one.
  static const Color chipDark = Color(0xFF2A2A2A);

  static Color bar({required bool isDark}) => isDark ? barDark : barLight;
  static Color chip({required bool isDark}) => isDark ? chipDark : Colors.white;
  static Color hairline({required bool isDark}) =>
      isDark ? hairlineDark : hairlineLight;
}

/// The padlock in the URL bar. Green only for https; anything else reads as
/// not-secure rather than as an error.
///
/// Shade 700/600 rather than the plain Material colours: the same padlock is
/// drawn on both chrome bars, and `Colors.green`/`Colors.grey` sit at 2.55:1
/// and 2.46:1 on the light one, under the 3:1 that a meaningful non-text
/// indicator needs. These clear it on both.
abstract final class SecurityIndicator {
  static const Color secure = Color(0xFF388E3C);
  static const Color insecure = Color(0xFF757575);
}

abstract final class IconSizes {
  /// Inline with body text (the URL bar padlock).
  static const double inline = 16;

  /// Tappable icon in a row or app bar.
  static const double action = 20;

  /// Icon inside a floating circular button.
  static const double floating = 22;
}

abstract final class TapTargets {
  /// Floor for a compact icon button that still has to be hittable.
  static const double compact = 32;
}

abstract final class Motion {
  /// A group or a site growing out of its icon, as a launcher opens one.
  static const Duration launch = Duration(milliseconds: 360);

  /// The same shrinking back into its icon, a little quicker, as leaving is.
  static const Duration launchBack = Duration(milliseconds: 300);

  /// Quick out of the icon and a soft landing at full size; flipped for the
  /// way back, so the icon is landed on as softly.
  static const Curve launchCurve = Easing.emphasizedDecelerate;

  /// A site's card fading off the site once it is on screen.
  static const Duration reveal = Duration(milliseconds: 180);

  /// The longest a site's card waits over the screen for the switch under
  /// it before it moves on regardless.
  static const Duration launchHold = Duration(milliseconds: 800);

  /// An icon held down rising under the finger.
  static const Duration lift = Duration(milliseconds: 180);

  /// Press / release feedback. Short enough to feel attached to the finger.
  static const Duration press = Duration(milliseconds: 100);

  /// One step of a list scrolling itself while something is dragged at its
  /// edge.
  static const Duration autoScrollTick = Duration(milliseconds: 16);

  /// A released control gliding to where it rests.
  static const Duration settle = Duration(milliseconds: 250);

  /// A folder's sites turning from a grid into rows and back.
  static const Duration layoutMorph = Duration(milliseconds: 420);
  static const Curve layoutCurve = Curves.easeInOutCubicEmphasized;

  /// How far into a swipe between folder pages the panel takes the next
  /// page's size: late, so the page in view keeps its size while it goes.
  static const Curve folderPageResize = Interval(
    .6,
    1,
    curve: Curves.easeInOut,
  );
}

abstract final class Elevations {
  static const double floating = 3;
  static const double floatingActive = 8;
}

/// The tab-strip button floats over site content, so it is translucent enough
/// to show what it covers and grows while dragged.
abstract final class FloatingButton {
  static const double surfaceOpacity = 0.85;
  static const double padding = 10;
  static const double dragScale = 1.2;
}

/// Rows of the tab list (TAB-011).
abstract final class TabRows {
  /// A tab that holds no webview is drawn at this strength, as a browser
  /// fades an unloaded tab.
  static const double unloadedOpacity = 0.5;

  /// The row being dragged, left in place (TAB-015).
  static const double draggingOpacity = 0.3;

  /// The line that shows where a dragged tab will land.
  static const double dropLineWidth = 2;

  /// How close to the list's top or bottom a drag starts scrolling it, and
  /// how far one step scrolls.
  static const double autoScrollEdge = 48;
  static const double autoScrollStep = 8;
}

/// One colour per container (TAB-018): a tab row is marked with the colour of
/// the container it runs in, so which container a tab uses is never a guess.
/// Two sets, the same hues in order, each holding 3:1 against the surfaces of
/// its brightness so the mark reads as a graphic.
abstract final class ContainerColors {
  /// Blue, turquoise, green, yellow, orange, red, pink, purple.
  static const List<Color> light = [
    Color(0xFF1565C0),
    Color(0xFF00838F),
    Color(0xFF2E7D32),
    Color(0xFF8D6E00),
    Color(0xFFE65100),
    Color(0xFFC62828),
    Color(0xFFAD1457),
    Color(0xFF6A1B9A),
  ];

  static const List<Color> dark = [
    Color(0xFF64B5F6),
    Color(0xFF4DD0E1),
    Color(0xFF81C784),
    Color(0xFFFFD54F),
    Color(0xFFFFB74D),
    Color(0xFFE57373),
    Color(0xFFF06292),
    Color(0xFFBA68C8),
  ];

  /// The bar at the start of a tab row.
  static const double markWidth = 3;

  static Color of(int index, {required Brightness brightness}) {
    final set = brightness == Brightness.dark ? dark : light;
    return set[index % set.length];
  }
}

abstract final class TextSizes {
  /// The URL bar's editable text.
  static const double url = 14;
}
