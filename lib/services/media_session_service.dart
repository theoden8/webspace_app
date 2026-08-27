import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/settings/proxy.dart';

/// BGAUDIO-006 Dart bridge to the native media session. A background-audio
/// site's page-JS reports its playback state here (via the `wsMediaSession`
/// handler wired in `webview.dart`); this service raises/refreshes/tears down
/// the OS media surface and routes transport controls back to the owning
/// webview's JS.
///
/// Two native implementations behind one channel: Android's `mediaPlayback`
/// foreground service + `MediaStyle` notification (`MediaSessionPlugin.kt` /
/// `MediaPlaybackService.kt`), and iOS's Now Playing info + remote command
/// centre (`MediaSessionPlugin.swift`, BGAUDIO-010). Leaving iOS to WebKit's
/// own Now Playing handling meant nothing in the app knew the controls were
/// up, and a transport tap had no route back into the page.
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

  bool get _enabled =>
      debugEnabledOverride ?? (hostIsAndroid || hostIsIOS);

  /// Whether this platform has a native media session behind the channel.
  /// Read by `webview.dart` to gate the shim + handler injection, so the
  /// bridge is armed exactly where something consumes its reports.
  bool get isSupported => _enabled;

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
      if (call.method == 'onSessionState') {
        // Non-sensitive audio-session state from the native side (BGAUDIO-011).
        // "The audio stopped in the background" has several candidate causes
        // that look identical from Dart; the session's category and active
        // state at that moment separate them, and this puts them in the App
        // Logs export the user can actually send.
        final args = call.arguments;
        final message = (args is Map ? args['message'] : null) as String? ?? '';
        if (message.isNotEmpty) {
          LogService.instance.log('MediaSession', 'Audio session: $message');
        }
        return null;
      }
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
    UserProxySettings? proxy,
  }) async {
    if (!_enabled) return;
    if (playing) {
      _ownerSiteId = siteId;
      _ownerFrame = frame;
      _ownerRunJs = runJs;
      final artwork = await _fetchArtwork(artworkUrl, proxy);
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

  /// A transport control the page could not act on (BGAUDIO-007). Reported by
  /// the shim only on failure, and logged non-sensitively (no site name, URL or
  /// track metadata): "I hit play and nothing happened" is otherwise silent at
  /// every layer, and the engine's own reason — a rejected `play()` promise, or
  /// no element left to drive — is the one fact that separates a dead bridge
  /// from a refusal.
  Future<void> reportControlFailure({
    required String action,
    required String error,
  }) async {
    if (!_enabled) return;
    LogService.instance.log(
      'MediaSession',
      'Transport "$action" did not reach playback: $error',
      level: LogLevel.warning,
    );
  }

  /// Clear whatever media surface the OS shows for this app, including one we
  /// never raised. On iOS WebKit publishes its own Now Playing info for any
  /// page that plays audio, so a site WITHOUT the background-audio toggle can
  /// leave transport controls behind after its media is stopped — controls
  /// whose buttons reach a site the app is no longer keeping alive. Called
  /// when no background-audio site is loaded (BGAUDIO-009/010).
  Future<void> clearOsMediaSurface() async {
    if (!_enabled) return;
    if (_active) {
      _active = false;
      _ownerSiteId = null;
      _ownerRunJs = null;
      _ownerFrame = null;
      _visibilityChecked = false;
      LogService.instance.log('MediaSession', 'Notification torn down');
    }
    // `deactivate`: with nothing of ours left playing, giving the audio
    // session up is what actually drops the app out of the OS media surface —
    // clearing the metadata alone leaves an entry the engine can repopulate.
    // Ignored by the Android side, which owns its notification outright.
    await _invoke('stop', {'deactivate': true});
    // WebKit republishes its own Now Playing info when it finishes processing
    // the pause that preceded this, which can land after the first clear.
    await Future<void>.delayed(debugSurfaceReclearDelay);
    await _invoke('stop', {'deactivate': true});
  }

  /// How long to wait before the second clear. Short enough to run inside the
  /// window a backgrounding app still gets.
  @visibleForTesting
  static Duration debugSurfaceReclearDelay = const Duration(milliseconds: 400);

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
  ///
  /// The URL comes from page JS and the shim runs in every frame, so this is an
  /// attacker-reachable outbound request: it goes through the site's proxy
  /// (LEAK-002) and fails closed when that proxy cannot be honored, and it
  /// refuses loopback / private / link-local literals so a page cannot use it
  /// to probe the LAN or cloud metadata.
  Future<Uint8List?> _fetchArtwork(String url, UserProxySettings? proxy) async {
    if (url.isEmpty) return null;
    final uri = Uri.tryParse(url);
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
      return null;
    }
    if (_isPrivateOrLoopbackHost(uri.host.toLowerCase())) return null;
    final result = outboundHttp.clientFor(
        resolveEffectiveProxy(proxy ?? UserProxySettings(type: ProxyType.DEFAULT)));
    if (result is OutboundClientBlocked) {
      LogService.instance.log(
        'MediaSession',
        'Artwork fetch skipped: ${result.reason}',
        level: LogLevel.warning,
      );
      return null;
    }
    final client = (result as OutboundClientReady).client;
    const cap = 1536 * 1024; // 1.5 MB
    const timeout = Duration(seconds: 5);
    try {
      final response = await client.get(uri).timeout(timeout);
      if (response.statusCode != 200) return null;
      if (response.bodyBytes.length > cap) return null;
      return response.bodyBytes;
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }
}

/// True if [host] is a loopback, private (RFC1918), unique-local, or
/// link-local literal address (IPv4 or IPv6), or the `localhost` name.
bool _isPrivateOrLoopbackHost(String host) {
  if (host == 'localhost' || host.endsWith('.localhost')) return true;

  // IPv6 literal (Uri.host strips the surrounding brackets).
  if (host.contains(':')) {
    final h = host.split('%').first; // drop any zone id
    if (h == '::1' || h == '::') return true;
    // fc00::/7 unique-local, fe80::/10 link-local.
    if (h.startsWith('fc') || h.startsWith('fd')) return true;
    if (h.startsWith('fe8') ||
        h.startsWith('fe9') ||
        h.startsWith('fea') ||
        h.startsWith('feb')) {
      return true;
    }
    return false;
  }

  // IPv4 dotted-quad.
  final parts = host.split('.');
  if (parts.length == 4) {
    final octets = <int>[];
    for (final p in parts) {
      final v = int.tryParse(p);
      if (v == null || v < 0 || v > 255) return false; // not an IPv4 literal
      octets.add(v);
    }
    final a = octets[0], b = octets[1];
    if (a == 0) return true; // 0.0.0.0/8
    if (a == 127) return true; // loopback
    if (a == 10) return true; // private
    if (a == 172 && b >= 16 && b <= 31) return true; // private
    if (a == 192 && b == 168) return true; // private
    if (a == 169 && b == 254) return true; // link-local + cloud metadata
  }
  return false;
}
