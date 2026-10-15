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

use adblock::content_blocking::{CbRule, CbType};
use adblock::filters::network::{NetworkFilter, NetworkFilterMask};
use adblock::Engine as AdblockEngine;
use adblock::lists::{FilterSet, ParseOptions, RuleTypes};
use adblock::request::Request;
use adblock::resources::Resource;

/// adblock-rust resource bundle, fetched at build time from
/// github.com/brave/adblock-resources at a pinned commit (see
/// `build.rs`). Empty `[]` when the fetcher couldn't reach the
/// upstream (offline build) — engine then runs without
/// `$redirect=` support. Pre-baked into the .so via `include_str!`;
/// no runtime file IO, no committed third-party data.
/// JSON list of transitive Rust dependencies + SPDX licenses, produced
/// by build.rs via `cargo metadata`. Surfaced through
/// [`ws_dep_licenses_json`].
const DEP_LICENSES_JSON: &str = include_str!(
    concat!(env!("OUT_DIR"), "/dep_licenses.json")
);

/// Null-terminated copy of [`DEP_LICENSES_JSON`] for the C FFI.
/// Static, lives in .rodata for the process lifetime — caller MUST
/// NOT free.
static DEP_LICENSES_JSON_CSTR: std::sync::LazyLock<std::ffi::CString> =
    std::sync::LazyLock::new(|| {
        std::ffi::CString::new(DEP_LICENSES_JSON)
            .unwrap_or_else(|_| std::ffi::CString::new("[]").unwrap())
    });

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
    enable_ubo_resources: bool,
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
    filter_set.add_filter_list(text.to_string(), ParseOptions::default());
    let mut engine = AdblockEngine::new_with_filter_set(filter_set);
    // `enable_ubo_resources` gates the uBO web_accessible_resources pool
    // embedded at build time (see build.rs). When off, $redirect= rules
    // become drop-the-request (engine.redirect_for returns None for every
    // URL). Useful when a downstream wants the rule engine without the
    // bundled resource payload — e.g. a paranoid user who'd rather see
    // empty bodies than a stub from a third-party tarball.
    if enable_ubo_resources {
        let resources = load_ubo_resources();
        if !resources.is_empty() {
            engine.use_resources(resources);
        }
    }
    Box::into_raw(Box::new(Engine { inner: engine }))
}

/// Build an engine from the binary blob produced by [`ws_engine_serialize`].
/// Skips the multi-megabyte ABP rule parse — same observable engine
/// state, just hydrated from flatbuffers instead of text. The uBO
/// resource pool is not part of the serialized format, so we re-apply
/// it here (gated on `enable_ubo_resources` the same way `ws_engine_new`
/// is).
///
/// Returns null on UTF-8/flatbuffer parse failure, on a panic, or when
/// the serialized blob came from an incompatible adblock-rust version.
/// Caller must treat null as "cache miss, fall back to parse" — never
/// abort.
#[no_mangle]
pub extern "C" fn ws_engine_new_from_serialized(
    bytes: *const u8,
    len: usize,
    enable_ubo_resources: bool,
) -> *mut Engine {
    if bytes.is_null() || len == 0 {
        return std::ptr::null_mut();
    }
    let blob = unsafe { slice::from_raw_parts(bytes, len) };
    // Build a fresh empty engine then deserialize into it — matches the
    // adblock-rust API shape (`Engine::deserialize(&mut self, ...)`).
    let mut engine =
        AdblockEngine::new_with_filter_set(FilterSet::new(false));
    if engine.deserialize(blob).is_err() {
        return std::ptr::null_mut();
    }
    if enable_ubo_resources {
        let resources = load_ubo_resources();
        if !resources.is_empty() {
            engine.use_resources(resources);
        }
    }
    Box::into_raw(Box::new(Engine { inner: engine }))
}

