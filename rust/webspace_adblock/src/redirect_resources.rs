// SPDX-License-Identifier: MPL-2.0
//
// The bodies `$redirect=` and `$rewrite=abp-resource:` rules name. A filter
// list asks for one by the name its syntax gives it (uBlock Origin's resource
// names and their aliases, Adblock Plus's `abp-resource:` names); the engine
// serves the body as a `data:` URL in place of the blocked request. A rule
// naming a resource that is not here blocks the request outright
// (adblock-rust's `Blocker`), as it does with the pool switched off. The pool
// holds three kinds:
//   * bodies that do nothing: an empty script, page, text, stylesheet or JSON
//     value, a transparent image, a silent sound or video, an empty ad
//     playlist, made here;
//   * scripts that stand in for a library's API, written here from that
//     library's own documentation, each in ../resources/ with what it stands
//     in for in its header;
//   * DuckDuckGo's tracker surrogates (`SURROGATES`), which build.rs takes at
//     a pinned commit, file by file as ../surrogates.tsv pins them.

use adblock::resources::{MimeType, Resource, ResourceType};
use base64::{engine::general_purpose::STANDARD, Engine as _};

struct Stub {
    name: &'static str,
    aliases: &'static [&'static str],
    mime: MimeType,
    body: Body,
}

