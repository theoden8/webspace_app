import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/media_session_shim.dart';

/// BGAUDIO-006: cheap structural guard on the media-session bridge shim. The
/// string is what webview.dart injects at DOCUMENT_START on background-audio
/// sites; these asserts pin the page->Dart handler name and the Dart->page
/// control entry point so a rename can't silently break the notification.
void main() {
  final shim = buildMediaSessionShim();

  test('reports playback state to the wsMediaSession handler', () {
    expect(shim, contains("callHandler('wsMediaSession'"));
    // The payload the Dart handler destructures.
    for (final key in ['playing', 'title', 'artist', 'album', 'artwork']) {
      expect(shim, contains(key), reason: 'payload key "$key" missing');
    }
  });

  test('exposes the Dart->page transport entry point', () {
    expect(shim, contains('window.__wsMediaControl'));
    expect(shim, contains(".play()"));
    expect(shim, contains(".pause()"));
  });

  test('watches dynamically added media elements', () {
    expect(shim, contains('MutationObserver'));
    expect(shim, contains('HTMLMediaElement.prototype.play'));
    expect(shim, contains("querySelectorAll('audio,video')"));
  });

  test('is idempotent (guards against double injection across frames)', () {
    expect(shim, contains('__wsMediaShim'));
  });
}
