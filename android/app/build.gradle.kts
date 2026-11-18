plugins {
    id("com.android.application")
}

android {
    namespace = "io.github.mbanucu.freebuffnative"
    compileSdk = 35

    defaultConfig {
        applicationId = "io.github.mbanucu.freebuffnative"
        minSdk = 24
        targetSdk = 35
        // fastlane/metadata/android/en-US/changelogs/<versionCode>.txt must match.
        versionCode = 1
        versionName = "0.1.0"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    // No dependencies on purpose: no AndroidX, no analytics, no networking.
    lint {
        abortOnError = true
        warningsAsErrors = false
    }
}
