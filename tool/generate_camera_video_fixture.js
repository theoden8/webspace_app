// Generates the two-tone looping WebM used as a *video* virtual-camera
// source by integration_test/camera_test.dart.
//
//   node tool/generate_camera_video_fixture.js
//
// Output: integration_test/fixtures/virtual_camera_video.dart — a base64
// const, because the emulator tier runs on-device where the repo's files
// are not readable and adding the clip to pubspec `assets:` would ship it
// inside the production app.
//
// Encoded with Chromium's own MediaRecorder (canvas.captureStream ->
// VP8/WebM) so no ffmpeg is needed; the repo's Puppeteer browser is the
// only dependency.
//
// The clip alternates its two colours on EVERY frame, so each colour holds
// half the clip's media time and two decoded frames are enough to prove the
// source is playing rather than frozen.
//
// Its predecessor painted the canvas twice and let captureStream(10) sample
// it. That capture emits a frame only when the canvas is touched, so the
// clip came out as exactly two frames: colour A at 0ms and colour B at
// 500ms, the last 0.3ms of a 500.3ms clip. A sampler could then only catch
// colour B by winning a race with the loop wrap, which it loses often
// enough to have produced 8, 2 and 0 transitions across CI runs of the same
// 4s window, and zero across 300 samples on the run that failed the
// emulator tier. Per-frame alternation strengthens the freeze check rather
// than loosening it: a stream stuck on frame 0 still reports one colour.

const fs = require('node:fs');
const path = require('node:path');
const puppeteer = require('puppeteer');

const OUT = path.resolve(
  __dirname, '..', 'integration_test', 'fixtures', 'virtual_camera_video.dart');

// Kept in sync with the constants in integration_test/camera_test.dart.
const COLOR_A = [0x1E, 0xC8, 0x7A]; // green
const COLOR_B = [0xC8, 0x1E, 0x9B]; // magenta

// 24fps is a frame period of ~41.7ms, which does not divide the 100ms
// sampling interval of either probe: a sampler cannot lock onto one parity
// of an every-frame alternation and read a constant colour off a live clip.
const FPS = 24;
const FRAMES = 24;