/// Serialize the engine state to a flatbuffer blob suitable for
/// rehydration via [`ws_engine_new_from_serialized`]. Writes the
/// resulting byte count to `out_len`. The returned pointer is owned
/// by the caller and MUST be released with [`ws_buf_free`].
///
/// On any error (null engine, panic), returns null and leaves `out_len`
/// untouched.
///
/// Note: the format includes a self-describing version stamp; later
/// adblock-rust releases may bump it. A rehydration mismatch surfaces
/// as null from `ws_engine_new_from_serialized`; the caller falls back
/// to text parsing.
#[no_mangle]
pub extern "C" fn ws_engine_serialize(
    engine: *mut Engine,
    out_len: *mut usize,
) -> *mut u8 {
    if engine.is_null() || out_len.is_null() {
        return std::ptr::null_mut();
    }
    let engine_ref = unsafe { &(*engine).inner };
    let blob = engine_ref.serialize();
    let len = blob.len();
    // Move the Vec into a heap allocation under our exclusive
    // ownership so the C side can free it via `ws_buf_free`.
    let mut boxed = blob.into_boxed_slice();
    let ptr = boxed.as_mut_ptr();
    std::mem::forget(boxed);
    unsafe {
        *out_len = len;
    }
    ptr
}

/// Release a buffer returned by [`ws_engine_serialize`]. Safe with null.
#[no_mangle]
pub extern "C" fn ws_buf_free(ptr: *mut u8, len: usize) {
    if ptr.is_null() || len == 0 {
        return;
    }
    unsafe {
        let slice = std::slice::from_raw_parts_mut(ptr, len);
        drop(Box::from_raw(slice as *mut [u8]));
    }
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

    let request = match Request::new(url_s, src_s, typ_s, "") {
        Ok(r) => r,
        Err(_) => return -1,
    };
    let res = engine_ref.check_network_request(&request);
    if res.should_block() {
        1
    } else {
        0
    }
}

/// Per-request `$removeparam=` lookup. Returns the rewritten URL when
/// adblock-rust would strip one or more query parameters from the
/// request URL. Returns null when no rewrite applies (no matching
/// filter, or the URL has no query string).
///
/// This is a SEPARATE call from [`ws_engine_check_url`] because the two
/// outcomes can co-occur — a URL can be both blocked AND rewritten if
/// two filters match. The caller decides priority. Typical pattern:
///   1. Check block — if blocked, drop / serve redirect body.
///   2. Else check rewrite — if rewritten, swap URL on the navigation.
///
/// Caller must free the returned pointer with [`ws_string_free`].
#[no_mangle]
pub extern "C" fn ws_engine_rewritten_url(
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

    let request = match Request::new(url_s, src_s, typ_s, "") {
        Ok(r) => r,
        Err(_) => return std::ptr::null_mut(),
    };
    let res = engine_ref.check_network_request(&request);
    match res.rewritten_url {
        Some(s) => CString::new(s)
            .map(|c| c.into_raw())
            .unwrap_or(std::ptr::null_mut()),
        None => std::ptr::null_mut(),
    }
}

