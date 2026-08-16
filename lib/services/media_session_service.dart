import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:webspace/services/log_service.dart';

/// BGAUDIO-006 Dart bridge to the Android foreground media service
/// (`MediaSessionPlugin.kt` / `MediaPlaybackService.kt`). A background-audio
/// site's page-JS reports its playback state here (via the `wsMediaSession`
/// handler wired in `webview.dart`); this service raises/refreshes/tears down
/// the media notification and routes transport controls back to the owning
/// webview's JS.
///
/// Android-only. iOS relies on its `.playback` AVAudioSession + the system
/// Now Playing UI, which the page's own MediaSession populates.
class MediaSessionService {
  static final MediaSessionService instance = MediaSessionService._();
  MediaSessionService._();

  static const _channel =
      MethodChannel('org.codeberg.theoden8.webspace/media_session');

  bool _initialized = false;
  bool _active = false;

  /// Site whose playback currently owns the notification, and the closure that
  /// runs JS on its webview. Updated on every "playing" report so a transport
  /// tap drives the right page.
  String? _ownerSiteId;
  Future<void> Function(String js)? _ownerRunJs;

  /// Frame token (from the shim) that last reported playback. The shim runs in
  /// every frame of the site and they all share one handler, so the site id
  /// alone cannot tell the playing frame from a sibling iframe (BGAUDIO-008).
  String? _ownerFrame;

  /// Set once per activation so the "raised but nothing on screen" warning
  /// (usually a denied `POST_NOTIFICATIONS`) is logged once, not per report.
  bool _visibilityChecked = false;

  /// Test seam: the Android gate is a compile-time platform check, which a
  /// host-run unit test cannot satisfy.
  @visibleForTesting
  static bool? debugEnabledOverride;

  bool get _enabled => debugEnabledOverride ?? Platform.isAndroid;

  /// Whether the notification is currently raised as far as Dart knows.
  /// [notificationPosted] is the authority on whether the OS actually shows it.
  bool get isActive => _active;

  /// How long after raising the notification to ask the OS whether it is
  /// actually on screen. One second covers `startForegroundService` plus the
  /// service's first `startForeground`.
  @visibleForTesting
  static Duration debugVisibilityCheckDelay = const Duration(seconds: 1);

  /// Return the singleton to its cold state between tests, including the
  /// `initialize()` latch so the transport handler can be re-bound.
  @visibleForTesting
  void debugReset() {
    _initialized = false;
    _active = false;
    _ownerSiteId = null;
    _ownerRunJs = null;
    _ownerFrame = null;
    _visibilityChecked = false;
  }

