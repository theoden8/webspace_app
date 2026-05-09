// SPDX-License-Identifier: MPL-2.0
//
// C FFI surface around Brave's `adblock` crate, tailored for WebSpace.
//
// The Dart side (`lib/services/adblock_engine.dart`) calls these
// functions through `dart:ffi`. Surface is deliberately small:
//
//   * `ws_engine_new` — parse a filter list into an engine instance.
//   * `ws_engine_free` — drop the engine.
//   * `ws_engine_check_url` — block/allow decision for one request.
//   * `ws_engine_cosmetic_resources_json` — per-URL hide selectors,
//     style rules, exceptions, and (currently ignored) scriptlets,
//     marshalled as a JSON string the Dart side parses.
//   * `ws_string_free` — release a string allocated by this library.
//
// Memory rules: every `*const c_char` returned to the caller MUST be
// freed via `ws_string_free`. Engines are heap-allocated boxes; only
// release them with `ws_engine_free`. Strings passed *in* live as
// long as the caller keeps them alive — we copy what we need.

#![allow(clippy::not_unsafe_ptr_arg_deref)]

use std::ffi::{c_char, CString};
#[cfg(test)]
use std::ffi::CStr;

#[cfg(target_os = "android")]
mod jni;
use std::slice;

use adblock::Engine as AdblockEngine;
use adblock::lists::{FilterSet, ParseOptions};
use adblock::request::Request;

/// Opaque engine handle. Heap-allocated via `Box`; the C side sees
/// only a `*mut Engine` and never dereferences it. cbindgen prefixes
/// this to `WsEngine` in the generated header.
pub struct Engine {
    inner: AdblockEngine,
}

/// Parse [rules_text] (a UTF-8 filter list, lines separated by `\n`)
/// into a new engine. Returns null on UTF-8 error or panic.
///
/// `rules_text` must point to `len` bytes. Caller retains ownership;
/// we copy into the engine.
#[no_mangle]
pub extern "C" fn ws_engine_new(
    rules_text: *const c_char,
    len: usize,
) -> *mut Engine {
    if rules_text.is_null() {
        return std::ptr::null_mut();
    }
    let bytes = unsafe { slice::from_raw_parts(rules_text as *const u8, len) };
    let text = match std::str::from_utf8(bytes) {
        Ok(s) => s,
        Err(_) => return std::ptr::null_mut(),
    };

    // No catch_unwind: release builds set `panic = "abort"`, so a
    // panic here aborts the process before crossing the FFI boundary.
    // Test builds let the panic surface as a failure, which is what
    // we want.
    let mut filter_set = FilterSet::new(false);
    filter_set.add_filter_list(text, ParseOptions::default());
    let engine = AdblockEngine::from_filter_set(filter_set, true);
    Box::into_raw(Box::new(Engine { inner: engine }))
}

/// Drop the engine. Safe to call with a null pointer (no-op).
#[no_mangle]
pub extern "C" fn ws_engine_free(engine: *mut Engine) {
    if engine.is_null() {
        return;
    }
    unsafe {
        drop(Box::from_raw(engine));
    }
}

/// Block-decision check. Mirrors `adblock::Engine::check_network_request`
/// but with C-friendly arguments.
///
/// `source_url` and `request_type` may be empty strings (length 0,
/// any pointer); the engine will degrade gracefully — `request_type`
/// of "" is treated as "other".
///
/// Returns:
///   * `1` — request matched a block rule, no exception in effect
///   * `0` — request allowed (no match, or matched + exception)
///   * `-1` — bad arguments / panic
#[no_mangle]
pub extern "C" fn ws_engine_check_url(
    engine: *mut Engine,
    url: *const c_char,
    url_len: usize,
    source_url: *const c_char,
    source_url_len: usize,
    request_type: *const c_char,
    request_type_len: usize,
) -> i32 {
    if engine.is_null() || url.is_null() {
        return -1;
    }
    let engine_ref = unsafe { &(*engine).inner };

    let url_s = match read_utf8(url, url_len) {
        Some(s) => s,
        None => return -1,
    };
    let src_s = read_utf8(source_url, source_url_len).unwrap_or("");
    let typ_s = read_utf8(request_type, request_type_len).unwrap_or("other");

    let request = match Request::new(url_s, src_s, typ_s) {
        Ok(r) => r,
        Err(_) => return -1,
    };
    let res = engine_ref.check_network_request(&request);
    if res.matched && res.exception.is_none() {
        1
    } else {
        0
    }
}

