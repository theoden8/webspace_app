import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

  bool get _enabled => Platform.isAndroid;

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
  Future<void> report({
    required String siteId,
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
      _ownerRunJs = runJs;
      final artwork = await _fetchArtwork(artworkUrl);
      await _invoke(_active ? 'update' : 'start', {
        'title': title,
        'artist': artist,
        'album': album,
        'playing': true,
        'artwork': artwork,
      });
      _active = true;
    } else {
      // Only the owner may drive the notification to a paused state; a
      // background site reporting "not playing" must not clobber the site
      // the user is actually listening to.
      if (!_active || _ownerSiteId != siteId) return;
      _ownerRunJs = runJs;
      await _invoke('update', {
        'title': title,
        'artist': artist,
        'album': album,
        'playing': false,
        'artwork': null,
      });
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

  Future<void> _stop() async {
    _active = false;
    _ownerSiteId = null;
    _ownerRunJs = null;
    await _invoke('stop', null);
  }

  Future<void> _invoke(String method, Map<String, Object?>? args) async {
    try {
      await _channel.invokeMethod(method, args);
    } on PlatformException catch (e) {
      LogService.instance.log(
        'MediaSession',
        '$method failed: ${e.message}',
        level: LogLevel.warning,
      );
    } on MissingPluginException {
      // Native side not present (older build); harmless.
    }
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
