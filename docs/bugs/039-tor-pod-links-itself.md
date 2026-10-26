# BUG-039 — The Tor pod links its own framework

Status: closed. Attempt 2 removes the lookup by name that every instance went through.

**Spec:** [platform-support](../../openspec/specs/platform-support/spec.md)
PLATFORM-006 (macOS ships); `tor-proxy` TOR-007 (the Tor pod on macOS)
**Code:** the Tor target's `post_install` block in
[macos/Podfile](../../macos/Podfile) and [ios/Podfile](../../ios/Podfile)

## Symptom

`flutter build macos --release` fails while linking the Tor pod:

```
ld: can't link a dylib with itself. same install_name as dylib being built in
'.../Tor.framework/Versions/A/Tor'
```

The path names either Xcode's eager-linking stub
(`Intermediates.noindex/EagerLinkingTBDs/Release/Tor.framework/.../Tor.tbd`) or
the built binary (`Products/Release/Tor/Tor.framework/Versions/A/Tor`).

## Root mechanism / invariant

The Tor podspec vendors `tor.xcframework`, whose slice is `tor.framework`, and
CocoaPods links it into the pod's own `Tor.framework` as `-framework "tor"`. A
Mac's default APFS volume ignores case, and Xcode puts the pod's own products
folder on the framework search path, so a lookup of `tor` matches `Tor.framework`
whenever any file of it exists there before the link. The invariant: the Tor
pod's link names the vendored binary, never a framework by name.

## Fix attempts

1. **2026-10-14, #717 (3ace2bc).** `EAGER_LINKING = NO` on the Tor target.
   *Why:* with eager linking on, Xcode wrote `Tor.tbd` for the pod before
   linking it, and the lookup matched the stub. *Partial:* it removed one file
   the lookup could match, not the lookup. A build on Xcode 26.3 still failed
   on the built `Tor.framework/Versions/A/Tor`, from a clean `build/` and
   `macos/Pods`; CI's `macos-26` runner did not.
2. **2026-10-26.** `post_install` rewrites the Tor target's xcconfig so it links
   `"${PODS_XCFRAMEWORKS_BUILD_DIR}/Tor/<subspec>/tor.framework/tor"` by path,
   and `pod install` fails if the search path or the rewrite is missing.
   `EAGER_LINKING = NO` is dropped: with no lookup by name, the stub cannot be
   matched. *Why:* every instance went through the one name lookup. Both
   Podfiles carry it, since the iOS pod links the same way.

   On the Xcode 26.3 machine that hit the binary case, a clean
   `flutter build macos --release` then built.

## Known open gaps

- Which Xcode 26.3 step leaves `Tor.framework/Versions/A/Tor` before the link
  is not known; the fix does not depend on it.
