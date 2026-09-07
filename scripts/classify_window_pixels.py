#!/usr/bin/env python3
"""Classify a raw `adb exec-out screencap` frame over a cropped region.

Host-side half of the adb white-screen tier (INTEG-011): the lifecycle
scenarios (warm start, activity recreation, bfcache back nav) survive
activity/process teardown, so the verdict must come from outside the app.
`screencap` reads the final composited frame (SurfaceFlinger output),
which includes the SurfaceView content that Flutter-side captures miss —
the same plane the in-app window sampler (SurfaceDiagPlugin) reads.

Prints one JSON line: {"status", "width", "height", "dominant", "uniform",
"verdict"}. Verdict thresholds mirror SurfaceDiagNative.classify: a region
>= 98% one quantized color whose luma is >= 243 (white) or <= 12 (black)
is the BUG-001 blank; anything else is content.

Exit codes: 0 = expectation met (or no expectation given), 3 =
expectation not met, 2 = unreadable frame. Expectations:
  --expect-dominant RRGGBB [--tolerance N] [--min-uniform F]
      dominant pixel within per-channel tolerance and uniform fraction
      at least F (the seeded solid-color pages make this a proof the
      webview composited).
  --expect-blank-white
      verdict must be the white blank (detector sensitivity control).
  --expect-blank
      verdict must be either blank. Which shade the uncomposited hole
      samples as is not the app's to decide, so a scenario asserting the
      surface went blank must not depend on it.
"""

import argparse
import json
import struct
import sys

# Fractional (left, top, right, bottom) of the screen that is webview on a
# portrait phone with the seeded layout (no URL bar): below status bar +
# AppBar, above the gesture nav area, inset from the edges so scrollbars
# and edge glow stay out of the histogram.
DEFAULT_CROP = (0.15, 0.30, 0.85, 0.75)
GRID = 64  # GRID^2 sampled pixels, like the in-app 32x32 PixelCopy histogram

RGBA_8888 = 1


def parse_frame(data):
    if len(data) < 16:
        return None, 'short frame (%d bytes)' % len(data)
    w, h, fmt = struct.unpack_from('<III', data, 0)
    if w == 0 or h == 0 or w > 16384 or h > 16384:
        return None, 'implausible dimensions %dx%d' % (w, h)
    if fmt != RGBA_8888:
        return None, 'unsupported pixel format %d' % fmt
    body = w * h * 4
    # API 26+ prepends a 16-byte header (adds colorspace); older is 12.
    for header in (16, 12):
        if len(data) == header + body:
            return (w, h, data[header:]), None
    return None, 'size mismatch: %d bytes for %dx%d' % (len(data), w, h)


def sample(w, h, pixels, crop):
    left = int(w * crop[0])
    top = int(h * crop[1])
    right = int(w * crop[2])
    bottom = int(h * crop[3])
    counts = {}
    representative = {}
    for gy in range(GRID):
        y = top + (bottom - 1 - top) * gy // (GRID - 1)
        row = y * w * 4
        for gx in range(GRID):
            x = left + (right - 1 - left) * gx // (GRID - 1)
            off = row + x * 4
            r, g, b = pixels[off], pixels[off + 1], pixels[off + 2]
            key = (r & 0xF0, g & 0xF0, b & 0xF0)
            counts[key] = counts.get(key, 0) + 1
            if key not in representative:
                representative[key] = (r, g, b)
    dominant_key = max(counts, key=counts.get)
    return representative[dominant_key], counts[dominant_key] / (GRID * GRID)


def verdict_of(rgb, uniform):
    if uniform < 0.98:
        return 'content'
    luma = 0.299 * rgb[0] + 0.587 * rgb[1] + 0.114 * rgb[2]
    if luma >= 243:
        return 'blank-white'
    if luma <= 12:
        return 'blank-black'
    return 'content'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--file', help='raw screencap dump (default: stdin)')
    ap.add_argument('--crop', help='fractional left,top,right,bottom')
    ap.add_argument('--expect-dominant', metavar='RRGGBB')
    ap.add_argument('--tolerance', type=int, default=28)
    ap.add_argument('--min-uniform', type=float, default=0.5)
    ap.add_argument('--expect-blank-white', action='store_true')
    ap.add_argument('--expect-blank', action='store_true')
    args = ap.parse_args()

    crop = DEFAULT_CROP
    if args.crop:
        crop = tuple(float(v) for v in args.crop.split(','))
        if len(crop) != 4 or not all(0 <= v <= 1 for v in crop) or \
                crop[0] >= crop[2] or crop[1] >= crop[3]:
            print(json.dumps({'status': 'bad-crop'}))
            return 2

    if args.file:
        with open(args.file, 'rb') as f:
            data = f.read()
    else:
        data = sys.stdin.buffer.read()

    frame, err = parse_frame(data)
    if frame is None:
        print(json.dumps({'status': 'unreadable', 'error': err}))
        return 2
    w, h, pixels = frame
    rgb, uniform = sample(w, h, pixels, crop)
    verdict = verdict_of(rgb, uniform)
    print(json.dumps({
        'status': 'ok',
        'width': w,
        'height': h,
        'dominant': '%02x%02x%02x' % rgb,
        'uniform': round(uniform, 4),
        'verdict': verdict,
    }))

    if args.expect_dominant:
        want = int(args.expect_dominant, 16)
        want_rgb = ((want >> 16) & 0xFF, (want >> 8) & 0xFF, want & 0xFF)
        near = all(abs(a - e) <= args.tolerance
                   for a, e in zip(rgb, want_rgb))
        return 0 if near and uniform >= args.min_uniform else 3
    if args.expect_blank_white:
        return 0 if verdict == 'blank-white' else 3
    if args.expect_blank:
        return 0 if verdict in ('blank-white', 'blank-black') else 3
    return 0


if __name__ == '__main__':
    sys.exit(main())
