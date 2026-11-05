# BUG-044: A picked image is stored with metadata that names the user

Status: open

**Spec:** [web-camera-access](../../openspec/specs/web-camera-access/spec.md) CAM-015,
[site-editing](../../openspec/specs/site-editing/spec.md) EDIT-008,
[web-screen-sharing](../../openspec/specs/web-screen-sharing/spec.md) SHARE-016;
security review [SEC-016](../security/2026-09-10-review.md#sec-016-virtual-cameramicrophonescreen-bridge-returns-the-original-media-file-with-metadata-to-any-frame)
**Tests:** [test/virtual_pick_strip_test.dart](../../test/virtual_pick_strip_test.dart),
[test/media_metadata_strip_test.dart](../../test/media_metadata_strip_test.dart),
[test/custom_icon_test.dart](../../test/custom_icon_test.dart)

## Symptom

A file the user picks for a virtual camera or a virtual screen share is
inlined on the site's model as a `data:` URL and handed to page script, so
anything it says about the user (device model, GPS, capture time, editing
software, an XMP packet) is readable by the page and by any frame the shims
reach. A picked custom icon rides every settings backup the same way.

## Root mechanism / invariant

Every picked image is re-encoded before it is stored: a capture source by the
strip in `media_metadata_strip.dart`, a custom icon by `processCustomIconImage`.
The invariant is that nothing in the file survives but the pixels or samples.
One step owns it, and every kind of metadata a format carries has to be
cleared there, since the decoder keeps what it reads and the encoder writes
back whatever it is given.

## Fix attempts

1. **2026-09-10, #593 (SEC-016).** Images re-encoded with `package:image`
   (JPEG stays JPEG, everything else becomes PNG) with `exif` and `iccProfile`
   cleared; ISO-BMFF metadata boxes blanked in place; MP3 ID3 tags cut. *Why:*
   the bridge returned the picked file verbatim. *Why partial:* it cleared
   what the decoder reads into `exif` and `iccProfile` but not `textData`, into
   which the PNG decoder reads tEXt, iTXt and zTXt chunks, where a PNG carries
   XMP. The PNG encoder writes `textData` back, so a screenshot's XMP block
   reached the page. The unit tests checked a JPEG's EXIF and a BMP's pixels,
   neither of which has text.
2. **2026-11-05 (SHARE-016, EDIT-008).** One step, `withoutMetadata`, clears
   `exif`, `iccProfile` and `textData`, and both re-encodes of a picked image
   go through it: the capture source's strip and the custom icon's
   normalization, which had cleared nothing and rides backups. A test drives
   the pick path (`VirtualMediaPicker.pick` over a faked file dialog) with a
   PNG naming its device in an XMP text chunk and in EXIF, and reads the
   chunks of the PNG that lands; another holds the stored icon to the same.
   *Why partial:* it covers what `package:image` reads into its fields. A
   format whose metadata the decoder neither keeps nor drops would need its
   own case.

## Known open gaps

- WebM, Ogg, WAV, FLAC and AAC are delivered as picked; their metadata blocks
  are not walked (the strip's doc comment says so).