enum Body {
    Text(&'static str),
    Gif,
    Png { width: u32, height: u32 },
    SilentMp3 { seconds: f64 },
    SilentMp4 { seconds: f64 },
}

const STUBS: &[Stub] = &[
    Stub { name: "noop.js", aliases: &["noopjs", "abp-resource:blank-js"],
        mime: MimeType::ApplicationJavascript, body: Body::Text("(function() {})();\n") },
    Stub { name: "noop.html", aliases: &["noopframe", "abp-resource:blank-html"],
        mime: MimeType::TextHtml,
        body: Body::Text("<!DOCTYPE html>\n<html><head></head><body></body></html>\n") },
    Stub { name: "noop.txt", aliases: &["nooptext", "abp-resource:blank-text"],
        mime: MimeType::TextPlain, body: Body::Text("") },
    Stub { name: "empty", aliases: &[],
        mime: MimeType::TextPlain, body: Body::Text("") },
    Stub { name: "noop.css", aliases: &["abp-resource:blank-css"],
        mime: MimeType::TextCss, body: Body::Text("") },
    Stub { name: "noop.json", aliases: &["noopjson"],
        mime: MimeType::ApplicationJson, body: Body::Text("{}\n") },
    // IAB VMAP 1.0: a playlist with no ad breaks.
    Stub { name: "noop-vmap1.0.xml", aliases: &["noopvmap-1.0", "noop-vmap1.xml"],
        mime: MimeType::TextXml,
        body: Body::Text("<vmap:VMAP xmlns:vmap=\"http://www.iab.net/videosuite/vmap\" version=\"1.0\"></vmap:VMAP>\n") },
    Stub { name: "1x1.gif", aliases: &["1x1-transparent.gif", "abp-resource:1x1-transparent-gif"],
        mime: MimeType::ImageGif, body: Body::Gif },
    Stub { name: "2x2.png", aliases: &["2x2-transparent.png", "abp-resource:2x2-transparent-png"],
        mime: MimeType::ImagePng, body: Body::Png { width: 2, height: 2 } },
    Stub { name: "3x2.png", aliases: &["3x2-transparent.png", "abp-resource:3x2-transparent-png"],
        mime: MimeType::ImagePng, body: Body::Png { width: 3, height: 2 } },
    Stub { name: "32x32.png", aliases: &["32x32-transparent.png", "abp-resource:32x32-transparent-png"],
        mime: MimeType::ImagePng, body: Body::Png { width: 32, height: 32 } },
    Stub { name: "noop-0.1s.mp3", aliases: &["noopmp3-0.1s", "abp-resource:blank-mp3"],
        mime: MimeType::AudioMp3, body: Body::SilentMp3 { seconds: 0.1 } },
    Stub { name: "noop-0.5s.mp3", aliases: &[],
        mime: MimeType::AudioMp3, body: Body::SilentMp3 { seconds: 0.5 } },
    Stub { name: "noop-1s.mp4", aliases: &["abp-resource:blank-mp4"],
        mime: MimeType::VideoMp4, body: Body::SilentMp4 { seconds: 1.0 } },
    Stub { name: "nofab.js", aliases: &["fuckadblock.js-3.2.0", "nobab.js", "bab-defuser.js"],
        mime: MimeType::ApplicationJavascript, body: Body::Text(include_str!("../resources/nofab.js")) },
    Stub { name: "noeval.js", aliases: &[],
        mime: MimeType::ApplicationJavascript, body: Body::Text(include_str!("../resources/noeval.js")) },
    Stub { name: "noeval-silent.js", aliases: &["silent-noeval.js"],
        mime: MimeType::ApplicationJavascript, body: Body::Text(include_str!("../resources/noeval-silent.js")) },
    Stub { name: "popads.js", aliases: &["popads.net.js"],
        mime: MimeType::ApplicationJavascript, body: Body::Text(include_str!("../resources/popads.js")) },
    Stub { name: "prebid-ads.js", aliases: &[],
        mime: MimeType::ApplicationJavascript, body: Body::Text(include_str!("../resources/prebid-ads.js")) },
    Stub { name: "fingerprint2.js", aliases: &[],
        mime: MimeType::ApplicationJavascript, body: Body::Text(include_str!("../resources/fingerprint2.js")) },
    Stub { name: "fingerprint3.js", aliases: &[],
        mime: MimeType::ApplicationJavascript, body: Body::Text(include_str!("../resources/fingerprint3.js")) },
    Stub { name: "ampproject_v0.js", aliases: &["ampproject.org/v0.js"],
        mime: MimeType::ApplicationJavascript, body: Body::Text(include_str!("../resources/ampproject_v0.js")) },
];

include!(concat!(env!("OUT_DIR"), "/surrogates.rs"));

/// The pool, as the engine takes it (`Engine::use_resources`).
pub(crate) fn all() -> Vec<Resource> {
    STUBS
        .iter()
        .chain(SURROGATES)
        .map(|stub| Resource {
            name: stub.name.to_string(),
            aliases: stub.aliases.iter().map(|a| a.to_string()).collect(),
            kind: ResourceType::Mime(stub.mime.clone()),
            content: STANDARD.encode(stub.body.bytes()),
            dependencies: Vec::new(),
            permission: Default::default(),
        })
        .collect()
}

impl Body {
    fn bytes(&self) -> Vec<u8> {
        match self {
            Body::Text(text) => text.as_bytes().to_vec(),
            Body::Gif => TRANSPARENT_GIF.to_vec(),
            Body::Png { width, height } => transparent_png(*width, *height),
            Body::SilentMp3 { seconds } => silent_mp3(*seconds),
            Body::SilentMp4 { seconds } => silent_mp4(*seconds),
        }
    }
}

/// GIF89a, 1x1, a two-colour table whose first colour the graphic control
/// extension makes transparent, and that one pixel in it.
const TRANSPARENT_GIF: [u8; 43] = [
    b'G', b'I', b'F', b'8', b'9', b'a',
    0x01, 0x00, 0x01, 0x00, // width, height
    0x80, 0x00, 0x00, // global colour table of 2, background 0, square pixels
    0x00, 0x00, 0x00, 0xff, 0xff, 0xff, // the table
    0x21, 0xf9, 0x04, 0x01, 0x00, 0x00, 0x00, 0x00, // colour 0 is transparent
    0x2c, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, // the image
    0x02, 0x02, 0x44, 0x01, 0x00, // LZW: clear, 0, end
    0x3b,
];

/// A PNG of [width] x [height] transparent RGBA pixels, its image data one
/// uncompressed deflate block.
fn transparent_png(width: u32, height: u32) -> Vec<u8> {
    let row = 1 + 4 * width as usize; // filter type 0, then the pixels
    let raw = vec![0u8; row * height as usize];
    assert!(raw.len() <= 0xffff, "one stored deflate block holds 65535 bytes");

    let mut ihdr = Vec::new();
    ihdr.extend_from_slice(&width.to_be_bytes());
    ihdr.extend_from_slice(&height.to_be_bytes());
    ihdr.extend_from_slice(&[8, 6, 0, 0, 0]); // 8 bits, RGBA, deflate, no filter set, no interlace

    let len = raw.len() as u16;
    let mut zlib = vec![0x78, 0x01, 0x01]; // zlib header; final stored block
    zlib.extend_from_slice(&len.to_le_bytes());
    zlib.extend_from_slice(&(!len).to_le_bytes());
    zlib.extend_from_slice(&raw);
    zlib.extend_from_slice(&adler32(&raw).to_be_bytes());

    let mut png = vec![0x89, b'P', b'N', b'G', 0x0d, 0x0a, 0x1a, 0x0a];
    png_chunk(&mut png, b"IHDR", &ihdr);
    png_chunk(&mut png, b"IDAT", &zlib);
    png_chunk(&mut png, b"IEND", &[]);
    png
}

fn png_chunk(png: &mut Vec<u8>, kind: &[u8; 4], data: &[u8]) {
    png.extend_from_slice(&(data.len() as u32).to_be_bytes());
    let start = png.len();
    png.extend_from_slice(kind);
    png.extend_from_slice(data);
    let crc = crc32(&png[start..]);
    png.extend_from_slice(&crc.to_be_bytes());
}

const MP3_HEADER: [u8; 4] = [0xff, 0xfb, 0x10, 0xc0];
const MP3_RATE: u32 = 44_100;
const MP3_BITRATE: u32 = 32_000;
const MP3_FRAME_SAMPLES: u32 = 1152;
const MP3_FRAME_LEN: usize = (144 * MP3_BITRATE / MP3_RATE) as usize;
const MP3_FRAME_SECONDS: f64 = MP3_FRAME_SAMPLES as f64 / MP3_RATE as f64;

/// [seconds] of MPEG-1 Layer III silence, to the nearest frame: 32 kbit/s,
/// 44.1 kHz, mono, no CRC. Each frame is its header and zeros, so its side
/// information gives every granule no coded bits.
fn silent_mp3(seconds: f64) -> Vec<u8> {
    let frames = (seconds / MP3_FRAME_SECONDS).round() as usize;
    let mut mp3 = Vec::with_capacity(frames * MP3_FRAME_LEN);
    for _ in 0..frames {
        mp3.extend_from_slice(&MP3_HEADER);
        mp3.resize(mp3.len() + MP3_FRAME_LEN - MP3_HEADER.len(), 0);
    }
    mp3
}

/// The same silence as an MP4 file (ISO/IEC 14496-12), its one track the MP3
/// frames as samples, object type 0x6B (MPEG-1 audio in ISO/IEC 14496-1's
/// registry), every box version 0 and the movie data last.
fn silent_mp4(seconds: f64) -> Vec<u8> {
    let mdat = silent_mp3(seconds);
    let frames = (mdat.len() / MP3_FRAME_LEN) as u32;
    let ftyp = mp4_box(b"ftyp", [&b"isom"[..], &0x200u32.to_be_bytes(), b"isom", b"iso2", b"mp41"].concat());
    let head = ftyp.len() + mp4_moov(frames, 0).len() + 8;
    [ftyp, mp4_moov(frames, head as u32), mp4_box(b"mdat", mdat)].concat()
}

/// The movie box of [frames] MP3 frames stored from file offset [data_at].
fn mp4_moov(frames: u32, data_at: u32) -> Vec<u8> {
    let be = u32::to_be_bytes;
    let samples = frames * MP3_FRAME_SAMPLES;
    let millis = (samples as u64 * 1000 + MP3_RATE as u64 / 2) / MP3_RATE as u64;
    let millis = be(millis as u32);
    let unity: Vec<u8> = [0x0001_0000u32, 0, 0, 0, 0x0001_0000, 0, 0, 0, 0x4000_0000]
        .iter()
        .flat_map(|v| v.to_be_bytes())
        .collect();
    let volume = 0x0100u16.to_be_bytes();
    // creation and modification times, then the timescale and duration
    let mvhd = full_box(b"mvhd", 0, [&[0; 8][..], &be(1000), &millis, &be(0x0001_0000), &volume,
        &[0; 10], &unity, &[0; 24], &be(2)].concat());
    // flags: enabled, in the movie
    let tkhd = full_box(b"tkhd", 3, [&[0; 8][..], &be(1), &[0; 4], &millis, &[0; 12], &volume,
        &[0; 2], &unity, &[0; 8]].concat());
    // 0x55c4 is the language `und`, three letters of five bits
    let mdhd = full_box(b"mdhd", 0, [&[0; 8][..], &be(MP3_RATE), &be(samples), &0x55c4u16.to_be_bytes(),
        &[0; 2]].concat());
    let hdlr = full_box(b"hdlr", 0, [&[0; 4][..], b"soun", &[0; 12], b"SoundHandler\0"].concat());
    let smhd = full_box(b"smhd", 0, vec![0; 4]);
    // one data reference, flag 1: the data is in this file
    let dinf = mp4_box(b"dinf", full_box(b"dref", 0, [&be(1)[..], &full_box(b"url ", 1, Vec::new())].concat()));
    // ES_ID 1; object type 0x6B, stream type 5 (audio) with its reserved bit,
    // a frame's buffer and bitrates; SL config 2, as an MP4 file has it
    let decoder = mp4_descriptor(4, [&[0x6b, 0x15][..], &be(MP3_FRAME_LEN as u32)[1..], &be(MP3_BITRATE),
        &be(MP3_BITRATE)].concat());
    let esds = full_box(b"esds", 0, mp4_descriptor(3, [&[0, 1, 0][..], &decoder, &mp4_descriptor(6, vec![2])].concat()));
    // data reference 1; one channel of 16-bit samples at the frames' rate
    let mp4a = mp4_box(b"mp4a", [&[0; 6][..], &1u16.to_be_bytes(), &[0; 8], &1u16.to_be_bytes(),
        &16u16.to_be_bytes(), &[0; 4], &be(MP3_RATE << 16), &esds].concat());
    let stbl = mp4_box(b"stbl", [
        full_box(b"stsd", 0, [&be(1)[..], &mp4a].concat()),
        full_box(b"stts", 0, [be(1), be(frames), be(MP3_FRAME_SAMPLES)].concat()),
        full_box(b"stsc", 0, [be(1), be(1), be(frames), be(1)].concat()),
        full_box(b"stsz", 0, [be(MP3_FRAME_LEN as u32), be(frames)].concat()),
        full_box(b"stco", 0, [be(1), be(data_at)].concat()),
    ].concat());
    let minf = mp4_box(b"minf", [smhd, dinf, stbl].concat());
    let mdia = mp4_box(b"mdia", [mdhd, hdlr, minf].concat());
    mp4_box(b"moov", [mvhd, mp4_box(b"trak", [tkhd, mdia].concat())].concat())
}

fn mp4_box(kind: &[u8; 4], payload: Vec<u8>) -> Vec<u8> {
    [&((8 + payload.len()) as u32).to_be_bytes()[..], kind, &payload].concat()
}

/// A box with a version, always 0, and [flags].
fn full_box(kind: &[u8; 4], flags: u32, payload: Vec<u8>) -> Vec<u8> {
    mp4_box(kind, [&flags.to_be_bytes()[..], &payload].concat())
}

/// An MPEG-4 descriptor of [tag], its length in one byte.
fn mp4_descriptor(tag: u8, body: Vec<u8>) -> Vec<u8> {
    assert!(body.len() < 0x80, "a one-byte length");
    [&[tag, body.len() as u8][..], &body].concat()
}

/// CRC-32 as PNG defines it (ISO 3309, reflected, polynomial 0xEDB88320).
fn crc32(bytes: &[u8]) -> u32 {
    let mut crc = 0xffff_ffffu32;
    for &byte in bytes {
        crc ^= byte as u32;
        for _ in 0..8 {
            crc = if crc & 1 != 0 { (crc >> 1) ^ 0xedb8_8320 } else { crc >> 1 };
        }
    }
    !crc
}

/// Adler-32 as zlib defines it (RFC 1950).
fn adler32(bytes: &[u8]) -> u32 {
    let (mut a, mut b) = (1u32, 0u32);
    for &byte in bytes {
        a = (a + byte as u32) % 65_521;
        b = (b + a) % 65_521;
    }
    (b << 16) | a
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    #[test]
    fn checksums_match_their_published_check_values() {
        assert_eq!(crc32(b"123456789"), 0xcbf4_3926);
        assert_eq!(crc32(b"IEND"), 0xae42_6082);
        assert_eq!(adler32(b"Wikipedia"), 0x11e6_0398);
    }

    fn pool() -> impl Iterator<Item = &'static Stub> {
        STUBS.iter().chain(SURROGATES)
    }

