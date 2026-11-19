// The listing images F-Droid and the README read: each at the size its store
// takes, and carrying no metadata. A design tool's export can put EXIF, a
// colour profile or a capture date back in, or change the size, and no store
// says so until an upload; this holds every committed image to both.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const REPO = path.resolve(__dirname, '..', '..');
const listing = 'fastlane/metadata/android/en-US/images';

const sizes = {
  [`${listing}/phoneScreenshots/1.jpg`]: [1728, 3456],
  [`${listing}/phoneScreenshots/2.jpg`]: [1728, 3456],
  [`${listing}/phoneScreenshots/3.jpg`]: [1728, 3456],
  [`${listing}/phoneScreenshots/4.jpg`]: [1728, 3456],
  [`${listing}/featureGraphic.jpg`]: [1024, 500],
  'assets/featureGraphic.jpg': [1024, 500],
};

// The JPEG segments an image needs; any other application or comment segment
// (APP1 EXIF/XMP, APP2 ICC, APP13 IPTC, COM) is metadata.
const DECODING = new Set([0xc0, 0xc2, 0xc4, 0xdb, 0xdd, 0xe0]);

/** The size a JPEG declares and the segments before its scan. */
function jpeg(bytes) {
  assert.equal(bytes.readUInt16BE(0), 0xffd8, 'not a JPEG');
  const markers = [];
  let size;
  for (let i = 2; i < bytes.length && bytes[i] === 0xff; ) {
    const marker = bytes[i + 1];
    if (marker === 0xda) break;
    if (marker === 0xc0 || marker === 0xc2) {
      size = [bytes.readUInt16BE(i + 7), bytes.readUInt16BE(i + 5)];
    }
    markers.push(marker);
    i += 2 + bytes.readUInt16BE(i + 2);
  }
  return { size, markers };
}

test('every listing image F-Droid and the README read is listed here', () => {
  const dir = path.join(REPO, listing);
  const shipped = [
    ...fs.readdirSync(dir).filter((f) => /\.(jpe?g|png)$/.test(f) && f !== 'icon.png')
      .map((f) => `${listing}/${f}`),
    ...fs.readdirSync(path.join(dir, 'phoneScreenshots')).filter((f) => /\.(jpe?g|png)$/.test(f))
      .map((f) => `${listing}/phoneScreenshots/${f}`),
  ].sort();
  assert.deepEqual(shipped, Object.keys(sizes).filter((f) => f.startsWith(listing)).sort());
});

for (const [rel, [width, height]] of Object.entries(sizes)) {
  test(`${rel} is ${width}x${height} and carries no metadata`, () => {
    const { size, markers } = jpeg(fs.readFileSync(path.join(REPO, rel)));
    assert.deepEqual(size, [width, height]);
    const extra = markers.filter((m) => !DECODING.has(m)).map((m) => `0x${m.toString(16)}`);
    assert.deepEqual(extra, [], `${rel} carries metadata segments`);
  });
}
