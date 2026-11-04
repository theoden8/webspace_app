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
//     value, a transparent image, a silent sound, an empty ad playlist, made
//     here;
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
}

const STUBS: &[Stub] = &[
    Stub { name: "noop.js", aliases: &["noopjs", "abp-resource:blank-js"],
        mime: MimeType::ApplicationJavascript, body: Body::Text("(function() {})();\n") },
    Stub { name: "noop.html", aliases: &["noopframe"],
        mime: MimeType::TextHtml,
        body: Body::Text("<!DOCTYPE html>\n<html><head></head><body></body></html>\n") },
    Stub { name: "noop.txt", aliases: &["nooptext"],
        mime: MimeType::TextPlain, body: Body::Text("") },
    Stub { name: "empty", aliases: &[],
        mime: MimeType::TextPlain, body: Body::Text("") },
    Stub { name: "noop.css", aliases: &[],
        mime: MimeType::TextCss, body: Body::Text("") },
    Stub { name: "noop.json", aliases: &["noopjson"],
        mime: MimeType::ApplicationJson, body: Body::Text("{}\n") },
    // IAB VMAP 1.0: a playlist with no ad breaks.
    Stub { name: "noop-vmap1.0.xml", aliases: &["noopvmap-1.0"],
        mime: MimeType::TextXml,
        body: Body::Text("<vmap:VMAP xmlns:vmap=\"http://www.iab.net/videosuite/vmap\" version=\"1.0\"></vmap:VMAP>\n") },
    Stub { name: "1x1.gif", aliases: &["1x1-transparent.gif"],
        mime: MimeType::ImageGif, body: Body::Gif },
    Stub { name: "2x2.png", aliases: &["2x2-transparent.png"],
        mime: MimeType::ImagePng, body: Body::Png { width: 2, height: 2 } },
    Stub { name: "3x2.png", aliases: &["3x2-transparent.png"],
        mime: MimeType::ImagePng, body: Body::Png { width: 3, height: 2 } },
    Stub { name: "32x32.png", aliases: &["32x32-transparent.png"],
        mime: MimeType::ImagePng, body: Body::Png { width: 32, height: 32 } },
    Stub { name: "noop-0.1s.mp3", aliases: &["noopmp3-0.1s", "abp-resource:blank-mp3"],
        mime: MimeType::AudioMp3, body: Body::SilentMp3 { seconds: 0.1 } },
    Stub { name: "noop-0.5s.mp3", aliases: &[],
        mime: MimeType::AudioMp3, body: Body::SilentMp3 { seconds: 0.5 } },
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
const MP3_FRAME_LEN: usize = 144 * 32_000 / 44_100;
const MP3_FRAME_SECONDS: f64 = 1152.0 / 44_100.0;

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