    fn names(stub: &Stub) -> impl Iterator<Item = &'static str> + '_ {
        std::iter::once(stub.name).chain(stub.aliases.iter().copied())
    }

    #[test]
    fn every_name_and_alias_is_taken_once() {
        let mut seen = HashSet::new();
        for stub in pool() {
            for name in names(stub) {
                assert!(seen.insert(name), "{name} is named twice");
            }
        }
    }

    // adblock-rust drops a resource it cannot take without a word (a name
    // taken twice, a body that is not its kind's), so each name is asked of
    // an engine the way a filter list asks for it.
    #[test]
    fn every_name_and_alias_serves_its_body_cb_010() {
        let asked: Vec<(String, &Stub)> = pool()
            .flat_map(|stub| names(stub).map(move |name| (name.to_string(), stub)))
            .collect();
        let rules: Vec<String> = asked
            .iter()
            .enumerate()
            .map(|(i, (name, _))| format!("||r{i}.example^$redirect={name}"))
            .collect();
        let mut set = adblock::lists::FilterSet::new(false);
        set.add_filter_list(rules.join("\n"), Default::default());
        let mut engine = adblock::Engine::new_with_filter_set(set);
        engine.use_resources(all());
        for (i, (name, stub)) in asked.iter().enumerate() {
            let request = adblock::request::Request::new(
                &format!("https://r{i}.example/x"), "https://site.example/", "script", "").unwrap();
            let redirect = engine.check_network_request(&request).redirect
                .unwrap_or_else(|| panic!("$redirect={name} serves nothing"));
            let (head, body) = redirect.split_once(";base64,").expect("a base64 data: URL");
            assert_eq!(head, format!("data:{}", stub.mime), "{name}");
            assert_eq!(STANDARD.decode(body).unwrap(), stub.body.bytes(), "{name}");
        }
    }

