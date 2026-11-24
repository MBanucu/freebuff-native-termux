// The Android Gradle Plugin is the only build-time dependency; the app itself
// has none, so an F-Droid build needs nothing but the SDK.  Versions live in
// gradle/libs.versions.toml.
plugins {
    alias(libs.plugins.android.application) apply false
}
