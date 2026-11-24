pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    // Repositories belong here and only here; a module that adds its own would
    // silently change what F-Droid resolves.
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

// AGP fails with a generic "SDK location not found" when nothing is configured.
// Check the same sources first and print one actionable message instead.  This
// runs while settings are evaluated, before the Android plugin is configured.
val sdkFromEnv = System.getenv("ANDROID_HOME")?.takeIf { it.isNotBlank() }
    ?: System.getenv("ANDROID_SDK_ROOT")?.takeIf { it.isNotBlank() }
val sdkFromProperty = System.getProperty("android.home")?.takeIf { it.isNotBlank() }
val sdkFromLocal = file("local.properties")
    .takeIf { it.isFile }
    ?.let { propertiesFile ->
        java.util.Properties().apply {
            propertiesFile.inputStream().use(::load)
        }.getProperty("sdk.dir")?.takeIf { it.isNotBlank() }
    }
val configuredSdk = sdkFromLocal ?: sdkFromProperty ?: sdkFromEnv ?: throw GradleException(
    """
    Android SDK not found: set ANDROID_HOME, or sdk.dir in android/local.properties.

    On Termux, use the documented wrapper (it finds ${'$'}HOME/android-sdk and
    the bionic aapt2 for you):

        tools/termux-build.sh assembleDebug

    Or configure it yourself:

        export ANDROID_HOME="${'$'}HOME/android-sdk"
        ./gradlew assembleDebug

    Or pass AGP's system property directly:

        ./gradlew -Dandroid.home="${'$'}HOME/android-sdk" assembleDebug

    There is also local.properties.example next to this file.
    """.trimIndent()
)
if (!file(configuredSdk).isDirectory) {
    throw GradleException(
        "Android SDK '$configuredSdk' does not exist. " +
            "Set ANDROID_HOME to an SDK directory, or run tools/termux-build.sh."
    )
}

rootProject.name = "freebuff-native"
include(":app")