    #[test]
    fn every_stub_can_serve_a_redirect() {
        for resource in all() {
            assert!(resource.kind.supports_redirect(), "{}", resource.name);
        }
    }

    #[test]
    fn the_gif_is_one_transparent_pixel() {
        let gif = Body::Gif.bytes();
        assert_eq!(&gif[..6], b"GIF89a");
        assert_eq!(u16::from_le_bytes([gif[6], gif[7]]), 1);
        assert_eq!(u16::from_le_bytes([gif[8], gif[9]]), 1);
        assert_eq!(gif[22] & 1, 1, "the graphic control extension sets transparency");
        assert_eq!(gif[25], 0, "colour 0 is the transparent one");
        assert_eq!(*gif.last().unwrap(), 0x3b);
    }

    /// Reads the PNG back chunk by chunk, checking each CRC, and inflates
    /// its one stored block.
    fn read_png(png: &[u8]) -> (u32, u32, Vec<u8>) {
        assert_eq!(&png[..8], &[0x89, b'P', b'N', b'G', 0x0d, 0x0a, 0x1a, 0x0a]);
        let mut at = 8;
        let (mut width, mut height, mut raw, mut kinds) = (0, 0, Vec::new(), Vec::new());
        while at < png.len() {
            let len = u32::from_be_bytes(png[at..at + 4].try_into().unwrap()) as usize;
            let kind = &png[at + 4..at + 8];
            let data = &png[at + 8..at + 8 + len];
            let crc = u32::from_be_bytes(png[at + 8 + len..at + 12 + len].try_into().unwrap());
            assert_eq!(crc32(&png[at + 4..at + 8 + len]), crc);
            match kind {
                b"IHDR" => {
                    width = u32::from_be_bytes(data[..4].try_into().unwrap());
                    height = u32::from_be_bytes(data[4..8].try_into().unwrap());
                    assert_eq!(&data[8..], &[8, 6, 0, 0, 0]);
                }
                b"IDAT" => {
                    assert_eq!(&data[..2], &[0x78, 0x01]);
                    assert_eq!(u16::from_be_bytes([data[0], data[1]]) % 31, 0, "zlib FCHECK");
                    assert_eq!(data[2], 0x01, "one final stored block");
                    let n = u16::from_le_bytes([data[3], data[4]]);
                    assert_eq!(!n, u16::from_le_bytes([data[5], data[6]]));
                    raw = data[7..7 + n as usize].to_vec();
                    let adler = u32::from_be_bytes(data[7 + n as usize..].try_into().unwrap());
                    assert_eq!(adler32(&raw), adler);
                }
                _ => {}
            }
            kinds.push(kind.to_vec());
            at += 12 + len;
        }
        assert_eq!(kinds, [b"IHDR".to_vec(), b"IDAT".to_vec(), b"IEND".to_vec()]);
        (width, height, raw)
    }

