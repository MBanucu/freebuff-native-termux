plugins {
    alias(libs.plugins.android.application)
}

android {
    namespace = "io.github.mbanucu.freebuffnative"
    compileSdk = libs.versions.compileSdk.get().toInt()

    defaultConfig {
        applicationId = "io.github.mbanucu.freebuffnative"
        minSdk = libs.versions.minSdk.get().toInt()
        targetSdk = libs.versions.targetSdk.get().toInt()
        // fastlane/metadata/android/en-US/changelogs/<versionCode>.txt must match.
        versionCode = libs.versions.appVersionCode.get().toInt()
        versionName = libs.versions.appVersionName.get()
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
    androidTestImplementation(libs.androidx.test.runner)
    androidTestImplementation(libs.androidx.test.rules)
    androidTestImplementation(libs.androidx.test.ext.junit)
    androidTestImplementation(libs.androidx.test.uiautomator)
}
