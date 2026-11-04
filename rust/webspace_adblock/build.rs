// Build-time enumeration of the crates linked into this library and
// their licences, embedded for the app's licence page
// (`ws_dep_licenses_json`), and the tracker surrogates the `$redirect=`
// pool takes in (src/redirect_resources.rs builds the rest of it).

use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

mod licence_policy;
#[path = "src/sha256.rs"]
mod sha256;

use serde_json::{json, Value};

// DuckDuckGo's tracker surrogates (CB-010): the files surrogates.tsv names,
// taken at this commit and held one by one to the SHA-256 digests the table
// pins, so a moved branch or a tampered copy fails the build rather than
// reaching a page. A build with no network checks out the same commit itself
// and names the checkout in WEBSPACE_SURROGATES_SOURCE, held to the same
// digests. To move the pin, read the new commit's files and licence, write
// their digests into surrogates.tsv and move the pin in components.tsv.
const SURROGATES_REPO: &str = "https://github.com/duckduckgo/tracker-surrogates.git";
const SURROGATES_COMMIT: &str = "1cca57fa1edc945f208423d478c1d2aa50655141";
const SURROGATES_SOURCE_ENV: &str = "WEBSPACE_SURROGATES_SOURCE";

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    let out_dir = PathBuf::from(env::var("OUT_DIR").expect("OUT_DIR not set"));
    let policy = licence_policy::Policy::checked();
    let surrogates = take_surrogates(&out_dir, &policy);

    // Always re-enumerate the dep tree on every build — `cargo
    // metadata` is fast (no compilation, just lockfile + manifest
    // parse) and we want a license blob that exactly mirrors what
    // got linked into this binary.
    write_dep_licenses(&out_dir, &policy, surrogates);
}

/// A file surrogates.tsv names: its path in the upstream tree, the digest it
/// must have, and the names a `$redirect=` asks for it by, none for the
/// licence.
struct Pinned {
    path: String,
    sha256: String,
    names: Vec<String>,
}

fn surrogates_table() -> Vec<Pinned> {
    let at = Path::new(&env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR not set"))
        .join("surrogates.tsv");
    println!("cargo:rerun-if-changed={}", at.display());
    let text = fs::read_to_string(&at).unwrap_or_else(|e| panic!("{}: {e}", at.display()));
    let rows: Vec<Pinned> = text
        .lines()
        .filter(|l| !l.trim().is_empty() && !l.starts_with('#'))
        .map(|line| {
            let cols: Vec<&str> = line.split('\t').collect();
            let (path, sha256, names) = match cols[..] {
                [path, sha256] => (path, sha256, ""),
                [path, sha256, names] => (path, sha256, names),
                _ => panic!("{}: a row is a path, a digest and its names: {line:?}", at.display()),
            };
            assert!(
                sha256.len() == 64 && sha256.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)),
                "{}: {path}'s digest is not 64 lowercase hex digits",
                at.display()
            );
            assert!(
                !path.starts_with('/') && !path.split('/').any(|p| p.is_empty() || p == ".." || p == "."),
                "{}: {path} is not a path inside the tree",
                at.display()
            );
            Pinned {
                path: path.to_string(),
                sha256: sha256.to_string(),
                names: names.split_whitespace().map(String::from).collect(),
            }
        })
        .collect();
    let licences = rows.iter().filter(|r| r.names.is_empty()).count();
    assert_eq!(licences, 1, "{}: one file, the licence, is served under no name", at.display());
    for row in rows.iter().filter(|r| !r.names.is_empty()) {
        assert!(row.path.ends_with(".js"), "{}: {} is served as a script", at.display(), row.path);
    }
    rows
}

/// Each file of [rows] under [root], or every one missing or unlike its pin.
fn read_pinned(root: &Path, rows: &[Pinned]) -> Result<Vec<Vec<u8>>, Vec<String>> {
    let mut files = Vec::new();
    let mut wrong = Vec::new();
    for row in rows {
        match fs::read(root.join(&row.path)) {
            Ok(bytes) => {
                let digest = sha256::sha256_hex(&bytes);
                if digest != row.sha256 {
                    wrong.push(format!("{}: SHA-256 {digest}, pinned {}", row.path, row.sha256));
                }
                files.push(bytes);
            }
            Err(e) => wrong.push(format!("{}: {e}", row.path)),
        }
    }
    if wrong.is_empty() { Ok(files) } else { Err(wrong) }
}

