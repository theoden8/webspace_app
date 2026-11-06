import 'package:webspace/settings/shim_frames.dart';

export 'package:webspace/settings/shim_frames.dart';

/// When in a document a page shim runs.
enum ShimTime { start, end }

/// Every script the app installs into a site's documents, under the group
/// name the platform keeps it by, with the frames it reaches and when it
/// runs. A shim's reach is a property of the shim, decided here once: a
/// location or fingerprinting shim that missed a cross-origin frame would
/// leave that frame the real values, and a screen share that reached one
/// would hand a third party the surface (SHARE-005).
///
/// A group is installed when its webview is built, in the order declared
/// here (`PageScripts.buildPageScripts`), so every document it runs in has it
/// from before the page's own first script; only a [LiveShim] is replaced on
/// a live view.
enum ShimGroup {
  webglKillSwitch('webgl_kill_switch', frames: ShimFrames.all),
  doNotTrack('do_not_track', frames: ShimFrames.all),
  cameraStream('camera_stream', frames: ShimFrames.all),
  microphoneStream('microphone_stream', frames: ShimFrames.all),
  screenShare('screen_share', frames: ShimFrames.top),
  passkey('passkey', frames: ShimFrames.all),

  /// WebKit answers a same-origin subframe too (PASSKEY-013).
  passkeyBlock('passkey_block', frames: ShimFrames.all),
  targetBlankRewrite('target_blank_rewrite', frames: ShimFrames.all),
  antiFingerprinting('anti_fingerprinting', frames: ShimFrames.all),
  blobUrlCapture('blob_url_capture', frames: ShimFrames.top),
  blobDownloadClickIntercept('blob_download_click_intercept',
      frames: ShimFrames.top),
  desktopMode('desktop_mode_shim', frames: ShimFrames.all),
  uaIdentity('ua_identity_shim', frames: ShimFrames.all),
  defaultViewport('default_viewport', frames: ShimFrames.top),
  systemTextZoom('system_text_zoom', frames: ShimFrames.all),
  pageZoom('page_zoom', frames: ShimFrames.all),
  notificationPolyfill('notification_polyfill', frames: ShimFrames.all),
  mediaSession('media_session_shim', frames: ShimFrames.all),
  locationSpoof('location_spoof', frames: ShimFrames.all),
  contentBlockerEarlyCss('content_blocker_early_css', frames: ShimFrames.top),
  contentBlockerCsp('content_blocker_csp', frames: ShimFrames.top),
  genericCosmetic('generic_cosmetic',
      frames: ShimFrames.top, at: ShimTime.end),
  proceduralCosmetic('procedural_cosmetic',
      frames: ShimFrames.top, at: ShimTime.end),
  clearUrlShare('clearurl_share', frames: ShimFrames.all),
  languageOverride('language_override', frames: ShimFrames.all),
  themeColorScheme('theme_color_scheme_shim', frames: ShimFrames.all),

  /// An iframe can create its own workers.
  worker('worker_shim', frames: ShimFrames.all),
  blockResourceObserver('block_resource_observer', frames: ShimFrames.all),
  blockJsInterceptor('block_js_interceptor', frames: ShimFrames.all),
  scriptFetch('script_fetch_shim', frames: ShimFrames.top),

  /// The user's own scripts, under one group at either time they ask for.
  userScriptsAtStart('user_scripts', frames: ShimFrames.top),
  userScriptsAtEnd('user_scripts', frames: ShimFrames.top, at: ShimTime.end),
  remoteEdge('remote_edge', frames: ShimFrames.all),
  iconLinkWatcher('icon_link_watcher', frames: ShimFrames.top),
  searchLinkWatcher('search_link_watcher', frames: ShimFrames.top);

  const ShimGroup(this.groupName, {required this.frames, this.at = ShimTime.start});

  /// The name the platform keeps the group's scripts under.
  final String groupName;

  final ShimFrames frames;
  final ShimTime at;
}

/// A shim replaced on a live view, for a value that changes while the page
/// stays (its theme, the OS text size). Between the replacement's removal and
/// its install a document can load without it, so a shim that keeps a value
/// from the page (a location, a fingerprint, a capture decision) is never one:
/// its change rebuilds the webview instead.
enum LiveShim {
  themeColorScheme(ShimGroup.themeColorScheme),
  systemTextZoom(ShimGroup.systemTextZoom);

  const LiveShim(this.group);

  final ShimGroup group;
}
