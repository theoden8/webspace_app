// Build-time fetcher + assembler for uBO's web-accessible resources.
//
// adblock-rust's $redirect= rules need a resource pool keyed by name
// → body. uBO ships these as web_accessible_resources/ in its
// repo, parsed by adblock-rust's `assemble_web_accessible_resources`
// helper. We fetch the upstream tarball at a pinned tag, extract
// just the two paths we need, call the assembler, serialise the
// result to JSON, and bake it into the .so via `include_str!`.
//
// Why this shape:
//   * No committed third-party source code — the uBO files only
//     live in $OUT_DIR at build time, then disappear from the
//     committed tree.
//   * No runtime network access — the assembled JSON is embedded
//     at compile time.
//   * Cargo's $OUT_DIR cache makes the network fetch + tar extract
//     + parse fire exactly once per pinned tag + target dir combo.
//
// Build-time network requirement: best-effort. If `curl` isn't on
// PATH OR the host has no network OR the upstream tag is gone,
// build.rs emits a cargo:warning and writes an empty `[]` resources
// pool. The engine then runs without $redirect= support — same as
// having the feature flag off. Logs surface the gap in CI.
//
// To bump uBO:
//   1. Tag a release at github.com/gorhill/uBlock, get the tag name.
//   2. Replace UBO_TAG below.
//   3. Commit. Next `cargo build` re-fetches + reparses.
//
// brave/adblock-resources was tempting (npm package, dist/
// resources.json pre-built) but it ships Brave's custom overrides
// rather than uBO's standard pool — it complements uBO's resources
// rather than replacing them. Wiring that bundle on top would
// be a separate concern; this build.rs pulls only the standard pool.

use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use adblock::resources::resource_assembler::assemble_web_accessible_resources;
use serde_json::{json, Value};

const UBO_TAG: &str = "1.59.0";
const UBO_TARBALL_URL: &str =
    "https://github.com/gorhill/uBlock/archive/refs/tags/1.59.0.tar.gz";

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    let out_dir = PathBuf::from(env::var("OUT_DIR").expect("OUT_DIR not set"));

    // Always re-enumerate the dep tree on every build — `cargo
    // metadata` is fast (no compilation, just lockfile + manifest
    // parse) and we want a license blob that exactly mirrors what
    // got linked into this binary.
    write_dep_licenses(&out_dir);

    let output_json = out_dir.join("ubo_resources.json");

    // Cache hit. Bumping UBO_TAG above also triggers a refetch
    // because build.rs itself changes.
    if output_json.exists() {
        println!("cargo:warning=ubo_resources.json cached at {}",
            output_json.display());
        return;
    }

    // Step 1: download tarball.
    let tarball_path = out_dir.join(format!("ubo-{}.tar.gz", UBO_TAG));
    if !tarball_path.exists() {
        if let Err(e) = fetch(&tarball_path, UBO_TARBALL_URL) {
            println!("cargo:warning=uBO fetch failed: {} — $redirect= rules will silently miss", e);
            fs::write(&output_json, b"[]").expect("write fallback");
            return;
        }
    }

    // Step 2: extract just web_accessible_resources/ + redirect-resources.js.
    let extract_dir = out_dir.join("ubo-extract");
    let _ = fs::remove_dir_all(&extract_dir);
    fs::create_dir_all(&extract_dir).expect("mkdir extract");
    let prefix = format!("uBlock-{}/src", UBO_TAG);
    let extract_result = Command::new("tar")
        .args(["-xzf"])
        .arg(&tarball_path)
        .args(["-C"])
        .arg(&extract_dir)
        .args([
            &format!("{}/web_accessible_resources", prefix),
            &format!("{}/js/redirect-resources.js", prefix),
        ])
        .output();
    let extract_ok = matches!(&extract_result, Ok(o) if o.status.success());
    if !extract_ok {
        let stderr = extract_result
            .map(|o| String::from_utf8_lossy(&o.stderr).into_owned())
            .unwrap_or_else(|e| e.to_string());
        println!("cargo:warning=uBO extract failed: {} — $redirect= rules will silently miss", stderr.trim());
        fs::write(&output_json, b"[]").expect("write fallback");
        return;
    }

    let war_dir = extract_dir
        .join(&prefix)
        .join("web_accessible_resources");
    let redirect_resources = extract_dir
        .join(&prefix)
        .join("js/redirect-resources.js");

    // Step 3: parse via the build-dep adblock crate.
    let resources = assemble_web_accessible_resources(
        &war_dir,
        &redirect_resources,
    );
    println!(
        "cargo:warning=uBO {}: assembled {} resources from {}",
        UBO_TAG, resources.len(), war_dir.display()
    );

    // Step 4: serialise to JSON, write to $OUT_DIR.
    let json = serde_json::to_string(&resources)
        .expect("serialise Vec<Resource>");
    fs::write(&output_json, &json).expect("write ubo_resources.json");
    println!(
        "cargo:warning=ubo_resources.json written ({} bytes)",
        json.len()
    );

    // Free disk: tarball and extract dir served their purpose.
    let _ = fs::remove_file(&tarball_path);
    let _ = fs::remove_dir_all(&extract_dir);
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
/// were just invoked by cargo) → write `[]`, app shows no deps. Same
/// fallback as the uBO fetch path: app keeps working.
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

fn fetch(out_path: &Path, url: &str) -> std::io::Result<()> {
    let out = Command::new("curl")
        .args(["-fsSL", "--max-time", "120", "-o"])
        .arg(out_path)
        .arg(url)
        .output()?;
    if !out.status.success() {
        let stderr = String::from_utf8_lossy(&out.stderr);
        return Err(std::io::Error::new(
            std::io::ErrorKind::Other,
            format!("curl exit {}: {}", out.status, stderr.trim()),
        ));
    }
    Ok(())
}
