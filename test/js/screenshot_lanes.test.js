// The store screenshot lanes (openspec/specs/screenshots): every platform
// takes its set through the one integration test, the phone and tablet sets
// are framed or the lane fails, and the iPad build that opts out of
// multitasking never leaves Info.plist changed.
//
// Rung 5: a Fastfile is Ruby that only a device run executes, and the
// screenshot jobs run on a manual run or a release PR alone, so the lanes'
// shape is read from their text here, where every PR checks it.
const test = require('node:test');
const assert = require('node:assert/strict');
const { read, exists } = require('./helpers/source');

const DRIVER = 'test_driver/integration_test.dart';
const TARGET = 'integration_test/screenshot_test.dart';

// Each platform's Fastfile and the folder its set lands in.
const PLATFORMS = {
  android: { fastfile: 'android/fastlane/Fastfile', dir: '"screenshots", "android"' },
  ios: { fastfile: 'ios/fastlane/Fastfile', dir: '"screenshots", "ios", name' },
  mac: { fastfile: 'macos/fastlane/Fastfile', dir: '"screenshots", "macos"' },
  linux: { fastfile: 'linux/fastlane/Fastfile', dir: '"screenshots", "linux"' },
};

/** A lane's body: from its `lane :name do` line to the `end` at its indent. */
function lane(source, name) {
  const head = new RegExp(`^( *)lane :${name} do\\b.*$`, 'm').exec(source);
  if (!head) return null;
  const rest = source.slice(head.index + head[0].length);
  const end = new RegExp(`^${head[1]}end$`, 'm').exec(rest);
  assert.ok(end, `lane :${name} has no end at its indent`);
  return rest.slice(0, end.index);
}

/** A Ruby method's body, as [lane] reads a lane's. */
function method(source, name) {
  const head = new RegExp(`^( *)def ${name}\\b.*$`, 'm').exec(source);
  if (!head) return null;
  const rest = source.slice(head.index + head[0].length);
  return rest.slice(0, new RegExp(`^${head[1]}end$`, 'm').exec(rest).index);
}

/** What is wrong with a `screenshots` lane: SCREENSHOT-001's shape. */
function screenshotLaneProblems(source, { dir }) {
  const body = lane(source, 'screenshots');
  if (body === null) return ['no screenshots lane'];
  const problems = [];
  if (!body.includes(`--driver=${DRIVER}`)) problems.push(`does not drive ${DRIVER}`);
  if (!body.includes(`--target=${TARGET}`)) problems.push(`does not run ${TARGET}`);
  if (!/SCREENSHOT_DIR='#\{screenshots_dir\}'/.test(body)) {
    problems.push('does not hand the driver its folder');
  }
  const folder = body.includes(dir) || (method(source, 'screenshot_set') ?? '').includes(dir);
  if (!folder) problems.push(`does not write into ${dir}`);
  return problems;
}

test('every platform takes its set through the one screenshot test (SCREENSHOT-001)', () => {
  for (const [platform, spec] of Object.entries(PLATFORMS)) {
    const source = read(spec.fastfile);
    assert.match(source, new RegExp(`^platform :${platform} do$`, 'm'),
      `${spec.fastfile} declares no ${platform} platform`);
    assert.deepEqual(screenshotLaneProblems(source, spec), [], spec.fastfile);
  }
  const mac = read(PLATFORMS.mac.fastfile);
  assert.deepEqual(
    screenshotLaneProblems(mac.replace(TARGET, 'integration_test/smoke_test.dart'), PLATFORMS.mac),
    [`does not run ${TARGET}`]);
});

