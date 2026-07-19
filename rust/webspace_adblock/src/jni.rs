// SPDX-License-Identifier: MPL-2.0
//
// JNI bridge so the Android `FastSubresourceInterceptor` (Kotlin)
// can consult the adblock-rust engine WITHOUT a Dart roundtrip per
// sub-resource. The webview's chromium IO thread calls
// `shouldInterceptRequest` for every sub-resource; routing that
// through the Dart isolate would add tens of milliseconds per
// request and serialise on a single isolate. Going direct
// Kotlin → Rust via JNI keeps it sub-millisecond and parallelised.
//
// JVM contract:
//   Long  enginePtr    — opaque Box<Engine> pointer; treated as
//                        u64 by Kotlin so the GC can store it as
//                        a regular long alongside the other plugin
//                        state.
//   String rulesText   — the same concatenated filter list the
//                        Dart side parses; transferred once when
//                        the user flips the toggle.
//   String url, source, requestType — passed per request from
//                        FastSubresourceInterceptor.checkUrl.
//
// Memory: ws_engine_free in lib.rs OR the Java-side `engineFree`
// release the Box — call exactly one. Callers must not deref
// after free. nativeCheckUrl / nativeRedirectFor deref the handle
// with no internal synchronization, so the Kotlin facade serialises
// free (write) against deref (read) via a ReentrantReadWriteLock —
// see AdblockEngineNative.kt. Do not call these directly off a raw
// handle that another thread can free.

#![cfg(target_os = "android")]

use std::sync::OnceLock;

use jni::objects::{JClass, JString};
use jni::sys::{jboolean, jlong, JNI_FALSE, JNI_TRUE};
use jni::JNIEnv;

use adblock::lists::{FilterSet, ParseOptions};
use adblock::request::Request;
use adblock::Engine as AdblockEngine;

use crate::Engine;

/// Internal helper to read a `JString` as a Rust `&str`. Returns an
/// empty string on conversion failure (matches the C-FFI's "empty
/// source = unknown" semantics — good enough for the hot path).
fn read_jstring(env: &mut JNIEnv, s: &JString) -> String {
    if s.is_null() {
        return String::new();
    }
    match env.get_string(s) {
        Ok(js) => js.into(),
        Err(_) => String::new(),
    }
}

/// Cached "boxes are heap pointers we own" log line. JNI's println-
/// to-logcat round-trip is allocation-heavy; we only log on engine
/// creation / failure, not per request. logcat tag matches the
/// Dart-side LogService tag for grep-ability.
fn android_log(level: log::Level, msg: &str) {
    #[cfg(feature = "android-log")]
    {
        match level {
            log::Level::Error => log::error!("{}", msg),
            log::Level::Warn => log::warn!("{}", msg),
            log::Level::Info => log::info!("{}", msg),
            log::Level::Debug => log::debug!("{}", msg),
            log::Level::Trace => log::trace!("{}", msg),
        }
    }
    // Without the `android-log` feature we still write to stderr —
    // adb logcat captures stderr from the app process.
    #[cfg(not(feature = "android-log"))]
    {
        let _ = level;
        eprintln!("[webspace_adblock] {}", msg);
    }
}

/// JNIEXPORT for `AdblockEngineNative.engineNew(rulesText: String): Long`.
/// Returns 0 on failure (caller must treat as null and skip engine
/// consultation). On success, returns a u64 cast of `Box::into_raw`.
#[no_mangle]
pub extern "system" fn Java_org_codeberg_theoden8_webspace_AdblockEngineNative_nativeEngineNew(
    mut env: JNIEnv,
    _class: JClass,
    rules_text: JString,
    enable_ubo_resources: jboolean,
) -> jlong {
    let text = read_jstring(&mut env, &rules_text);
    if text.is_empty() {
        android_log(log::Level::Warn, "JNI engineNew: empty rules text");
        return 0;
    }
    let mut filter_set = FilterSet::new(false);
    filter_set.add_filter_list(&text, ParseOptions::default());
    let mut engine = AdblockEngine::from_filter_set(filter_set, true);
    if enable_ubo_resources != 0 {
        let resources = crate::load_ubo_resources();
        if !resources.is_empty() {
            engine.use_resources(resources);
        }
    }
    let boxed = Box::new(Engine { inner: engine });
    let ptr = Box::into_raw(boxed);
    android_log(
        log::Level::Info,
        &format!(
            "JNI engineNew: parsed {} bytes, ptr=0x{:x}",
            text.len(),
            ptr as usize
        ),
    );
    ptr as jlong
}

