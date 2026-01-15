# Screengrab Android 13+ Research Findings

## Question
Can Fastlane's Screengrab automatically pull screenshots on Android 13+, or is the manual extraction workaround necessary?

## TL;DR - ROOT CAUSE FOUND
**The issue was Ruby version incompatibility, not Android 13+ limitations.** The user was using Ruby 4, but Fastlane >2.211 only supports Ruby <3. With the correct Ruby version, Fastlane's Screengrab works perfectly and pulls screenshots automatically without any manual extraction needed.

All the "Android 13+ limitations" and Screengrab tooling issues documented below were actually symptoms of Fastlane malfunctioning due to Ruby version incompatibility.

## Research Findings

### Fastlane's Built-in Run-As Support

**Status**: Implemented but unreliable

- **PR #17006** (merged in 2019, released in Fastlane 2.156.0) added `run-as` command support to screengrab operations
- This was meant to solve permission denied errors on API 24+ by executing adb commands within the app's security context
- **However**: The `use_adb_root` parameter was deprecated in Fastlane 2.0+ with no replacement, and the parameters `use_adb_root`, `reinstall_app`, and `exit_on_test_failure` do not exist in the screengrab action

### Known Issues (As of 2024-2025)

Multiple unresolved GitHub issues demonstrate ongoing problems:

1. **Issue #28797** (November 2024) - Flutter/Android permission denied:
   - Fastlane 2.225.0 (includes the run-as fix)
   - Screenshots created successfully but pull fails with "Permission denied"
   - Error: `ls: /data/data/[package]/app_screengrab: Permission denied`
   - Status: OPEN, no solution documented

2. **Issue #17164** - Unable to get screenshot storage directory:
   - Labeled "workaround available" but no details in thread
   - Status: CLOSED/LOCKED

3. **Multiple path mismatch issues**:
   - Screenshots written to `/data/user/0/[package]/app_screengrab/`
   - Screengrab looks in `/data/data/[package]/app_screengrab/`
   - Or vice versa - created in one location, pulled from another

### Why the Manual Extraction Works

The manual extraction script (`android/fastlane/extract_screenshots.sh`) works because it:

1. Uses `adb shell run-as [package]` to access internal storage with proper app permissions
2. Creates a tar archive in the app's accessible storage location
3. Streams the archive using `cat` to avoid permission issues
4. Extracts to the correct output directory structure

This approach sidesteps the path detection and permission issues that affect Fastlane's built-in logic.

## Accurate Characterization

### ❌ Incorrect Statements

1. "Android 13+ limitation" - Android 13+ doesn't prevent screenshot pulling
2. "Just a configuration issue" - Not solved by adding config parameters
3. "Use use_adb_root: false" - This parameter doesn't exist in screengrab action
4. "Screengrab 2.1.1+ automatically handles it" - Evidence shows it doesn't work reliably

### ✅ Correct Understanding

1. **Not a platform limitation**: Android 13+ scoped storage doesn't prevent automated screenshot pulling when done correctly
2. **Screengrab tooling limitation**: Fastlane's screengrab has known issues with path detection and permission handling on modern Android
3. **Manual extraction is a valid workaround**: Not a hack, but a legitimate solution for a known tool limitation
4. **May work in some scenarios**: Fastlane's built-in run-as might work for some device/emulator configurations, but fails for others

## Current Setup Assessment

The existing webspace_app setup is **correct and appropriate**:

- ✅ Screengrab 2.1.1 dependency (latest)
- ✅ UiAutomatorScreenshotStrategy configured
- ✅ Manual extraction script as fallback in Fastfile
- ✅ Works reliably (as documented in transcript)

## Recommendation

**Keep the current setup with manual extraction.** The approach is:

1. Try screengrab normally (may work on some emulators/devices)
2. If it fails with "No screenshots were detected", fall back to manual extraction
3. This ensures screenshots are captured reliably regardless of Fastlane quirks

The transcript's characterization as "Android 13+ limitation" is misleading, but the implementation approach is sound. A better characterization would be "Screengrab tooling limitation on modern Android versions, requiring manual extraction workaround."

## Documentation Update Needed

The FASTLANE_SETUP.md should be updated to:

1. Remove language suggesting Android 13+ has a platform limitation
2. Explain that it's a Screengrab tooling issue with known workarounds
3. Note that Fastlane theoretically supports it but has documented reliability issues
4. Clarify that manual extraction is a valid solution, not a temporary hack

## Version Clarification

There was initial confusion about versions:
- **Fastlane tool** (Ruby gem): Version 2.230+ (the CLI tool you run)
- **tools.fastlane:screengrab** (Android library): Version 2.1.1 (latest on Maven Central, Oct 2021)

The project was already using `tools.fastlane:screengrab:2.1.1`, which is the **latest available version** of the Android library. This is separate from the Fastlane tool version.

**Conclusion:**
The manual extraction script addresses real limitations in the screengrab library, not outdated code. Version 2.1.1 is the current and only actively maintained version available on Maven Central.

## RESOLUTION: Ruby Version Incompatibility

After extensive investigation into Android 13+ limitations, Screengrab tooling issues, and path mismatches, the **actual root cause** was discovered:

**Problem**: Using Ruby 4 with Fastlane >2.211
**Fastlane Requirement**: Ruby <3 (version 2.x)
**Symptom**: Fastlane malfunctioned, causing it to fail to pull screenshots despite tests succeeding

### What Actually Happened

1. Tests ran successfully and screenshots were captured correctly
2. Fastlane attempted to pull screenshots but failed due to Ruby incompatibility causing internal errors
3. Error messages suggested Android permission issues, but these were red herrings
4. With correct Ruby version (<3), Fastlane's built-in run-as logic works perfectly

### Conclusion

**No manual extraction script is needed.** The extract_screenshots.sh workaround was solving a symptom of Ruby version incompatibility, not a real Android or Screengrab limitation.

**Lesson Learned**: Always check environment/dependency compatibility before investigating complex platform-specific issues.

## Sources

- [Fastlane Screengrab PR #17006 - Added run-as support](https://github.com/fastlane/fastlane/pull/17006)
- [Issue #28797 - Permission denied on Android (Nov 2024)](https://github.com/fastlane/fastlane/issues/28797)
- [Issue #17164 - Unable to get storage directory](https://github.com/fastlane/fastlane/issues/17164)
- [Issue #15788 - Permission denied API 24+](https://github.com/fastlane/fastlane/issues/15788)
- [Fastlane Screengrab Documentation](https://docs.fastlane.tools/actions/screengrab/)
