// Build-time enumeration of the crates linked into this library and
// their licences, embedded for the app's licence page
// (`ws_dep_licenses_json`). The `$redirect=` stubs are built by
// src/redirect_resources.rs.

use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

mod licence_policy;

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

/// The licence files at the top of a crate's directory, each as its name
/// and text, in name order.
fn licence_files(dir: &Path) -> Vec<Value> {
    let mut files: Vec<_> = fs::read_dir(dir)
        .into_iter()
        .flatten()
        .flatten()
        .filter(|e| e.path().is_file())
        .filter(|e| {
            let name = e.file_name().to_string_lossy().to_lowercase();
            ["licen", "copying", "notice", "copyright"].iter().any(|p| name.starts_with(p))
        })
        .collect();
    files.sort_by_key(|e| e.file_name());
    files
        .iter()
        .map(|e| {
            json!({
                "name": e.file_name().to_string_lossy(),
                "text": String::from_utf8_lossy(&fs::read(e.path()).unwrap_or_default()),
            })
        })
        .collect()
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
/// A crate whose licence licence_policy.rs refuses fails the build, and
/// so does a metadata run that fails, since nothing is then checked.
fn write_dep_licenses(out_dir: &Path) {
    println!("cargo:rerun-if-changed=Cargo.toml");
    println!("cargo:rerun-if-changed=Cargo.lock");
    let policy = licence_policy::Policy::checked();
    let out_path = out_dir.join("dep_licenses.json");
    let metadata = match Command::new(env::var("CARGO").unwrap_or_else(|_| "cargo".into()))
        .args(["metadata", "--format-version", "1", "--all-features"])
        .output()
    {
        Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout).into_owned(),
        Ok(o) => panic!(
            "cargo metadata exit {}, so the crates' licences cannot be read: {}",
            o.status,
            String::from_utf8_lossy(&o.stderr).trim()
        ),
        Err(e) => panic!("cargo metadata failed, so the crates' licences cannot be read: {e}"),
    };

    let parsed: Value = serde_json::from_str(&metadata)
        .unwrap_or_else(|e| panic!("cargo metadata printed no JSON: {e}"));
    let packages = parsed
        .get("packages")
        .and_then(|v| v.as_array())
        .expect("cargo metadata lists no packages");

    let linked = licence_policy::linked(&parsed);
    let mut out = Vec::new();
    let mut refused = Vec::new();
    let mut gnu = Vec::new();
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
            .unwrap_or("");
        let version = pkg.get("version").and_then(|v| v.as_str()).unwrap_or("");
        if !policy.allows(license_expr, licence_policy::Ships::Linked, &format!("crate:{name}")) {
            refused.push(format!("{name} {version}: {license_expr:?}"));
        }
        if !pkg["id"].as_str().is_some_and(|id| linked.contains(id)) {
            continue;
        }
        let dir = Path::new(pkg["manifest_path"].as_str().expect("a package with no manifest"))
            .parent()
            .expect("a manifest with no directory");
        gnu.extend(licence_policy::gnu_text_in(dir).into_iter().map(|f| format!("{name} {version}: {f}")));
        // The crate's own licence files carry its copyright notices, which
        // MIT and BSD ask to travel with the binary; the canonical SPDX text
        // stands in only for a crate that ships none.
        let license_files = licence_files(dir);
        let license_texts = if license_files.is_empty() {
            license_texts_for_expression(license_expr)
        } else {
            Vec::new()
        };
        out.push(json!({
            "name": name,
            "version": version,
            "license": license_expr,
            "repository": pkg
                .get("repository")
                .and_then(|v| v.as_str())
                .unwrap_or(""),
            "description": pkg
                .get("description")
                .and_then(|v| v.as_str())
                .unwrap_or(""),
            "authors": pkg["authors"].clone(),
            "license_files": license_files,
            "license_texts": license_texts,
        }));
    }
    assert!(
        refused.is_empty(),
        "LICENSE-001: openspec/specs/legal/licences.tsv lets none of these crates link: {refused:?}"
    );
    assert!(
        gnu.is_empty(),
        "LICENSE-001: these linked crates carry GNU licence text, whatever their label: {gnu:?}"
    );
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