(async () => {
  const browser = await puppeteer.launch({
    headless: true, args: ['--no-sandbox', '--disable-setuid-sandbox'],
  });
  const page = await browser.newPage();
  await page.goto('about:blank', { waitUntil: 'load' });

  const base64 = await page.evaluate(async (a, b, fps, frames) => {
    const canvas = document.createElement('canvas');
    canvas.width = 160;
    canvas.height = 120;
    const ctx = canvas.getContext('2d');
    // 0fps: frames are captured only by requestFrame(), so each painted
    // colour becomes exactly one encoded frame. Auto-capture at a fixed rate
    // samples the canvas on its own clock, which can duplicate a colour or —
    // if it happens to stride by two paints — miss the alternation entirely.
    const stream = canvas.captureStream(0);
    const track = stream.getVideoTracks()[0];
    const rec = new MediaRecorder(stream, {
      mimeType: 'video/webm;codecs=vp8',
      videoBitsPerSecond: 100000,
    });
    const chunks = [];
    rec.ondataavailable = (e) => { if (e.data.size) chunks.push(e.data); };
    const done = new Promise((res) => { rec.onstop = res; });

    const paint = (c) => {
      ctx.fillStyle = `rgb(${c[0]},${c[1]},${c[2]})`;
      ctx.fillRect(0, 0, canvas.width, canvas.height);
    };

    paint(a);
    rec.start();
    for (let i = 0; i < frames; i++) {
      paint(i % 2 === 0 ? a : b);
      track.requestFrame();
      await new Promise((r) => setTimeout(r, 1000 / fps));
    }
    rec.stop();
    await done;

    const blob = new Blob(chunks, { type: 'video/webm' });
    const buf = await blob.arrayBuffer();
    const bytes = new Uint8Array(buf);
    let bin = '';
    for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
    return btoa(bin);
  }, COLOR_A, COLOR_B, FPS, FRAMES);

  // Decode what was just encoded and walk its presented frames: the whole
  // point of the fixture is that one flip costs two frames, and neither the
  // emulator tier nor the browser tier can tell a bad encode from a stalled
  // decoder. Fail here instead.
  const check = await page.evaluate(async (dataUrl, a, b) => {
    const video = document.createElement('video');
    video.muted = true;
    video.playsInline = true;
    video.src = dataUrl;
    await new Promise((res, rej) => {
      video.oncanplay = res;
      video.onerror = () => rej(new Error('generated clip does not decode'));
    });
    if (!video.requestVideoFrameCallback) {
      throw new Error('requestVideoFrameCallback missing; cannot verify the clip');
    }
    const canvas = document.createElement('canvas');
    canvas.width = video.videoWidth;
    canvas.height = video.videoHeight;
    const ctx = canvas.getContext('2d');
    const frames = [];
    const ended = new Promise((res) => { video.onended = res; });
    const onFrame = () => {
      ctx.drawImage(video, 0, 0);
      const d = ctx.getImageData(
        Math.floor(canvas.width / 2), Math.floor(canvas.height / 2), 1, 1).data;
      frames.push([d[0], d[1], d[2]]);
      video.requestVideoFrameCallback(onFrame);
    };
    video.requestVideoFrameCallback(onFrame);
    await video.play();
    await Promise.race([ended, new Promise((r) => setTimeout(r, 10000))]);
    const near = (p, c) => Math.abs(p[0] - c[0]) + Math.abs(p[1] - c[1]) +
      Math.abs(p[2] - c[2]) <= 60;
    let transitions = 0;
    let firstFlip = -1;
    for (let i = 1; i < frames.length; i++) {
      const p = frames[i - 1], q = frames[i];
      if (Math.abs(p[0] - q[0]) + Math.abs(p[1] - q[1]) + Math.abs(p[2] - q[2]) > 40) {
        transitions++;
        if (firstFlip < 0) firstFlip = i;
      }
    }
    return {
      presented: frames.length,
      transitions,
      firstFlip,
      sawA: frames.some((p) => near(p, a)),
      sawB: frames.some((p) => near(p, b)),
      durationMs: Math.round(video.duration * 1000),
      head: frames.slice(0, 6),
    };
  }, `data:video/webm;base64,${base64}`, COLOR_A, COLOR_B);

  await browser.close();

  const fail = (why) => {
    console.error(`generated clip rejected: ${why}\n${JSON.stringify(check)}`);
    process.exit(1);
  };
  if (!check.sawA || !check.sawB) fail('both colours must be present');
  // The flip must be at the very first frame boundary: that bound is what
  // the emulator tier is buying.
  if (check.firstFlip !== 1) fail(`first flip at frame ${check.firstFlip}, want 1`);
  if (check.transitions < (check.presented - 1) / 2) {
    fail(`only ${check.transitions} transitions over ${check.presented} frames`);
  }

  const dart = `// GENERATED by tool/generate_camera_video_fixture.js — do not edit.
//
// A ~1s VP8/WebM clip whose two solid colours alternate on every frame, used
// as the *video* virtual-camera source in integration_test/camera_test.dart.
// Every frame flips, so each colour holds half the clip and a sampler proves
// the stream is live off two decoded frames. Its predecessor carried the
// second colour on a single frame at the very end of the clip, where a
// sampler had to beat the loop wrap to see it at all.
// Committed (rather than generated at test time) because the Android
// emulator tier has no browser to encode it and the clip must not ship in
// the production app's assets.
//
// Regenerate: node tool/generate_camera_video_fixture.js

/// Solid colours the clip alternates between, as RGB.
const List<int> kVirtualCameraVideoColorA = [${COLOR_A.join(', ')}];
const List<int> kVirtualCameraVideoColorB = [${COLOR_B.join(', ')}];

/// The clip as a \`data:\` URL, ready to hand to \`VirtualCameraSource\`.
const String kVirtualCameraVideoDataUrl =
    'data:video/webm;base64,'
    '${base64}';
`;

  fs.mkdirSync(path.dirname(OUT), { recursive: true });
  fs.writeFileSync(OUT, dart);
  console.log(`wrote ${OUT} (${base64.length} base64 chars); ` +
    `${check.presented} frames presented, ${check.transitions} transitions, ` +
    `first flip at frame ${check.firstFlip}, duration ${check.durationMs}ms`);
})().catch((e) => { console.error(e); process.exit(1); });