    #[test]
    fn each_png_is_its_size_in_transparent_pixels() {
        for (w, h) in [(2, 2), (3, 2), (32, 32)] {
            let (width, height, raw) = read_png(&transparent_png(w, h));
            assert_eq!((width, height), (w, h));
            assert_eq!(raw.len(), (1 + 4 * w as usize) * h as usize);
            assert!(raw.iter().all(|&b| b == 0), "filter 0 and alpha 0 everywhere");
        }
    }

    #[test]
    fn each_mp3_is_silence_as_long_as_its_name_says() {
        let mut checked = 0;
        for stub in STUBS {
            let Body::SilentMp3 { seconds } = stub.body else { continue };
            assert_eq!(stub.name, format!("noop-{seconds}s.mp3"));
            let mp3 = stub.body.bytes();
            assert_eq!(mp3.len() % 104, 0, "whole frames of 104 bytes");
            for frame in mp3.chunks(104) {
                assert_eq!(&frame[..4], &[0xff, 0xfb, 0x10, 0xc0]);
                assert!(frame[4..].iter().all(|&b| b == 0));
            }
            let duration = (mp3.len() / 104) as f64 * 1152.0 / 44_100.0;
            assert!((duration - seconds).abs() <= 1152.0 / 44_100.0 / 2.0,
                "{} lasts {duration}s", stub.name);
            checked += 1;
        }
        assert_eq!(checked, 2);
    }

