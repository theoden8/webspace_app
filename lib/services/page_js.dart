import 'dart:convert';

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/services.dart' show rootBundle;

/// Reads one file of `lib/js/` by its path from the package root.
typedef PageJsReader = Future<String> Function(String path);

/// A script the app runs in pages, kept as `lib/js/<file>.js` so it is read,
/// checked and tested as JavaScript (`test/js/helpers/page_js.js` reads the
/// same files the same way). [load] reads every one before the first webview
/// is built; [script] and [withConfig] are synchronous after that.
///
/// A line `// @include <file>` is replaced by `lib/js/<file>`, a part shared
/// by several scripts. Parts start with `_` and include no other part.
enum PageJs {
  antiFingerprinting('anti_fingerprinting'),
  blobDownload('blob_download'),
  blobDownloadClickIntercept('blob_download_click_intercept'),
  blobUrlCapture('blob_url_capture'),
  blockJsInterceptor('block_js_interceptor'),
  blockResourceObserver('block_resource_observer'),
  cameraStream('camera_stream'),
  clearUrlShare('clearurl_share'),
  contentBlockerCosmetic('content_blocker_cosmetic'),
  contentBlockerCsp('content_blocker_csp'),
  contentBlockerEarlyCss('content_blocker_early_css'),
  defaultViewport('default_viewport'),
  desktopMode('desktop_mode'),
  doNotTrack('do_not_track'),
  expirePageCookies('expire_page_cookies'),
  genericCosmetic('generic_cosmetic'),
  htmlSnapshot('html_snapshot'),
  iconLinkWatcher('icon_link_watcher'),
  language('language'),
  locationSpoof('location_spoof'),
  mediaPause('media_pause'),
  mediaSession('media_session'),
  microphoneStream('microphone_stream'),
  notificationPolyfill('notification_polyfill'),
  pageZoomCss('page_zoom_css'),
  pageZoomViewport('page_zoom_viewport'),
  passkey('passkey'),
  passkeyBlock('passkey_block'),
  proceduralCosmetic('procedural_cosmetic'),
  screenShare('screen_share'),
  searchLinkWatcher('search_link_watcher'),
  targetBlankRewrite('target_blank_rewrite'),
  textZoom('text_zoom'),
  themeColorScheme('theme_color_scheme'),
  uaIdentity('ua_identity'),
  userScript('user_script'),
  webGlKillSwitch('webgl_kill_switch'),
  workerPayload('worker_payload'),
  workerShim('worker_shim');

  const PageJs(this.file);

  /// The file's name in [dir], without `.js`.
  final String file;

  static const dir = 'lib/js';

  static final _include =
      RegExp(r'^[ \t]*// @include (\S+)[ \t]*$', multiLine: true);
  static final _configRead = RegExp(r'\bCONFIG\.(\w+)');
  static final _sources = <PageJs, String>{};

  /// Reads every script and resolves its includes. The app reads its assets;
  /// a test passes a reader of the checkout.
  static Future<void> load({PageJsReader? read}) async {
    final reader = read ?? (path) => rootBundle.loadString(path, cache: false);
    final parts = <String, Future<String>>{};
    Future<String> part(String name) => parts[name] ??= reader('$dir/$name')
        .then((text) {
          assert(!_include.hasMatch(text), '$name: a part includes no other part');
          return text;
        });
    await Future.wait([
      for (final js in values)
        reader('$dir/${js.file}.js').then((text) async {
          final out = StringBuffer();
          var at = 0;
          for (final m in _include.allMatches(text)) {
            out
              ..write(text.substring(at, m.start))
              ..write(await part(m[1]!));
            at = m.end;
          }
          _sources[js] = (out..write(text.substring(at))).toString();
        }),
    ]);
  }

  String get _source {
    final s = _sources[this];
    assert(s != null, 'PageJs.load() runs before a page script is built');
    return s!;
  }

  Set<String> get _keysRead =>
      {for (final m in _configRead.allMatches(_source)) m[1]!};

  /// The script as it runs, for one that reads no `CONFIG`.
  String get script {
    assert(_keysRead.isEmpty, '$file.js reads CONFIG: use withConfig');
    return _source;
  }

  /// The script with [config] bound to `CONFIG`: the one way a value reaches
  /// a page script. JSON, so no value can break out of its literal.
  String withConfig(Map<String, Object?> config) {
    assert(setEquals(config.keys.toSet(), _keysRead),
        '$file.js reads CONFIG.$_keysRead, given ${config.keys}');
    return '(function (CONFIG) {\n$_source\n})(${jsonEncode(config)});\n';
  }
}