/// The files of [rows], from the checkout [SURROGATES_SOURCE_ENV] names or
/// fetched at [SURROGATES_COMMIT] into [out_dir], each as surrogates.tsv
/// pins it. Any other outcome fails the build: a pool that silently lost its
/// surrogates would block what it should stand in for.
fn surrogate_files(out_dir: &Path, rows: &[Pinned]) -> Vec<Vec<u8>> {
    println!("cargo:rerun-if-env-changed={SURROGATES_SOURCE_ENV}");
    if let Some(root) = env::var_os(SURROGATES_SOURCE_ENV).map(PathBuf::from) {
        for row in rows {
            println!("cargo:rerun-if-changed={}", root.join(&row.path).display());
        }
        return read_pinned(&root, rows).unwrap_or_else(|wrong| {
            panic!(
                "{SURROGATES_SOURCE_ENV} names {}, which does not hold the files surrogates.tsv pins at {SURROGATES_COMMIT}: {wrong:?}",
                root.display()
            )
        });
    }
    let root = out_dir.join(format!("tracker-surrogates-{SURROGATES_COMMIT}"));
    if let Ok(files) = read_pinned(&root, rows) {
        return files;
    }
    if root.exists() {
        fs::remove_dir_all(&root).unwrap_or_else(|e| panic!("{}: {e}", root.display()));
    }
    fs::create_dir_all(&root).unwrap_or_else(|e| panic!("{}: {e}", root.display()));
    let offline = format!(
        "a build with no network names a checkout of {SURROGATES_REPO} at {SURROGATES_COMMIT} in {SURROGATES_SOURCE_ENV}"
    );
    for args in [
        &["init", "-q"][..],
        &["fetch", "-q", "--depth", "1", SURROGATES_REPO, SURROGATES_COMMIT],
        &["-c", "advice.detachedHead=false", "checkout", "-q", "FETCH_HEAD"],
    ] {
        let out = Command::new("git")
            .arg("-C")
            .arg(&root)
            .args(args)
            .env_remove("GIT_DIR")
            .env_remove("GIT_WORK_TREE")
            .env_remove("GIT_INDEX_FILE")
            .env("GIT_TERMINAL_PROMPT", "0")
            .output()
            .unwrap_or_else(|e| panic!("git {}: {e}; {offline}", args.join(" ")));
        assert!(
            out.status.success(),
            "git {} failed ({}): {}; {offline}",
            args.join(" "),
            out.status,
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }
    read_pinned(&root, rows).unwrap_or_else(|wrong| {
        panic!("{SURROGATES_REPO} at {SURROGATES_COMMIT} does not hold the files surrogates.tsv pins: {wrong:?}")
    })
}

/// Writes `surrogates.rs`, the pool's `SURROGATES`, into [out_dir], each
/// script under the names surrogates.tsv gives it, and returns the licences
/// page's entry for them, whose licence is the one components.tsv reads.
fn take_surrogates(out_dir: &Path, policy: &licence_policy::Policy) -> Value {
    let source = format!("url:{SURROGATES_REPO}");
    let component = licence_policy::component(&source);
    assert!(
        policy.allows(&component.licence, component.ships, &source),
        "LICENSE-001: openspec/specs/legal/licences.tsv lets {source} not ship under {:?}",
        component.licence
    );
    let rows = surrogates_table();
    let files = surrogate_files(out_dir, &rows);
    let dir = out_dir.join("surrogates");
    fs::create_dir_all(&dir).unwrap_or_else(|e| panic!("{}: {e}", dir.display()));
    let mut code = String::from("// Written by build.rs from surrogates.tsv.\nconst SURROGATES: &[Stub] = &[\n");
    let mut licence = None;
    for (row, bytes) in rows.iter().zip(&files) {
        let Some((name, aliases)) = row.names.split_first() else {
            licence = Some(json!({ "name": row.path, "text": String::from_utf8_lossy(bytes) }));
            continue;
        };
        let file = dir.join(row.path.replace('/', "__"));
        fs::write(&file, bytes).unwrap_or_else(|e| panic!("{}: {e}", file.display()));
        code.push_str(&format!(
            "    Stub {{ name: {name:?}, aliases: &{aliases:?}, mime: MimeType::ApplicationJavascript, \
             body: Body::Text(include_str!({:?})) }},\n",
            file.display().to_string()
        ));
    }
    code.push_str("];\n");
    let out = out_dir.join("surrogates.rs");
    fs::write(&out, code).unwrap_or_else(|e| panic!("{}: {e}", out.display()));
    json!({
        "kind": "redirect-resources",
        "name": "DuckDuckGo tracker-surrogates",
        "version": SURROGATES_COMMIT,
        "license": component.licence,
        "repository": SURROGATES_REPO.trim_end_matches(".git"),
        "description": "Scripts that stand in for the APIs of trackers and ad libraries, \
            which the content blocker serves for $redirect= rules. The files based on \
            Mozilla's webcompat shims and on uBlock Origin's google-ima.js are under \
            MPL-2.0, as each one's header says. The source of every file is the \
            repository below at this version.",
        "authors": [],
        "license_files": [licence.expect("surrogates.tsv names the licence")],
        "license_texts": [],
    })
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
/// resolved dependency, then [surrogates]' entry. The result is embedded into the .so/.a via
/// `include_str!` and surfaced to Flutter's LicenseRegistry on app
/// startup — that satisfies attribution requirements for the
/// permissive licenses every transitive crate carries without us
/// vendoring any license text.
///
/// `cargo metadata` parses Cargo.lock + Cargo.toml; it never compiles.
/// A crate whose licence licence_policy.rs refuses fails the build, and
/// so does a metadata run that fails, since nothing is then checked.
fn write_dep_licenses(out_dir: &Path, policy: &licence_policy::Policy, surrogates: Value) {
    println!("cargo:rerun-if-changed=Cargo.toml");
    println!("cargo:rerun-if-changed=Cargo.lock");
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
            "kind": "crate",
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

    out.push(surrogates);

    let json_blob = serde_json::to_string(&out).expect("serialise dep_licenses");
    fs::write(&out_path, &json_blob).expect("write dep_licenses.json");
    println!(
        "cargo:warning=dep_licenses.json: {} crates ({} bytes)",
        out.len(),
        json_blob.len()
    );
}