/** What is wrong with a framing lane: SCREENSHOT-005's for iOS. */
function iosFramingProblems(source) {
  const problems = [];
  const frames = lane(source, 'add_device_frames');
  if (frames === null) return ['no add_device_frames lane'];
  if (!/frame_screenshots\(/.test(frames)) problems.push('frames nothing');
  if (!/resize_screenshots\(/.test(frames)) problems.push('frames shots not at their store size');
  // frameit logs a shot it cannot frame and carries on.
  if (!/UI\.user_error!\("frameit left unframed/.test(frames)
      || !/_framed\.png/.test(frames.slice(frames.indexOf('frame_screenshots(')))) {
    problems.push('passes with a shot left unframed');
  }
  const sets = method(source, 'screenshot_set') ?? '';
  for (const [device, size] of [['iphone', '1170, 2532'], ['ipad', '2048, 2732']]) {
    if (!new RegExp(`"${device}" => \\{[^}]*portrait: \\[${size}\\]`).test(sets)) {
      problems.push(`${device} is not resized to ${size.replace(', ', 'x')}`);
    }
  }
  return problems;
}

test('the phone and tablet sets are framed, at the size each store takes '
    + '(SCREENSHOT-005)', () => {
  const ios = read(PLATFORMS.ios.fastfile);
  assert.deepEqual(iosFramingProblems(ios), []);
  const android = lane(read(PLATFORMS.android.fastfile), 'add_device_frames');
  assert.ok(android && /frame_screenshots\(/.test(android), 'Android frames nothing');
  assert.match(android, /resize_screenshots\n/, 'Android frames shots not resized first');
  for (const dir of ['screenshots/android', 'screenshots/ios']) {
    assert.ok(exists(`${dir}/Framefile.json`), `${dir} has no frameit config`);
  }
  // Desktop sets are window captures with their own title bar.
  for (const platform of ['mac', 'linux']) {
    assert.doesNotMatch(read(PLATFORMS[platform].fastfile), /frame_screenshots|add_device_frames/,
      `${platform} frames its window captures`);
  }

  const unchecked = ios.replace(/\n *UI\.user_error!\("frameit left unframed[^\n]*/, '');
  assert.notEqual(unchecked, ios, 'the plant changed nothing');
  assert.deepEqual(iosFramingProblems(unchecked), ['passes with a shot left unframed']);
});

/** What is wrong with the iPad build's Info.plist change: SCREENSHOT-010's. */
function fullScreenProblems(source) {
  const problems = [];
  const sets = method(source, 'screenshot_set') ?? '';
  if (!/"ipad" => \{[^}]*full_screen: true/.test(sets)) problems.push('the iPad set keeps multitasking');
  if (!/"iphone" => \{[^}]*full_screen: false/.test(sets)) problems.push('the iPhone set opts out of multitasking');
  const body = lane(source, 'screenshots') ?? '';
  const kept = /(\w+) = File\.read\(info_plist\)/.exec(body);
  const guarded = /\n( *)begin\n([\s\S]*?)\n\1ensure\n([\s\S]*?)\n\1end\b/.exec(body);
  if (!kept) problems.push('does not keep the shipped Info.plist');
  if (!guarded || !/UIRequiresFullScreen/.test(guarded[2]) || !/flutter drive/.test(guarded[2])) {
    problems.push('changes Info.plist outside the guarded run');
  } else if (!kept || !guarded[3].includes(`File.write(info_plist, ${kept[1]})`)) {
    problems.push('does not put Info.plist back when the run fails');
  }
  return problems;
}

test('the iPad set is taken from a build that opts out of multitasking, and '
    + 'Info.plist is put back (SCREENSHOT-010)', () => {
  const ios = read(PLATFORMS.ios.fastfile);
  assert.deepEqual(fullScreenProblems(ios), []);
  const unguarded = ios.replace(/\n( *)ensure\n( *File\.write\(info_plist, \w+\))\n\1end/,
    '\n$1end\n$2');
  assert.notEqual(unguarded, ios, 'the plant changed nothing');
  assert.deepEqual(fullScreenProblems(unguarded), ['changes Info.plist outside the guarded run']);
  assert.deepEqual(fullScreenProblems(ios.replace('full_screen: true', 'full_screen: false')),
    ['the iPad set keeps multitasking']);
});
