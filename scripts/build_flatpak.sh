#!/usr/bin/env bash
# Builds the flatpak with no network inside the build: flatpak-flutter
# (pinned below) turns linux/flatpak/flatpak-flutter.yml into an offline
# manifest under build/flatpak/manifest/, and flatpak-builder --sandbox
# builds that.
#
#   scripts/build_flatpak.sh [--generate-only] [commit]
#
# commit defaults to HEAD and has to be on GitHub: the manifest fetches the
# app from there, not from this checkout.
set -euo pipefail

FLATPAK_FLUTTER_TAG=0.15.0

generate_only=false
if [ "${1:-}" = --generate-only ]; then
  generate_only=true
  shift
fi

root="$(cd "$(dirname "$0")/.." && pwd)"
commit="${1:-$(git -C "$root" rev-parse HEAD)}"
app_id="$(sed -n 's/^id: //p' "$root/linux/flatpak/flatpak-flutter.yml")"
out="$root/build/flatpak"
tool="$out/flatpak-flutter"
work="$out/manifest"

if [ ! -d "$tool" ]; then
  git clone --quiet --depth 1 --branch "$FLATPAK_FLUTTER_TAG" \
    https://github.com/TheAppgineer/flatpak-flutter "$tool"
  python3 -m venv "$tool/.venv"
  "$tool/.venv/bin/pip" install --quiet -r "$tool/requirements.txt"
fi

rm -rf "$work"
mkdir -p "$work"
cp "$root"/linux/flatpak/* "$work"/

# The committed manifest builds master; point it at $commit instead. The
# Rust toolchain is rust-toolchain.toml's: flatpak-flutter provides the
# version a rustup-<version> module names, and RUSTUP_TOOLCHAIN overrides the
# file, whose Android targets rustup would otherwise try to download.
"$tool/.venv/bin/python" - "$work/flatpak-flutter.yml" "$commit" "$root/rust-toolchain.toml" <<'PY'
import sys, tomllib, yaml
path, commit, toolchain = sys.argv[1:]
with open(toolchain, 'rb') as f:
    rust = tomllib.load(f)['toolchain']['channel']
with open(path) as f:
    manifest = yaml.safe_load(f)
module = manifest['id'].split('.')[-1]
app = next(m for m in manifest['modules'] if isinstance(m, dict) and m['name'] == module)
source = next(s for s in app['sources'] if s.get('url', '').endswith('/webspace_app.git'))
del source['branch']
source['commit'] = commit
app.setdefault('modules', []).append(f'generated/modules/rustup-{rust}.json')
app['build-options']['env']['RUSTUP_TOOLCHAIN'] = rust
with open(path, 'w') as f:
    yaml.safe_dump(manifest, f, sort_keys=False)
PY

(cd "$work" && "$tool/.venv/bin/python" "$tool/flatpak-flutter.py" flatpak-flutter.yml)

if $generate_only; then
  exit 0
fi

flatpak-builder --sandbox --force-clean --user --install-deps-from=flathub \
  --state-dir="$out/state" --repo="$out/repo" "$out/app" "$work/$app_id.yml"
# The runtime comes from Flathub, so installing the bundle offers to add it.
flatpak build-bundle --runtime-repo=https://dl.flathub.org/repo/flathub.flatpakrepo \
  "$out/repo" "$out/webspace-$(flatpak --default-arch).flatpak" "$app_id"
