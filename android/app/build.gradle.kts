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
        // Test-only: the instrumentation test drives the UI through accessibility.
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
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

    // The shipped app has no dependencies on purpose: no AndroidX, no analytics,
    // no networking.  Everything below is test-only and never enters the APK.
    lint {
        abortOnError = true
        warningsAsErrors = false
    }
}

dependencies {
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test:rules:1.6.1")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test.uiautomator:uiautomator:2.3.0")
}
