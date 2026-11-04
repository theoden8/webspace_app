// Build-time enumeration of the crates linked into this library and
// their licences, embedded for the app's licence page
// (`ws_dep_licenses_json`). The `$redirect=` stubs are built by
// src/redirect_resources.rs.

use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use serde_json::{json, Value};

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    let out_dir = PathBuf::from(env::var("OUT_DIR").expect("OUT_DIR not set"));

    // Always re-enumerate the dep tree on every build — `cargo
    // metadata` is fast (no compilation, just lockfile + manifest
    // parse) and we want a license blob that exactly mirrors what
    // got linked into this binary.
    write_dep_licenses(&out_dir);
}

/// Look up canonical SPDX license texts for a `cargo metadata`
/// license expression via the `license` crate (which ships the
/// upstream SPDX 3.x dataset). Avoids the legal risk of either
/// hand-typing the text (typo / omission) or reading from each
/// crate's filesystem (non-standard filenames / encoding).
///
/// Expression tokens like `"MIT OR Apache-2.0"`, `"MIT/Apache-2.0"`,
/// `"(MIT OR Apache-2.0) AND Unicode-3.0"` are split on the
/// SPDX-allowed separators and each identified license is looked
/// up. Unknown identifiers are silently skipped — the caller still
/// records the raw expression so the user can read the original
/// SPDX string and follow the source link.
fn license_texts_for_expression(expression: &str) -> Vec<Value> {
    use license::License;
    if expression.is_empty() {
        return Vec::new();
    }
    let mut out = Vec::new();
    let mut seen: std::collections::HashSet<&'static str> = Default::default();
    let cleaned = expression.replace(['(', ')'], " ");
    for raw in cleaned.split(|c: char| c.is_whitespace() || c == '/') {
        let t = raw.trim();
        if t.is_empty() || matches!(t, "OR" | "AND" | "WITH" | "or" | "and" | "with") {
            continue;
        }
        let parsed: Result<&dyn License, _> = t.parse();
        if let Ok(lic) = parsed {
            if !seen.insert(lic.id()) {
                continue;
            }
            out.push(json!({
                "id": lic.id(),
                "name": lic.name(),
                "text": lic.text(),
            }));
        }
    }
    out
}

/// Run `cargo metadata` against the crate and emit a slim JSON list
/// of (name, version, license SPDX, repository, description) for every
/// resolved dependency. The result is embedded into the .so/.a via
/// `include_str!` and surfaced to Flutter's LicenseRegistry on app
/// startup — that satisfies attribution requirements for the
/// permissive licenses every transitive crate carries without us
/// vendoring any license text.
///
/// `cargo metadata` parses Cargo.lock + Cargo.toml; it never compiles.
/// Failure path: cargo not on PATH (theoretically impossible — we
/// were just invoked by cargo) → write `[]`, app shows no deps.
fn write_dep_licenses(out_dir: &Path) {
    let out_path = out_dir.join("dep_licenses.json");
    let metadata = match Command::new(env::var("CARGO").unwrap_or_else(|_| "cargo".into()))
        .args(["metadata", "--format-version", "1", "--all-features"])
        .output()
    {
        Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout).into_owned(),
        Ok(o) => {
            println!(
                "cargo:warning=cargo metadata exit {}: {}",
                o.status,
                String::from_utf8_lossy(&o.stderr).trim()
            );
            fs::write(&out_path, b"[]").expect("write empty dep_licenses");
            return;
        }
        Err(e) => {
            println!("cargo:warning=cargo metadata failed: {}", e);
            fs::write(&out_path, b"[]").expect("write empty dep_licenses");
            return;
        }
    };

    let parsed: Value = match serde_json::from_str(&metadata) {
        Ok(v) => v,
        Err(e) => {
            println!("cargo:warning=cargo metadata parse failed: {}", e);
            fs::write(&out_path, b"[]").expect("write empty dep_licenses");
            return;
        }
    };

    let packages = match parsed.get("packages").and_then(|v| v.as_array()) {
        Some(p) => p,
        None => {
            fs::write(&out_path, b"[]").expect("write empty dep_licenses");
            return;
        }
    };

    let mut out = Vec::new();
    for pkg in packages {
        let name = pkg.get("name").and_then(|v| v.as_str()).unwrap_or("");
        // Skip the wrapper crate itself — it has no upstream
        // source link and is fully described by the rest of the
        // attribution surface (the project's own LICENSE +
        // README + the transitive `adblock` entry that follows).
        if name == "webspace_adblock" {
            continue;
        }
        let license_expr = pkg
            .get("license")
            .and_then(|v| v.as_str())
            .unwrap_or("<unspecified>");
        // Resolve the SPDX expression to canonical license texts via
        // the `license` crate (build-dep). One entry per distinct
        // SPDX id named in the expression so dual-licensed crates
        // ship both bodies. Empty when the expression names no
        // recognised SPDX id — the consumer falls back to the raw
        // expression string.
        let license_texts = license_texts_for_expression(license_expr);
        out.push(json!({
            "name": name,
            "version": pkg.get("version").and_then(|v| v.as_str()).unwrap_or(""),
            "license": license_expr,
            "repository": pkg
                .get("repository")
                .and_then(|v| v.as_str())
                .unwrap_or(""),
            "description": pkg
                .get("description")
                .and_then(|v| v.as_str())
                .unwrap_or(""),
            "license_texts": license_texts,
        }));
    }
    // Stable order — sort by name so successive builds with the same
    // Cargo.lock produce byte-identical output (deterministic .so).
    out.sort_by(|a, b| {
        a.get("name").and_then(|v| v.as_str()).unwrap_or("")
            .cmp(b.get("name").and_then(|v| v.as_str()).unwrap_or(""))
    });

    let json_blob = serde_json::to_string(&out).expect("serialise dep_licenses");
    fs::write(&out_path, &json_blob).expect("write dep_licenses.json");
    println!(
        "cargo:warning=dep_licenses.json: {} crates ({} bytes)",
        out.len(),
        json_blob.len()
    );
}