    /// The boxes laid end to end in [bytes], each its kind and payload.
    fn boxes(bytes: &[u8]) -> Vec<(&[u8], &[u8])> {
        let mut out = Vec::new();
        let mut at = 0;
        while at < bytes.len() {
            let len = u32_at(bytes, at) as usize;
            assert!(len >= 8 && at + len <= bytes.len(), "the box at {at} runs past its parent");
            out.push((&bytes[at + 4..at + 8], &bytes[at + 8..at + len]));
            at += len;
        }
        out
    }

    /// The payloads of the boxes in [bytes], which are exactly [kinds].
    fn children<'a>(bytes: &'a [u8], kinds: &[&[u8; 4]]) -> Vec<&'a [u8]> {
        let found = boxes(bytes);
        let got: Vec<&[u8]> = found.iter().map(|(kind, _)| *kind).collect();
        let want: Vec<&[u8]> = kinds.iter().map(|k| &k[..]).collect();
        assert_eq!(got, want);
        found.into_iter().map(|(_, payload)| payload).collect()
    }

    fn u32_at(bytes: &[u8], at: usize) -> u32 {
        u32::from_be_bytes(bytes[at..at + 4].try_into().unwrap())
    }

    #[test]
    fn the_mp4_is_a_second_of_the_mp3_silence() {
        let stub = STUBS.iter().find(|s| matches!(s.body, Body::SilentMp4 { .. })).unwrap();
        let Body::SilentMp4 { seconds } = stub.body else { unreachable!() };
        assert_eq!(stub.name, format!("noop-{seconds}s.mp4"));
        let mp4 = stub.body.bytes();
        let [ftyp, moov, mdat] = children(&mp4, &[b"ftyp", b"moov", b"mdat"])[..] else { unreachable!() };
        assert_eq!(&ftyp[..4], b"isom");

        let [mvhd, trak] = children(moov, &[b"mvhd", b"trak"])[..] else { unreachable!() };
        let [tkhd, mdia] = children(trak, &[b"tkhd", b"mdia"])[..] else { unreachable!() };
        let [mdhd, hdlr, minf] = children(mdia, &[b"mdhd", b"hdlr", b"minf"])[..] else { unreachable!() };
        let [_, _, stbl] = children(minf, &[b"smhd", b"dinf", b"stbl"])[..] else { unreachable!() };
        let [stsd, stts, stsc, stsz, stco] =
            children(stbl, &[b"stsd", b"stts", b"stsc", b"stsz", b"stco"])[..] else { unreachable!() };

        // the frames: each a silent MP3 frame, as many as the tables count
        assert_eq!(mdat, &silent_mp3(seconds)[..]);
        let frames = (mdat.len() / MP3_FRAME_LEN) as u32;
        assert_eq!(&stts[4..], &[1, frames, 1152].map(u32::to_be_bytes).concat()[..], "one run of 1152-sample frames");
        assert_eq!(&stsc[4..], &[1, 1, frames, 1].map(u32::to_be_bytes).concat()[..], "one chunk of every frame");
        assert_eq!(&stsz[4..], &[104, frames].map(u32::to_be_bytes).concat()[..], "every frame 104 bytes");
        assert_eq!(&stco[4..8], &1u32.to_be_bytes());
        let mdat_at = mp4.len() - mdat.len();
        assert_eq!(u32_at(stco, 8) as usize, mdat_at, "the chunk starts where mdat's data does");

        // the clocks: the media's in samples, the movie's and the track's in ms
        assert_eq!(u32_at(mdhd, 12), 44_100);
        let samples = u32_at(mdhd, 16);
        assert_eq!(samples, frames * 1152);
        assert!((samples as f64 / 44_100.0 - seconds).abs() <= 1152.0 / 44_100.0 / 2.0,
            "lasts the nearest whole frames to {seconds}s");
        assert_eq!(u32_at(mvhd, 12), 1000);
        let millis = u32_at(mvhd, 16);
        assert_eq!(millis, (samples as f64 * 1000.0 / 44_100.0).round() as u32);
        assert_eq!(u32_at(tkhd, 0) & 0xff_ffff, 3, "the track is enabled and in the movie");
        assert_eq!(u32_at(tkhd, 12), 1, "track 1");
        assert_eq!(u32_at(tkhd, 20), millis);
        assert_eq!(u32_at(mvhd, 96), 2, "the next track id");
        assert_eq!(&hdlr[8..12], b"soun");

        // the sample entry: MP3 (object type 0x6B), one channel at 44.1 kHz
        assert_eq!(u32_at(stsd, 4), 1, "one sample entry");
        let [mp4a] = children(&stsd[8..], &[b"mp4a"])[..] else { unreachable!() };
        assert_eq!(&mp4a[6..8], &1u16.to_be_bytes(), "data reference 1");
        assert_eq!(&mp4a[16..18], &1u16.to_be_bytes(), "one channel");
        assert_eq!(u32_at(mp4a, 24) >> 16, 44_100);
        let [esds] = children(&mp4a[28..], &[b"esds"])[..] else { unreachable!() };
        let es = &esds[4..];
        assert_eq!((es[0], es[1] as usize), (3, es.len() - 2), "an ES descriptor, the whole box");
        let decoder = &es[5..];
        assert_eq!((decoder[0], decoder[2], decoder[3] >> 2), (4, 0x6b, 5), "MPEG-1 audio, an audio stream");
        assert_eq!(&decoder[2 + decoder[1] as usize..], &[6, 1, 2], "then the SL config MP4 files carry");
    }

    // build.rs takes each surrogate as surrogates.tsv pins it; this holds what
    // the library compiled in to the same table, read apart from build.rs.
    #[test]
    fn each_surrogate_is_the_file_surrogates_tsv_pins_cb_010() {
        let mut served = 0;
        for line in include_str!("../surrogates.tsv").lines().filter(|l| !l.is_empty() && !l.starts_with('#')) {
            let cols: Vec<&str> = line.split('\t').collect();
            let Some(names) = cols.get(2) else { continue };
            let mut names = names.split_whitespace();
            let name = names.next().unwrap();
            let stub = SURROGATES.iter().find(|s| s.name == name)
                .unwrap_or_else(|| panic!("{name}, {}, is not in the pool", cols[0]));
            assert_eq!(stub.aliases, names.collect::<Vec<_>>(), "{name}'s aliases");
            assert_eq!(crate::sha256::sha256_hex(&stub.body.bytes()), cols[1], "{name} is not {}", cols[0]);
            assert_eq!(stub.mime, MimeType::ApplicationJavascript, "{name}");
            served += 1;
        }
        assert!(served > 0, "surrogates.tsv names no script");
        assert_eq!(SURROGATES.len(), served, "a surrogate surrogates.tsv does not name");
    }

    #[test]
    fn each_script_in_resources_is_served_under_its_name_cb_010() {
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("resources");
        let mut files: Vec<_> = std::fs::read_dir(&dir).unwrap().map(|e| e.unwrap().path()).collect();
        files.sort();
        assert!(!files.is_empty(), "{} holds no script", dir.display());
        for file in files {
            let name = file.file_name().unwrap().to_str().unwrap();
            let stub = STUBS.iter().find(|s| s.name == name)
                .unwrap_or_else(|| panic!("resources/{name} is served under no name"));
            assert_eq!(stub.body.bytes(), std::fs::read(&file).unwrap(), "{name} is served another body");
            assert_eq!(stub.mime, MimeType::ApplicationJavascript, "{name}");
        }
    }
}
