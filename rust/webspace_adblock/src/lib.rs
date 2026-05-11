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
use adblock::resources::Resource;

/// adblock-rust resource bundle, fetched at build time from
/// github.com/brave/adblock-resources at a pinned commit (see
/// `build.rs`). Empty `[]` when the fetcher couldn't reach the
/// upstream (offline build) — engine then runs without
/// `$redirect=` support. Pre-baked into the .so via `include_str!`;
/// no runtime file IO, no committed third-party data.
const UBO_RESOURCES_JSON: &str = include_str!(
    concat!(env!("OUT_DIR"), "/ubo_resources.json")
);

fn load_ubo_resources() -> Vec<Resource> {
    serde_json::from_str(UBO_RESOURCES_JSON).unwrap_or_else(|e| {
        eprintln!(
            "[webspace_adblock] failed to parse embedded uBO resources: {} — \
             $redirect= rules will silently miss",
            e
        );
        Vec::new()
    })
}

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
    let mut engine = AdblockEngine::from_filter_set(filter_set, true);
    let resources = load_ubo_resources();
    if !resources.is_empty() {
        engine.use_resources(resources);
    }
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

/// Per-request redirect lookup. Returns the redirect resource as a
/// `data:` URL string when:
///   * a network filter matches this URL, AND
///   * the matched filter carries a `$redirect=` (or `$redirect-rule=`)
///     option pointing at a resource present in the loaded pool.
///
/// Callers should invoke this AFTER a positive [`ws_engine_check_url`]
/// to decide whether the blocked response should be served as an
/// empty body (no redirect) or as the resource body extracted from
/// the data URL. The data URL format is
/// `data:<mime>;base64,<encoded-body>` — callers split on the first
/// `;base64,` to extract MIME + base64 body.
///
/// Caller must free the returned pointer with [`ws_string_free`].
/// Returns null when no redirect applies, on bad arguments, or on
/// internal error.
#[no_mangle]
pub extern "C" fn ws_engine_redirect_for(
    engine: *mut Engine,
    url: *const c_char,
    url_len: usize,
    source_url: *const c_char,
    source_url_len: usize,
    request_type: *const c_char,
    request_type_len: usize,
) -> *mut c_char {
    if engine.is_null() || url.is_null() {
        return std::ptr::null_mut();
    }
    let engine_ref = unsafe { &(*engine).inner };

    let url_s = match read_utf8(url, url_len) {
        Some(s) => s,
        None => return std::ptr::null_mut(),
    };
    let src_s = read_utf8(source_url, source_url_len).unwrap_or("");
    let typ_raw = read_utf8(request_type, request_type_len).unwrap_or("other");
    let typ_s: &str = if typ_raw.is_empty() { "other" } else { typ_raw };

    let request = match Request::new(url_s, src_s, typ_s) {
        Ok(r) => r,
        Err(_) => return std::ptr::null_mut(),
    };
    let result = engine_ref.check_network_request(&request);
    match result.redirect {
        Some(data_url) => CString::new(data_url)
            .ok()
            .map(|c| c.into_raw())
            .unwrap_or(std::ptr::null_mut()),
        None => std::ptr::null_mut(),
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

/// Apple WKContentRuleList JSON export. Converts an ABP filter list
/// into the JSON format that `WKContentRuleListStore.compileContentRuleList`
/// accepts. The Pod hook on iOS/macOS compiles the result into WebKit
/// bytecode at install time, giving native sub-resource blocking
/// without a JS bridge round-trip.
///
/// Trade-off: WebKit fires NO callback when a rule matches (Apple's
/// privacy design), so per-request stats stay on the JS-bridge path
/// — the content rule list is an additive accelerator, not a
/// replacement for the existing pipeline.
///
/// Takes a UTF-8 filter list (same input as `ws_engine_new`) and
/// returns a JSON string. Caller must free with [`ws_string_free`].
/// Returns null on UTF-8 / parser failure.
#[no_mangle]
pub extern "C" fn ws_filters_to_content_blocking_json(
    rules_text: *const c_char,
    len: usize,
) -> *mut c_char {
    if rules_text.is_null() {
        return std::ptr::null_mut();
    }
    let bytes = unsafe { std::slice::from_raw_parts(rules_text as *const u8, len) };
    let text = match std::str::from_utf8(bytes) {
        Ok(s) => s,
        Err(_) => return std::ptr::null_mut(),
    };

    // `into_content_blocking` requires the FilterSet to be in debug
    // mode (carries source filter strings) so it can emit them in
    // the JSON action payload. Build a fresh FilterSet for the
    // conversion rather than reusing the runtime engine's optimised
    // (non-debug) one.
    let mut filter_set = FilterSet::new(true);
    filter_set.add_filter_list(text, ParseOptions::default());
    let rules = match filter_set.into_content_blocking() {
        Ok((rules, _used)) => rules,
        Err(_) => return std::ptr::null_mut(),
    };
    match serde_json::to_string(&rules) {
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
    fn redirect_rules_return_data_url_when_resources_loaded() {
        // With uBO's web_accessible_resources vendored + loaded via
        // engine.use_resources(...) in `ws_engine_new`, a rule like
        // `$redirect=noopjs` should surface the redirect resource on
        // matching requests. Without resources the redirect field
        // stays None and the rule silently degrades to "drop the
        // request" — exactly what we want to avoid for sites that
        // probe for the replacement library.
        let engine_ptr = rules_to_engine("||tracker.example.com^$redirect=noopjs\n");
        // We can't easily probe `BlockerResult.redirect` through the
        // existing FFI (which collapses to 0/1), so reach into the
        // engine directly. Internal-API test only.
        let engine = unsafe { &(*engine_ptr).inner };
        let request = adblock::request::Request::new(
            "https://tracker.example.com/foo.js",
            "https://news.com/",
            "script",
        ).unwrap();
        let result = engine.check_network_request(&request);
        assert!(result.matched, "rule must match");
        assert!(result.redirect.is_some(),
            "engine.use_resources(...) must populate the resource pool — \
             redirect was None despite ubo_resources.json being included. \
             Did the embedded JSON parse fail?");
        let redirect = result.redirect.unwrap();
        assert!(redirect.starts_with("data:"),
            "redirect must be a data: URL; got: {}",
            &redirect[..redirect.len().min(80)]);
        ws_engine_free(engine_ptr);
    }

    #[test]
    fn content_blocking_json_export() {
        // Mirrors `WKContentRuleListStore.compileContentRuleList`'s
        // expected JSON shape: array of {action, trigger} objects.
        let rules = "||doubleclick.net^\n||tracker.com^$third-party\n##.ad\n";
        let ptr = ws_filters_to_content_blocking_json(
            rules.as_ptr() as *const c_char,
            rules.len(),
        );
        assert!(!ptr.is_null(), "content_blocking conversion returned null");
        let json = unsafe { CStr::from_ptr(ptr) }.to_str().unwrap().to_owned();
        ws_string_free(ptr);

        // It IS a JSON array.
        assert!(json.starts_with('['), "payload: {}", json);
        // The Apple format wraps every rule in `{"action": ..., "trigger": ...}`.
        assert!(json.contains("\"action\""), "payload: {}", json);
        assert!(json.contains("\"trigger\""), "payload: {}", json);
        // doubleclick should map to a block action.
        assert!(json.contains("doubleclick"), "payload: {}", json);
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
