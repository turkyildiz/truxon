import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    // Firebase push — enabled 2026-07-17 (google-services.json present in this
    // folder). Provides FCM for urgent DND-bypass dispatch alarms.
    id("com.google.gms.google-services")
}

// Release signing — loaded from android/key.properties (gitignored, never
// committed). Release builds REQUIRE it: a missing file fails the build loudly
// rather than silently shipping a debug-signed "release" (which would poison
// the OTA chain — see RELEASES.md). Debug builds don't need it.
// OTA REQUIRES a stable key: once the fleet has a release-signed build, this
// keystore must never change or Android rejects the update.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseKeystore = keystorePropertiesFile.exists()
if (hasReleaseKeystore) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.truxon.truxon_companion"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // flutter_local_notifications requires core-library desugaring.
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.truxon.truxon_companion"
        // minSdk 24: required by firebase_messaging + comfortable for the
        // foreground-service + notifications stack.
        minSdk = maxOf(flutter.minSdkVersion, 24)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = rootProject.file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            if (hasReleaseKeystore) {
                signingConfig = signingConfigs.getByName("release")
            } else if (gradle.startParameter.taskNames.any { it.contains("Release", ignoreCase = true) }) {
                // Fail only when a release build was actually requested, so
                // debug builds on a checkout without the keystore still work.
                throw GradleException(
                    "Release build requires android/key.properties (keystore for release " +
                    "signing) and it was not found. Never ship a debug-signed release — it " +
                    "breaks the OTA update chain. See RELEASES.md → 'Migrating to a real " +
                    "keystore' for how to create the keystore and key.properties."
                )
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

flutter {
    source = "../.."
}
