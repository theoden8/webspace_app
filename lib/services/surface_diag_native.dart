import 'package:webspace/platform/host_platform.dart';

import 'package:flutter/services.dart';

/// Verdict over a sampled window region.
///
/// [uniformBlank] is BUG-001's symptom: the region the user sees is a flat
/// white (fresh SurfaceView default fill) or black (re-attached surface)
/// rectangle. A uniform region in any *other* color is [content]: a page
/// legitimately painted a solid background, which no blank surface produces.
enum WindowSampleVerdict { unavailable, uniformBlank, content }

/// One window-level pixel sample. [status] is `ok` when the histogram ran;
/// any other value (`unsupported`, `no-window`, `bad-region`, `no-surface`,
/// `copy-failed:N`) means the composited pixels could not be read this time.
class WindowRegionSample {
  final String status;
  final int? dominantColor;
  final double? uniformFraction;

  const WindowRegionSample({
    required this.status,
    this.dominantColor,
    this.uniformFraction,
  });

  static const unsupported = WindowRegionSample(status: 'unsupported');

  bool get ok => status == 'ok';

  @override
  String toString() {
    final color = dominantColor == null
        ? 'null'
        : '0x${dominantColor!.toRadixString(16).padLeft(8, '0')}';
    final fraction = uniformFraction?.toStringAsFixed(3) ?? 'null';
    return 'WindowRegionSample(status=$status dominant=$color uniform=$fraction)';
  }
}

/// Bridge to the Android window-pixel sampler ([SurfaceDiagPlugin.kt]).
///
/// The webview's hybrid-composition SurfaceView is composited by the OS,
/// invisible to both the JS probe (renderer plane) and Flutter-side capture
/// (raster tree without platform views). Window-level PixelCopy is the only
/// signal that measures what the user actually sees, so it is the only way
/// to *detect* the BUG-001 blank rather than infer it from a trigger path.
class SurfaceDiagNative {
  static const _channel =
      MethodChannel('org.codeberg.theoden8.webspace/surface_diag');

  /// Sample the composited window over [physicalRect] (physical pixels,
  /// window coordinates). Non-Android platforms report [WindowRegionSample.unsupported]:
  /// iOS's blank class is renderer jettison, which the JS probe already
  /// detects, and the Flutter window there composites platform views in-tree.
  static Future<WindowRegionSample> sampleWindowRegion(Rect physicalRect) async {
    if (!hostIsAndroid) return WindowRegionSample.unsupported;
    try {
      final res = await _channel
          .invokeMapMethod<String, dynamic>('sampleWindowRegion', <String, int>{
        'left': physicalRect.left.round(),
        'top': physicalRect.top.round(),
        'width': physicalRect.width.round(),
        'height': physicalRect.height.round(),
      });
      if (res == null) return WindowRegionSample.unsupported;
      // Kotlin sends a signed 32-bit ARGB int; normalize to unsigned so
      // 0xFF123524 stays 0xFF123524 on the Dart side.
      final rawColor = res['dominantColor'] as int?;
      return WindowRegionSample(
        status: res['status'] as String? ?? 'unsupported',
        dominantColor: rawColor == null ? null : rawColor & 0xFFFFFFFF,
        uniformFraction: (res['uniformFraction'] as num?)?.toDouble(),
      );
    } on MissingPluginException {
      return WindowRegionSample.unsupported;
    } on PlatformException {
      return WindowRegionSample.unsupported;
    }
  }

  /// Map a logical-coordinate region to the physical-pixel window rect the
  /// sampler needs. [insetLogical] shrinks the region on all sides so
  /// borders, scrollbar gutters, and the pull-to-refresh edge glow don't
  /// dilute the histogram.
  static Rect physicalRect({
    required Rect logicalRect,
    required double devicePixelRatio,
    double insetLogical = 0,
  }) {
    final inset = logicalRect.deflate(insetLogical);
    return Rect.fromLTRB(
      inset.left * devicePixelRatio,
      inset.top * devicePixelRatio,
      inset.right * devicePixelRatio,
      inset.bottom * devicePixelRatio,
    );
  }

  /// Pure classification of one sample. A verdict of [WindowSampleVerdict.uniformBlank]
  /// means the region is (nearly) all one color AND that color is near-white
  /// or near-black, the two fills a blank surface can show. Thresholds are
  /// lenient on the uniform fraction because compositor dithering fragments
  /// the histogram bucket at quantization boundaries.
  static WindowSampleVerdict classify(
    WindowRegionSample sample, {
    double uniformThreshold = 0.98,
  }) {
    final color = sample.dominantColor;
    final fraction = sample.uniformFraction;
    if (!sample.ok || color == null || fraction == null) {
      return WindowSampleVerdict.unavailable;
    }
    if (fraction < uniformThreshold) return WindowSampleVerdict.content;
    final r = (color >> 16) & 0xFF;
    final g = (color >> 8) & 0xFF;
    final b = color & 0xFF;
    final luma = 0.299 * r + 0.587 * g + 0.114 * b;
    if (luma >= 243 || luma <= 12) return WindowSampleVerdict.uniformBlank;
    return WindowSampleVerdict.content;
  }
}