/// Per-request `$csp=` lookup. Returns the joined CSP directives for
/// matching `$csp=...` rules at this URL — the caller injects them
/// into the response as `Content-Security-Policy` (Android response
/// header path) or as a `<meta http-equiv="Content-Security-Policy">`
/// tag (Apple, where we can't rewrite headers).
///
/// Returns null when no CSP applies. Caller must free with
/// [`ws_string_free`].
#[no_mangle]
pub extern "C" fn ws_engine_csp_for(
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

    let request = match Request::new(url_s, src_s, typ_s, "") {
        Ok(r) => r,
        Err(_) => return std::ptr::null_mut(),
    };
    match engine_ref.get_csp_directives(&request) {
        Some(s) if !s.is_empty() => CString::new(s)
            .map(|c| c.into_raw())
            .unwrap_or(std::ptr::null_mut()),
        _ => std::ptr::null_mut(),
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

    let request = match Request::new(url_s, src_s, typ_s, "") {
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

/// WebKit refuses a content rule list longer than this (`maxRuleCount` in
/// WebCore's `ContentExtensionParser.cpp`).
const WEBKIT_MAX_RULES: usize = 150_000;

/// The network rules in `text` as WebKit content rule lists, each at most
/// `max_rules` long, or `None` when the exceptions alone fill a list.
///
/// adblock-rust emits every block rule before every exception, and an
/// exception cancels only earlier rules of its own list, so each list is a
/// slice of the block rules followed by all of the exceptions. Cosmetic
/// rules are left to the page's cosmetic pass. `$method` rules are left out:
/// a WebKit rule without a `request-method` trigger blocks every method, and
/// WebKit before 7622 (iOS/macOS 26) ignores that trigger.
fn content_rule_lists(text: &str, max_rules: usize) -> Option<Vec<Vec<CbRule>>> {
    let kept: String = text
        .lines()
        .filter(|line| !restricts_method(line))
        .flat_map(|line| [line, "\n"])
        .collect();
    let mut filter_set = FilterSet::new(true);
    filter_set.add_filter_list(
        kept,
        ParseOptions { rule_types: RuleTypes::NetworkOnly, ..Default::default() },
    );
    let (rules, _used) = filter_set.into_content_blocking().ok()?;
    let first_exception = rules
        .iter()
        .position(|r| matches!(r.action.typ, CbType::IgnorePreviousRules))
        .unwrap_or(rules.len());
    let (blocks, exceptions) = rules.split_at(first_exception);
    debug_assert!(
        exceptions.iter().all(|r| matches!(r.action.typ, CbType::IgnorePreviousRules)),
        "adblock-rust emits exceptions after every block rule"
    );
    let room = max_rules.checked_sub(exceptions.len()).filter(|&n| n > 0)?;
    Some(
        blocks
            .chunks(room)
            .map(|chunk| [chunk, exceptions].concat())
            .collect(),
    )
}

fn restricts_method(line: &str) -> bool {
    line.to_ascii_lowercase().contains("method=")
        && NetworkFilter::parse(line, false, ParseOptions::default())
            .is_ok_and(|f| f.mask.intersects(NetworkFilterMask::FROM_ANY_METHODS))
}

/// WebKit content rule lists for a UTF-8 filter list (same input as
/// `ws_engine_new`), one compact JSON array per line, each ready for
/// `WKContentRuleListStore.compileContentRuleList`. An empty string when no
/// network rule converts. WebKit reports no match back, so blocking stats
/// stay with the page's interceptor; these lists only stop requests sooner.
///
/// Caller must free with [`ws_string_free`]. Null on invalid UTF-8, a parser
/// failure, or exceptions that alone exceed WebKit's rule cap.
#[no_mangle]
pub extern "C" fn ws_filters_to_content_rule_lists(
    rules_text: *const c_char,
    len: usize,
) -> *mut c_char {
    if rules_text.is_null() {
        return std::ptr::null_mut();
    }
    let bytes = unsafe { std::slice::from_raw_parts(rules_text as *const u8, len) };
    let Ok(text) = std::str::from_utf8(bytes) else {
        return std::ptr::null_mut();
    };
    let Some(lists) = content_rule_lists(text, WEBKIT_MAX_RULES) else {
        return std::ptr::null_mut();
    };
    let mut out = String::new();
    for list in &lists {
        let Ok(json) = serde_json::to_string(list) else {
            return std::ptr::null_mut();
        };
        out.push_str(&json);
        out.push('\n');
    }
    CString::new(out)
        .ok()
        .map(|c| c.into_raw())
        .unwrap_or(std::ptr::null_mut())
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

/// JSON-encoded list of the Rust-side transitive dependency tree
/// with SPDX licenses, produced at build time by `cargo metadata`
/// (see build.rs). Each entry:
///
///   {"name":"...","version":"...","license":"MIT OR Apache-2.0",
///    "repository":"https://github.com/...","description":"..."}
///
/// The Dart side reads this once and registers an entry per crate
/// in Flutter's LicenseRegistry — surfacing all transitive Rust
/// attribution in About → Open Source Licenses without us
/// vendoring any license text into the repo.
///
/// Static string baked at compile time — no allocation, just a
/// pointer to .rodata; do NOT free.
#[no_mangle]
pub extern "C" fn ws_dep_licenses_json() -> *const c_char {
    DEP_LICENSES_JSON_CSTR.as_ptr()
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
        rules_to_engine_with_resources(text, false)
    }

    fn rules_to_engine_with_resources(text: &str, enable_ubo_resources: bool) -> *mut Engine {
        ws_engine_new(text.as_ptr() as *const c_char, text.len(), enable_ubo_resources)
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
        let engine_ptr = rules_to_engine_with_resources(
            "||tracker.example.com^$redirect=noopjs\n", true);
        // We can't easily probe `BlockerResult.redirect` through the
        // existing FFI (which collapses to 0/1), so reach into the
        // engine directly. Internal-API test only.
        let engine = unsafe { &(*engine_ptr).inner };
        let request = adblock::request::Request::new(
            "https://tracker.example.com/foo.js",
            "https://news.com/",
            "script",
            "",
        ).unwrap();
        let result = engine.check_network_request(&request);
        assert!(result.should_block(), "rule must match");
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
    fn abp_rewrite_serves_the_aliased_redirect_resource() {
        // ABP lists write `$rewrite=abp-resource:<name>`; uBO ships the
        // `abp-resource:` names as aliases of its own resources.
        let engine_ptr = rules_to_engine_with_resources(
            "||tracker.example.com^$rewrite=abp-resource:blank-js\n", true);
        let engine = unsafe { &(*engine_ptr).inner };
        let request = adblock::request::Request::new(
            "https://tracker.example.com/foo.js",
            "https://news.com/",
            "script",
            "",
        ).unwrap();
        let redirect = engine.check_network_request(&request).redirect;
        assert!(redirect.is_some_and(|r| r.starts_with("data:")),
            "$rewrite= must resolve through the bundled uBO aliases");
        ws_engine_free(engine_ptr);
    }

    fn rule_lists_json(rules: &str) -> String {
        let ptr = ws_filters_to_content_rule_lists(
            rules.as_ptr() as *const c_char,
            rules.len(),
        );
        assert!(!ptr.is_null(), "content rule list conversion returned null");
        let json = unsafe { CStr::from_ptr(ptr) }.to_str().unwrap().to_owned();
        ws_string_free(ptr);
        json
    }

    #[test]
    fn content_rule_lists_carry_network_rules_only() {
        let json = rule_lists_json(
            "||doubleclick.net^\n||tracker.com^$third-party\n##.ad\nexample.com##.banner\n");
        let lists: Vec<Vec<serde_json::Value>> =
            json.lines().map(|l| serde_json::from_str(l).unwrap()).collect();
        assert_eq!(lists.len(), 1, "payload: {json}");
        assert!(json.contains("doubleclick"), "payload: {json}");
        assert!(!json.contains("css-display-none"), "cosmetic rules leaked: {json}");
    }

    #[test]
    fn content_rule_lists_leave_out_method_rules() {
        let json = rule_lists_json("||post.example^$method=post\n||get.example^\n");
        assert!(json.contains("get"), "payload: {json}");
        assert!(!json.contains("post"), "a method rule blocks every method in WebKit: {json}");
    }

    #[test]
    fn content_rule_lists_split_under_the_cap_with_every_exception() {
        let rules = "||a.example^\n||b.example^\n||c.example^\n@@||a.example/ok^\n";
        let lists = content_rule_lists(rules, 3).unwrap();
        let exceptions = |list: &Vec<CbRule>| list.iter()
            .filter(|r| matches!(r.action.typ, CbType::IgnorePreviousRules)).count();
        // One exception from the list plus the first-party document one.
        assert_eq!(exceptions(&lists[0]), 2);
        assert_eq!(lists.len(), 3, "one block rule per list: {lists:?}");
        for list in &lists {
            assert!(list.len() <= 3);
            assert_eq!(exceptions(list), 2, "every list carries every exception");
            assert!(matches!(list[0].action.typ, CbType::Block), "blocks come first");
        }
        assert!(content_rule_lists(rules, 2).is_none(), "exceptions alone fill a list of 2");
    }

    #[test]
    fn content_rule_lists_empty_without_network_rules() {
        assert_eq!(rule_lists_json("##.ad\n! comment\n"), "");
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
