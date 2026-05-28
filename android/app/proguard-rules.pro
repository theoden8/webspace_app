# R8 runs in optimize-only mode for release builds: shrinking and
# obfuscation are disabled so no class is removed or renamed (keeps
# reflection and JNI entry points intact across the native plugins).
# The only observable effect is that android.util.Log.d / .v calls are
# treated as side-effect-free and dropped during the optimize pass, so
# debug-level log lines (including ones inherited from upstream webview
# code) don't reach release logcat.
-dontshrink
-dontobfuscate

-assumenosideeffects class android.util.Log {
    public static int d(...);
    public static int v(...);
}

# Flutter's embedding references Play Store deferred-components and
# split-install classes that aren't bundled (the fdroid flavor ships no
# Play services). They're referenced on a code path this app never
# takes, so suppress R8's missing-class verification rather than pull in
# the dependency. Same for javax.lang.model, reachable only through
# compile-time errorprone annotations.
-dontwarn com.google.android.play.core.**
-dontwarn javax.lang.model.**