/// JNIEXPORT for `AdblockEngineNative.engineFree(handle: Long)`.
/// Safe to call with 0.
#[no_mangle]
pub extern "system" fn Java_org_codeberg_theoden8_webspace_AdblockEngineNative_nativeEngineFree(
    _env: JNIEnv,
    _class: JClass,
    handle: jlong,
) {
    if handle == 0 {
        return;
    }
    unsafe {
        let _ = Box::from_raw(handle as *mut Engine);
    }
}

/// JNIEXPORT for `AdblockEngineNative.checkUrl(handle, url, source, requestType)`.
/// Mirrors `ws_engine_check_url` semantics (1 = blocked, 0 = allowed).
/// Returns false (allowed) on null handle or empty URL.
#[no_mangle]
pub extern "system" fn Java_org_codeberg_theoden8_webspace_AdblockEngineNative_nativeCheckUrl(
    mut env: JNIEnv,
    _class: JClass,
    handle: jlong,
    url: JString,
    source_url: JString,
    request_type: JString,
) -> jboolean {
    if handle == 0 {
        return JNI_FALSE;
    }
    let url_s = read_jstring(&mut env, &url);
    if url_s.is_empty() {
        return JNI_FALSE;
    }
    let src_s = read_jstring(&mut env, &source_url);
    let typ_raw = read_jstring(&mut env, &request_type);
    let typ_s: &str = if typ_raw.is_empty() { "other" } else { &typ_raw };

    let engine = unsafe { &(*(handle as *mut Engine)).inner };
    let request = match Request::new(&url_s, &src_s, typ_s) {
        Ok(r) => r,
        Err(_) => return JNI_FALSE,
    };
    let res = engine.check_network_request(&request);
    if res.matched && res.exception.is_none() {
        JNI_TRUE
    } else {
        JNI_FALSE
    }
}

// Lightweight no-op `log` shim so the eprintln!-fallback path doesn't
// require the real `log` crate. The `log` macros above only expand
// to anything with the optional `android-log` feature; without it
// they're never reached.
#[cfg(not(feature = "android-log"))]
mod log {
    pub enum Level {
        Error,
        Warn,
        #[allow(dead_code)]
        Info,
        #[allow(dead_code)]
        Debug,
        #[allow(dead_code)]
        Trace,
    }
}

/// JNIEXPORT for `AdblockEngineNative.redirectFor(handle, url, source, type)`.
/// Mirrors `ws_engine_redirect_for`: returns the data: URL string for
/// the redirect resource, or null when no $redirect= applies. Caller
/// (Kotlin) handles parsing the data URL into a real WebResourceResponse.
///
/// The returned Java String is a fresh allocation; JNI manages its
/// lifetime, no manual free needed on the Kotlin side.
#[no_mangle]
pub extern "system" fn Java_org_codeberg_theoden8_webspace_AdblockEngineNative_nativeRedirectFor<'local>(
    mut env: JNIEnv<'local>,
    _class: JClass,
    handle: jlong,
    url: JString,
    source_url: JString,
    request_type: JString,
) -> jni::objects::JString<'local> {
    let null_ret = jni::objects::JString::default();
    if handle == 0 {
        return null_ret;
    }
    let url_s = read_jstring(&mut env, &url);
    if url_s.is_empty() {
        return null_ret;
    }
    let src_s = read_jstring(&mut env, &source_url);
    let typ_raw = read_jstring(&mut env, &request_type);
    let typ_s: &str = if typ_raw.is_empty() { "other" } else { &typ_raw };

    let engine = unsafe { &(*(handle as *mut Engine)).inner };
    let request = match Request::new(&url_s, &src_s, typ_s) {
        Ok(r) => r,
        Err(_) => return null_ret,
    };
    let result = engine.check_network_request(&request);
    match result.redirect {
        Some(data_url) => env.new_string(data_url).unwrap_or(null_ret),
        None => null_ret,
    }
}

/// Sanity-check anchor: a once-cell set on first symbol load. Reading
/// it from a separate JNI call is a cheap "is this build wired
/// correctly" probe. The Kotlin side hits it once at engine-set time.
#[no_mangle]
pub extern "system" fn Java_org_codeberg_theoden8_webspace_AdblockEngineNative_nativeProbe(
    _env: JNIEnv,
    _class: JClass,
) -> jboolean {
    static PROBED: OnceLock<()> = OnceLock::new();
    PROBED.get_or_init(|| {
        android_log(
            log::Level::Info,
            "JNI probe: webspace_adblock JNI symbols loaded",
        );
    });
    JNI_TRUE
}
