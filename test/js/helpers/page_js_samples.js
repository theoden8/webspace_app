// One runnable copy of every script in lib/js, with a realistic config, for
// the gates that run all of them (shim_document_root.test.js). A new script
// without a sample fails page_js.test.js.

const { pageJs } = require('./page_js');
const LOC = require('./location_configs');
const CAPTURE = require('./capture_shims');
const { FX_ANDROID } = require('./ua_identities');
const { INSTALLER_COMBINED } = require('./worker_shims');
const { EARLY_CSS, COSMETIC } = require('./content_blocker_samples');

const SAMPLES = {
  anti_fingerprinting: pageJs('anti_fingerprinting', { seed: 'alpha-fixture-seed', letterbox: false }),
  blob_download: pageJs('blob_download', {
    blobUrl: 'blob:https://example.test/test-blob-1',
    suggestedFilename: 'hello.txt',
    taskId: 'task-fixture',
  }),
  blob_download_click_intercept: pageJs('blob_download_click_intercept'),
  blob_url_capture: pageJs('blob_url_capture'),
  block_js_interceptor: pageJs('block_js_interceptor'),
  block_resource_observer: pageJs('block_resource_observer'),
  camera_stream: CAPTURE.CAMERA,
  clearurl_share: pageJs('clearurl_share'),
  content_blocker_cosmetic: COSMETIC,
  content_blocker_csp: pageJs('content_blocker_csp', { directives: "script-src 'none'; img-src 'self'" }),
  content_blocker_early_css: EARLY_CSS,
  default_viewport: pageJs('default_viewport'),
  desktop_mode: pageJs('desktop_mode', { platform: 'Linux x86_64' }),
  do_not_track: pageJs('do_not_track'),
  expire_page_cookies: pageJs('expire_page_cookies'),
  generic_cosmetic: pageJs('generic_cosmetic'),
  html_snapshot: pageJs('html_snapshot'),
  icon_link_watcher: pageJs('icon_link_watcher', {
    documentLoadedHandler: 'wsIconDocumentLoaded',
    linksHandler: 'wsIconLinks',
    linksChangedHandler: 'wsIconLinksChanged',
  }),
  language: pageJs('language', { language: 'fr-FR' }),
  location_spoof: LOC.FULL_COMBO,
  media_pause: pageJs('media_pause'),
  media_session: pageJs('media_session'),
  microphone_stream: CAPTURE.MICROPHONE,
  notification_polyfill: pageJs('notification_polyfill', { siteId: 'site-fixture', notificationsEnabled: true }),
  page_zoom_css: pageJs('page_zoom_css', { zoomPercent: 120 }),
  page_zoom_viewport: pageJs('page_zoom_viewport', {
    scale: 0.8, pinLayoutWidth: true, portraitWidth: 393, landscapeWidth: 851,
  }),
  passkey: pageJs('passkey'),
  passkey_block: pageJs('passkey_block'),
  procedural_cosmetic: pageJs('procedural_cosmetic', { rules: [
    { selector: [{ type: 'css-selector', arg: 'div.ad:has-text(Sponsored)' }], action: 'remove' },
  ] }),
  screen_share: CAPTURE.SCREEN_SHARE,
  search_link_watcher: pageJs('search_link_watcher', { handler: 'wsSearchLinks' }),
  target_blank_rewrite: pageJs('target_blank_rewrite'),
  text_zoom: pageJs('text_zoom', { zoomPercent: 150 }),
  theme_color_scheme: pageJs('theme_color_scheme', { theme: 'dark' }),
  ua_identity: FX_ANDROID,
  user_script: pageJs('user_script', {
    scriptHandler: '__ws_s_test',
    fetchHandler: '__ws_f_test',
    inlineScriptHandler: '__ws_i_test',
    whitelist: ['cdn.jsdelivr.net'],
  }),
  webgl_kill_switch: pageJs('webgl_kill_switch'),
  worker_payload: pageJs('worker_payload'),
  worker_shim: INSTALLER_COMBINED,
};

module.exports = { SAMPLES };
