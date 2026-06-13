# R8 runs in shrink + optimize mode for release builds. Obfuscation stays
# off (-dontobfuscate) so reflection and JNI symbol names survive intact
# across the native plugins. Shrinking removes provably-unreachable code --
# which is what strips Flutter's dead Play Store deferred-components manager
# and the com.google.android.play.core.* references it carries (F-Droid
# rejects those; this app uses FlutterApplication, never the split variant,
# so the path is dead code). The optimize pass additionally treats
# android.util.Log.d/.v as side-effect-free, so debug-level log lines don't
# reach release logcat.
-dontobfuscate

-assumenosideeffects class android.util.Log {
    public static int d(...);
    public static int v(...);
}

# JNI: keep every class that declares native methods, plus the method names
# and their descriptor types, so the Rust adblock engine's name-mangled
# lookups (Java_org_codeberg_theoden8_webspace_AdblockEngineNative_native*,
# bound in rust/webspace_adblock/src/jni.rs) still resolve after shrinking.
# A stripped or renamed JNI target fails at runtime with UnsatisfiedLinkError,
# not at build time, so pin it explicitly rather than trust reachability.
-keepclasseswithmembernames,includedescriptorclasses class * {
    native <methods>;
}

# First-party platform-channel plugins are reached from Dart by name and,
# for the adblock bridge, called back into from native code.
-keep class org.codeberg.theoden8.webspace.** { *; }

# Flutter's embedding still references the Play deferred-components and
# split-install classes during R8 verification before the dead path is
# pruned; errorprone leaves javax.lang.model refs reachable only at compile
# time. Suppress both rather than pull in the dependencies.
-dontwarn com.google.android.play.core.**
-dontwarn javax.lang.model.**