  void initialize() {
    if (_initialized) return;
    _initialized = true;
    if (!_enabled) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onTransport') {
        final args = call.arguments;
        final action = (args is Map ? args['action'] : null) as String? ?? '';
        if (action.isEmpty) return null;
        final runJs = _ownerRunJs;
        if (runJs != null) {
          await runJs(
              'if(window.__wsMediaControl)window.__wsMediaControl(${jsonEncode(action)});');
        }
      }
      return null;
    });
  }

  /// Called from the `wsMediaSession` JS handler for a background-audio site.
  ///
  /// [frame] is the reporting frame's token; the shim mints one per frame so a
  /// sibling iframe cannot speak for the frame that is actually playing.
  Future<void> report({
    required String siteId,
    required String frame,
    required Future<void> Function(String js) runJs,
    required bool playing,
    required String title,
    required String artist,
    required String album,
    required String artworkUrl,
  }) async {
    if (!_enabled) return;
    if (playing) {
      _ownerSiteId = siteId;
      _ownerFrame = frame;
      _ownerRunJs = runJs;
      final artwork = await _fetchArtwork(artworkUrl);
      final raising = !_active;
      await _invoke(raising ? 'start' : 'update', {
        'title': title,
        'artist': artist,
        'album': album,
        'playing': true,
        'artwork': artwork,
      });
      _active = true;
      if (raising) {
        // Non-sensitive: no site name, URL or track metadata. BGAUDIO-006's
        // observable — the line the integration test and a user bug report
        // both read to tell "the service was asked" from "nothing happened".
        LogService.instance.log('MediaSession', 'Notification raised');
        unawaited(_verifyVisible());
      }
    } else {
      // Only the owning frame of the owning site may drive the notification to
      // a paused state. A background site going quiet must not clobber the one
      // the user is listening to, and neither must an ad iframe of the very
      // site that is playing (BGAUDIO-008).
      if (!_active || _ownerSiteId != siteId || _ownerFrame != frame) return;
      _ownerRunJs = runJs;
      await _invoke('update', {
        'title': title,
        'artist': artist,
        'album': album,
        'playing': false,
        'artwork': null,
      });
      LogService.instance.log('MediaSession', 'Playback paused by the page');
    }
  }

  /// Tear the notification down when [siteId] owns it. Called when the site is
  /// unloaded/disposed or its background-audio toggle goes off.
  Future<void> stopForSite(String siteId) async {
    if (!_enabled) return;
    if (!_active || _ownerSiteId != siteId) return;
    await _stop();
  }

  /// Unconditional teardown — used when no background-audio site remains loaded.
  Future<void> stopAll() async {
    if (!_enabled || !_active) return;
    await _stop();
  }

  /// Whether the OS currently shows the media notification. Distinct from
  /// [isActive]: the foreground service can be running while the notification
  /// is suppressed, which is what a denied `POST_NOTIFICATIONS` looks like.
  Future<bool> notificationPosted() async {
    if (!_enabled) return false;
    final result = await _invoke('isNotificationActive', null);
    return result == true;
  }

  /// A raised notification the OS never posted is invisible to the user and
  /// silent in the logs — the exact shape of a denied notification permission.
  /// Give it a line so a bug report says which of the two happened.
  Future<void> _verifyVisible() async {
    if (_visibilityChecked) return;
    _visibilityChecked = true;
    await Future<void>.delayed(debugVisibilityCheckDelay);
    if (!_active) return;
    if (await notificationPosted()) return;
    LogService.instance.log(
      'MediaSession',
      'Notification raised but not posted by the OS — notification permission '
          'is likely denied; media controls will not be visible',
      level: LogLevel.warning,
    );
  }

  Future<void> _stop() async {
    _active = false;
    _ownerSiteId = null;
    _ownerRunJs = null;
    _ownerFrame = null;
    _visibilityChecked = false;
    await _invoke('stop', null);
    LogService.instance.log('MediaSession', 'Notification torn down');
  }

  Future<Object?> _invoke(String method, Map<String, Object?>? args) async {
    try {
      return await _channel.invokeMethod<Object?>(method, args);
    } on PlatformException catch (e) {
      LogService.instance.log(
        'MediaSession',
        '$method failed: ${e.message}',
        level: LogLevel.warning,
      );
    } on MissingPluginException {
      // Native side not present (older build); harmless.
    }
    return null;
  }

  /// Best-effort artwork fetch: the page's own declared artwork URL, capped and
  /// timed out. Decoding/scaling happens natively. Null on anything unexpected.
  Future<Uint8List?> _fetchArtwork(String url) async {
    if (url.isEmpty) return null;
    final uri = Uri.tryParse(url);
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
      return null;
    }
    HttpClient? client;
    try {
      client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
      final req = await client.getUrl(uri).timeout(const Duration(seconds: 5));
      final resp = await req.close().timeout(const Duration(seconds: 5));
      if (resp.statusCode != 200) return null;
      const cap = 1536 * 1024; // 1.5 MB
      final builder = BytesBuilder(copy: false);
      await for (final chunk in resp.timeout(const Duration(seconds: 5))) {
        builder.add(chunk);
        if (builder.length > cap) return null;
      }
      return builder.takeBytes();
    } catch (_) {
      return null;
    } finally {
      client?.close(force: true);
    }
  }
}
