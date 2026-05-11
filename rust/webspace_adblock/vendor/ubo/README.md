// Tracking the vendored uBlock Origin resources.

VENDORED FROM:
  https://github.com/gorhill/uBlock
  tag: 1.59.0
  paths:
    src/web_accessible_resources/  →  vendor/ubo/web_accessible_resources/
    src/js/redirect-resources.js   →  vendor/ubo/redirect-resources.js
    LICENSE.txt                    →  vendor/ubo/LICENSE.txt

LICENSE: GPL-3.0-only (see vendor/ubo/LICENSE.txt). Re-distributed
under the same terms as part of the WebSpace app.

WHY WE VENDOR:
  These are the resources adblock-rust's `assemble_web_accessible_
  resources` parses to populate `engine.use_resources(...)`. With
  the resource pool loaded:
    * $redirect=noop.js / $redirect=noopjs / similar ABP rules
      surface as a real WebResourceResponse body in the native
      sub-resource interceptor instead of an empty 200, which
      avoids breaking sites that explicitly probe for the
      redirected resource (e.g. analytics shims that try a
      replacement library).
    * The redirect mapping (redirect-resources.js) is needed so
      adblock-rust knows which name maps to which content-type and
      file body.

  Scriptlets (uBO's #$# snippet runtime) are NOT vendored here.
  uBO's scriptlet bundle is now an ES module that adblock-rust's
  deprecated `assemble_scriptlet_resources` can't parse. The new
  format upstream is in flux and would need its own runtime
  transformation. Out of scope for now; $redirect= is the high-
  leverage half.

REGENERATING (when bumping the uBO version):
  1. Replace `VENDORED_REF` in scripts/regen_ubo_resources.sh.
  2. Run `bash scripts/regen_ubo_resources.sh`. It downloads the
     tarball, extracts the two paths, and dumps the parsed JSON
     to src/ubo_resources.json.
  3. Commit the updated vendor/ubo/ files and the new
     src/ubo_resources.json side by side.

SIZE BUDGET:
  The vendored files are ~200 KB on disk. The serialised JSON
  embedded in libwebspace_adblock.so adds roughly the same to the
  shared library size.