/// Per-URL cosmetic resources, JSON-encoded. The shape is:
/// ```json
/// {
///   "hide_selectors": ["sel", ...],
///   "style_selectors": {".sel": ["height:1px !important", ...], ...},
///   "exceptions": ["sel", ...],
///   "injected_script": "...",
///   "generichide": false
/// }
/// ```
/// Caller must free the returned pointer with [`ws_string_free`].
/// Returns null on error.
#[no_mangle]
pub extern "C" fn ws_engine_cosmetic_resources_json(
    engine: *mut Engine,
    url: *const c_char,
    url_len: usize,
) -> *mut c_char {
    if engine.is_null() || url.is_null() {
        return std::ptr::null_mut();
    }
    let engine_ref = unsafe { &(*engine).inner };
    let url_s = match read_utf8(url, url_len) {
        Some(s) => s,
        None => return std::ptr::null_mut(),
    };

    let resources = engine_ref.url_cosmetic_resources(url_s);
    match serde_json::to_string(&resources) {
        Ok(s) => CString::new(s)
            .ok()
            .map(|c| c.into_raw())
            .unwrap_or(std::ptr::null_mut()),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Generic cosmetic-selector lookup. Returns a JSON array of selector
/// strings drawn from the engine's generic cosmetic ruleset that match
/// at least one of the page's [classes] or [ids].
///
/// This is the second half of the cosmetic story: domain-scoped rules
/// come from `ws_engine_cosmetic_resources_json`; generic `##.ad`-style
/// rules are kept out of that response (a busy filter list has tens
/// of thousands of them) and surfaced here only when the page actually
/// uses a class/id they target. Caller workflow:
///   1. JS scans the loaded DOM, collects unique classes and ids.
///   2. Sends them across the FFI as JSON arrays of strings.
///   3. Receives back the matching selectors and injects them into
///      a `<style>` tag the same way DOMAIN-SCOPED rules are handled.
///
/// `exceptions_json` is the `exceptions` array from the prior call to
/// `ws_engine_cosmetic_resources_json` — pass an empty array `[]` if
/// you don't have one.
///
/// Caller must free the returned pointer with [`ws_string_free`].
/// Returns null on error.
#[no_mangle]
pub extern "C" fn ws_engine_hidden_class_id_selectors_json(
    engine: *mut Engine,
    classes_json: *const c_char,
    classes_len: usize,
    ids_json: *const c_char,
    ids_len: usize,
    exceptions_json: *const c_char,
    exceptions_len: usize,
) -> *mut c_char {
    if engine.is_null() {
        return std::ptr::null_mut();
    }
    let engine_ref = unsafe { &(*engine).inner };

    let classes_s = match read_utf8(classes_json, classes_len) {
        Some(s) => s,
        None => return std::ptr::null_mut(),
    };
    let ids_s = match read_utf8(ids_json, ids_len) {
        Some(s) => s,
        None => return std::ptr::null_mut(),
    };
    let exceptions_s = read_utf8(exceptions_json, exceptions_len).unwrap_or("[]");

    let classes: Vec<String> = match serde_json::from_str(classes_s) {
        Ok(v) => v,
        Err(_) => return std::ptr::null_mut(),
    };
    let ids: Vec<String> = match serde_json::from_str(ids_s) {
        Ok(v) => v,
        Err(_) => return std::ptr::null_mut(),
    };
    let exceptions: std::collections::HashSet<String> =
        match serde_json::from_str(exceptions_s) {
            Ok(v) => v,
            Err(_) => return std::ptr::null_mut(),
        };

    let selectors = engine_ref.hidden_class_id_selectors(&classes, &ids, &exceptions);
    match serde_json::to_string(&selectors) {
        Ok(s) => CString::new(s)
            .ok()
            .map(|c| c.into_raw())
            .unwrap_or(std::ptr::null_mut()),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Free a string returned by this library. Safe with null.
#[no_mangle]
pub extern "C" fn ws_string_free(s: *mut c_char) {
    if s.is_null() {
        return;
    }
    unsafe {
        drop(CString::from_raw(s));
    }
}

/// Get the engine's library version string. Useful for debugging
/// "which adblock-rust am I running" without rebuilding.
/// Caller must free with [`ws_string_free`].
#[no_mangle]
pub extern "C" fn ws_engine_version() -> *mut c_char {
    let v = format!("webspace_adblock/{} adblock/{}",
        env!("CARGO_PKG_VERSION"),
        adblock_version());
    CString::new(v).ok().map(|c| c.into_raw()).unwrap_or(std::ptr::null_mut())
}

fn adblock_version() -> &'static str {
    // The `adblock` crate doesn't expose its version at runtime, so
    // we pull it from Cargo.lock at build time via env! — but that
    // requires it actually being our direct dep, which it is. The
    // CARGO_PKG_<dep> envs are only for the package itself, so use
    // the static string baked at compile-time via build.rs would be
    // cleanest. For the spike, just hardcode-track the dep version.
    "0.12"
}

fn read_utf8<'a>(ptr: *const c_char, len: usize) -> Option<&'a str> {
    if ptr.is_null() {
        // Treat null + 0 length as empty string; null + len > 0 is bad.
        return if len == 0 { Some("") } else { None };
    }
    let bytes = unsafe { slice::from_raw_parts(ptr as *const u8, len) };
    std::str::from_utf8(bytes).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rules_to_engine(text: &str) -> *mut Engine {
        ws_engine_new(text.as_ptr() as *const c_char, text.len())
    }

    fn check(engine: *mut Engine, url: &str, source: &str) -> i32 {
        ws_engine_check_url(
            engine,
            url.as_ptr() as *const c_char,
            url.len(),
            source.as_ptr() as *const c_char,
            source.len(),
            "other".as_ptr() as *const c_char,
            5,
        )
    }

    #[test]
    fn parses_simple_domain_rule() {
        let engine = rules_to_engine("||example.com^\n");
        assert!(!engine.is_null());
        assert_eq!(check(engine, "https://example.com/x", "https://news.com/"), 1);
        assert_eq!(check(engine, "https://other.com/x", "https://news.com/"), 0);
        ws_engine_free(engine);
    }

    #[test]
    fn honors_path_anchor() {
        let engine = rules_to_engine("||example.com/ads/\n");
        assert_eq!(check(engine, "https://example.com/ads/banner.png", "https://news.com/"), 1);
        assert_eq!(check(engine, "https://example.com/news/", "https://news.com/"), 0);
        ws_engine_free(engine);
    }

    #[test]
    fn honors_domain_modifier() {
        // The whole point of using a real engine: $domain= just works.
        let engine = rules_to_engine("||tracker.com^$domain=news.com\n");
        assert_eq!(check(engine, "https://tracker.com/x", "https://news.com/"), 1);
        assert_eq!(check(engine, "https://tracker.com/x", "https://blog.com/"), 0);
        ws_engine_free(engine);
    }

    #[test]
    fn null_engine_safe() {
        ws_engine_free(std::ptr::null_mut());
        assert_eq!(check(std::ptr::null_mut(), "https://x.com/", "https://y.com/"), -1);
    }

    #[test]
    fn hidden_class_id_selectors_returns_matching_selectors() {
        // Generic cosmetic rules (no domain prefix) live in a separate
        // bucket the engine surfaces only on demand. The page tells
        // the engine which classes/ids it actually uses; the engine
        // returns the selectors that target them.
        let rules = "##.ad-banner\n##.unrelated\n##.foo:has(.bar)\n";
        let engine = rules_to_engine(rules);

        let classes_json = "[\"ad-banner\",\"foo\"]";
        let ids_json = "[]";
        let exceptions_json = "[]";

        let ptr = ws_engine_hidden_class_id_selectors_json(
            engine,
            classes_json.as_ptr() as *const c_char,
            classes_json.len(),
            ids_json.as_ptr() as *const c_char,
            ids_json.len(),
            exceptions_json.as_ptr() as *const c_char,
            exceptions_json.len(),
        );
        assert!(!ptr.is_null());
        let json = unsafe { CStr::from_ptr(ptr) }.to_str().unwrap().to_owned();
        // Must include rules that target classes the page uses, NOT
        // include `.unrelated` (the page didn't list "unrelated").
        assert!(json.contains(".ad-banner"), "payload was: {}", json);
        assert!(!json.contains(".unrelated"), "payload was: {}", json);
        ws_string_free(ptr);
        ws_engine_free(engine);
    }

    #[test]
    fn cosmetic_resources_json_returns_payload() {
        // url_cosmetic_resources only returns DOMAIN-SPECIFIC cosmetic
        // rules. Generic `##.ad` rules go through a separate
        // class/id-aware path that the JS shim drives once the page
        // is parsed. Test with a domain-scoped rule to exercise the
        // FFI; generic-selector handling is wired up later.
        let engine = rules_to_engine("example.com##.feed-promo\n");
        let url = "https://example.com/";
        let ptr = ws_engine_cosmetic_resources_json(
            engine,
            url.as_ptr() as *const c_char,
            url.len(),
        );
        assert!(!ptr.is_null());
        let json = unsafe { CStr::from_ptr(ptr) }.to_str().unwrap().to_owned();
        assert!(json.contains(".feed-promo"), "payload was: {}", json);
        ws_string_free(ptr);
        ws_engine_free(engine);
    }
}
