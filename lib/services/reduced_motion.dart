import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/channel_reply.dart';
import 'package:webspace/services/log_service.dart';

/// Whether the OS asks for reduced motion (A11Y-011): Android's Remove
/// animations and GNOME's animations off reach Flutter as `disableAnimations`,
/// iOS's Reduce Motion as `reduceMotion` alone, and the Mac's reaches it not
/// at all, so it is asked of the runner's `reduced_motion` channel and
/// followed there.
class ReducedMotion extends ChangeNotifier with WidgetsBindingObserver {
  ReducedMotion({bool? onMac, MethodChannel? channel})
      : _onMac = onMac ?? hostIsMacOS,
        _channel = channel ?? _defaultChannel;

  static final instance = ReducedMotion();

  static const _defaultChannel =
      MethodChannel('org.codeberg.theoden8.webspace/reduced_motion');

  final bool _onMac;
  final MethodChannel _channel;
  ui.PlatformDispatcher _dispatcher = ui.PlatformDispatcher.instance;
  bool _started = false;
  bool _mac = false;

  /// Whether motion is reduced now, for code that builds no widget (a
  /// webview's native settings).
  bool get reduced => reducedMotion(
        disableAnimations: _dispatcher.accessibilityFeatures.disableAnimations,
        reduceMotion: _dispatcher.accessibilityFeatures.reduceMotion,
        macReduceMotion: _mac,
      );

  /// Whether motion is reduced where [context] is, rebuilding it when any
  /// source changes under a [ReducedMotionScope]. A test's bare widget has
  /// none above it and follows its [MediaQuery] alone.
  static bool of(BuildContext context) {
    final motion =
        context.dependOnInheritedWidgetOfExactType<ReducedMotionScope>()
                ?.notifier ??
            instance;
    return reducedMotion(
      disableAnimations: MediaQuery.maybeDisableAnimationsOf(context) ??
          motion._dispatcher.accessibilityFeatures.disableAnimations,
      reduceMotion: motion._dispatcher.accessibilityFeatures.reduceMotion,
      macReduceMotion: motion._mac,
    );
  }

  /// [full], or none while motion is reduced where [context] is.
  static Duration duration(BuildContext context, {required Duration full}) =>
      of(context) ? Duration.zero : full;

  /// Follows the binding's flags, and on the Mac reads the runner's answer
  /// and follows its changes.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    final binding = WidgetsBinding.instance;
    _dispatcher = binding.platformDispatcher;
    binding.addObserver(this);
    if (!_onMac) return;
    _channel.setMethodCallHandler((call) async {
      if ((call.method, call.arguments) case ('changed', final bool on)) {
        _setMac(to: on);
      }
    });
    switch (await _channel.ask<bool>('reduceMotion')) {
      case Answered(:final value):
        _setMac(to: value ?? false);
      case PlatformRefused(:final error):
        LogTag.startup.error('Reduced motion: ${error.code}');
      case NoPlugin():
        // An engine without the window's channels, as a test's.
        break;
    }
  }

  void _setMac({required bool to}) {
    if (to == _mac) return;
    _mac = to;
    notifyListeners();
  }

  @override
  void didChangeAccessibilityFeatures() => notifyListeners();
}

/// Motion is reduced when any platform's signal says so.
bool reducedMotion({
  required bool disableAnimations,
  required bool reduceMotion,
  required bool macReduceMotion,
}) =>
    disableAnimations || reduceMotion || macReduceMotion;

/// Rebuilds what reads [ReducedMotion.of] below it when the answer changes.
class ReducedMotionScope extends InheritedNotifier<ReducedMotion> {
  ReducedMotionScope({super.key, ReducedMotion? motion, required super.child})
      : super(notifier: motion ?? ReducedMotion.instance);
}
