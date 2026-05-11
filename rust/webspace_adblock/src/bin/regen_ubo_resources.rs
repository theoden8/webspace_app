// One-shot binary: parse the vendored uBO resources directory into
// a `Vec<adblock::resources::Resource>` and serialise it as JSON
// for `include_str!` consumption by lib.rs.
//
// Run via:
//   cd rust/webspace_adblock
//   cargo run --bin regen_ubo_resources
//
// The output path is fixed at `src/ubo_resources.json` (relative to
// the crate root). The committed JSON is the runtime source of
// truth — lib.rs embeds it at compile time. Re-running this is
// only necessary after bumping the vendored uBO version, NOT on
// every build.
//
// Why a separate binary instead of build.rs: keeping the parse step
// out of the standard build means cargo doesn't have to re-pull the
// `adblock` crate's resource-assembler feature for every clean
// build, and a corrupted parse output fails loudly here rather than
// silently producing an empty resource pool downstream.

use std::path::PathBuf;

use adblock::resources::resource_assembler::assemble_web_accessible_resources;

fn main() {
    let crate_root = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let war_dir = crate_root.join("vendor/ubo/web_accessible_resources");
    let redirect_resources_path =
        crate_root.join("vendor/ubo/redirect-resources.js");
    let output_path = crate_root.join("src/ubo_resources.json");

    if !war_dir.is_dir() {
        eprintln!(
            "expected vendored uBO at {} — see vendor/ubo/README.md",
            war_dir.display()
        );
        std::process::exit(2);
    }

    let resources = assemble_web_accessible_resources(
        &war_dir,
        &redirect_resources_path,
    );
    eprintln!("parsed {} resources from {}", resources.len(), war_dir.display());

    let json = serde_json::to_string(&resources).expect("serialise");
    std::fs::write(&output_path, &json).expect("write");
    eprintln!("wrote {} bytes to {}", json.len(), output_path.display());
}
