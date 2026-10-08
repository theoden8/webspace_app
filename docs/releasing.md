# Releasing

A release is one PR. It is squash-merged into master and the squash commit is
tagged `v<X.Y.Z>`. CI runs on that commit as it stands, so everything the tag
needs rides the PR. Signed macOS builds come after, from the tag:
[releasing-macos.md](releasing-macos.md).

## The version

`version: X.Y.Z+N` in `pubspec.yaml`, the only place it is written; Android,
iOS and macOS all read it from there.

- **X.Y.Z** is the maintainer's call. Ask which part moves (patch, minor,
  major) before bumping; do not infer it from the size of the changes.
- **N** is the last release's N plus one. It is the Android versionCode and
  it names the changelog.

## What the PR carries

| Item | Path | Fails without it |
|---|---|---|
| Version | `pubspec.yaml` | |
| Changelog | `fastlane/metadata/android/en-US/changelogs/<N>.txt` | `scripts/validate_fastlane_metadata.sh` (CI `validate`) |
| Backup fixtures | `test/fixtures/backup_compat/v<X.Y.Z>/` | `test/settings_backup_compat_test.dart` ("the version in pubspec.yaml has release fixtures") |

**Changelog.** What a user sees change since the last tag
(`git log --oneline v<last>..HEAD`), one short line each, under the three
headings the previous files use. Anything still behind an Experimental switch
or developer mode stays out, and so does the gate itself: users are not meant
to know developer mode exists, so a feature that leaves either gate is listed
as a new feature, nothing more. Refactors stay out too. At most 500 bytes (the
script checks it; F-Droid drops an oversize file silently).

**Backup fixtures.** What this release's own code exports, so every later
release proves it still imports it (BACKUP-012, BACKUP-014). The generator
checks out a commit, not the working tree, so commit the bump first:

```bash
git commit -m "Release X.Y.Z+N with changelog and backup compat fixtures" \
  pubspec.yaml fastlane/metadata/android/en-US/changelogs/N.txt
tool/backup_compat/generate.sh HEAD     # FLUTTER=... overrides `fvm flutter`
git add test/fixtures/backup_compat/vX.Y.Z && git commit --amend --no-edit
```

It needs network for `pub get` and Node for `prefs_keys.js`. It takes `lib/`
from the commit and `superset.json` from the working tree.

A red compat or `test/js/prefs_key_history.test.js` run on the new fixture is
the gate doing its job: HEAD writes something it does not read back, or one of
the scanners missed a spelling. Fix the cause in its own commit before the
release commit and regenerate; never edit a fixture by hand.

`superset.json` needs no release-day pass: the compat test
"superset.json moves every pref and writes every site key" fails on the PR
that adds a pref or a site field without it.

## Before merging

- The `flutter_inappwebview` refs in `pubspec.yaml` name a tag of the fork,
  not a branch (`git ls-remote --tags https://github.com/theoden8/flutter_inappwebview`).
  A branch can move under a release that is already tagged.
- Rebase onto master last, then run `generate.sh HEAD` again and amend. A
  serializer change that landed on master after the first run would otherwise
  leave the tag with fixtures its own code did not write.
- `fvm flutter test test/settings_backup_compat_test.dart`,
  `node --test test/js/prefs_key_history.test.js` and
  `./scripts/validate_fastlane_metadata.sh` pass.

## Tagging

Squash-merge, then tag the squash commit on master and push the tag:

```bash
git fetch origin master
git tag vX.Y.Z <squash sha>
git push origin vX.Y.Z
```

The fixture directory and the tag share a name, so `generate.sh vX.Y.Z`
reproduces what the PR committed.
