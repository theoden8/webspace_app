/// In-memory mirror of [background_audio.html] for the loopback server in
/// `background_audio_lifecycle_test.dart`. The integration test app cannot
/// read repo files at runtime (macOS CI: sandbox/entitlements deny with
/// EPERM), so the served bytes live here; the .html stays the authoritative,
/// browser-openable fixture. Byte-equality is enforced by
/// `test/background_audio_fixture_drift_test.dart`, which runs host-side in
/// plain `flutter test` where disk access works.
const String backgroundAudioFixtureHtml = '''
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<title>background-audio fixture</title>
</head>
<body>
<p>background-audio fixture</p>
<script>
// Liveness beacon: while this page's JS timers run, the loopback test
// server receives a /beacon request every 250 ms carrying a monotonously
// increasing tick count and the audio element's currentTime. The
// integration test observes liveness purely from the server side, so it
// needs no bridge into the app's widget tree. When the engine freezes JS
// timers (app-lifecycle pause), the beacons stop — that silence is the
// observable.
window.__ticks = 0;
window.__audioPlayState = 'unattempted';
// Media is opt-out via ?noMedia=1, and the element is built in JS so a
// static <audio> tag can't touch the media stack at parse time: WPE WebKit
// in the headless CI container (GStreamer base only, no plugin sets, no
// audio sink) crashes its web process initializing the media pipeline,
// which crash-loops the renderer before the first beacon. The CI lifecycle
// test loads ?noMedia=1 and asserts JS-timer liveness — the thing the
// pause machinery actually freezes; open the fixture without the param to
// exercise real audio playback on a capable engine.
var audio = null;
if (new URLSearchParams(location.search).get('noMedia') === null) {
  try {
    audio = document.createElement('audio');
    audio.loop = true;
    audio.src =
      'data:audio/wav;base64,UklGRiQAAABXQVZFZm10IBAAAAABAAEAQB8AAIA+AAACABAAZGF0YQAAAAA=';
    document.body.appendChild(audio);
    // Autoplay may be blocked (policy) or unavailable; the beacon carries
    // the outcome so observers know which assertions are meaningful.
    audio.play().then(function () {
      window.__audioPlayState = 'playing';
    }).catch(function (e) {
      window.__audioPlayState = 'blocked:' + (e && e.name ? e.name : 'unknown');
    });
  } catch (e) {
    window.__audioPlayState = 'threw:' + (e && e.name ? e.name : 'unknown');
  }
} else {
  window.__audioPlayState = 'skipped';
}
setInterval(function () {
  window.__ticks++;
  var q = '/beacon?ticks=' + window.__ticks +
      '&audio=' + encodeURIComponent(window.__audioPlayState) +
      '&t=' + ((audio && audio.currentTime) || 0);
  try { fetch(q, { cache: 'no-store' }); } catch (e) {}
}, 250);
</script>
</body>
</html>
''';
