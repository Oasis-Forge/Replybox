import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}

android {
    namespace = "com.replybox.app"
    // Pinned rather than inherited from `flutter.*`. A capture fixture is only
    // comparable against another one taken at the same API level -- notification
    // redaction widened in Android 15 and again in 16 -- so the level the app
    // builds and targets has to be a number in this file, not whatever the
    // installed Flutter happens to default to. These are Flutter 3.44.8's own
    // defaults as of 21 September 2026; raising them is a deliberate change with
    // a spike dump to back it up.
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // Permanent after the first Play upload. Do not change it.
        applicationId = "com.replybox.app"
        // Pinned; see the note on compileSdk above. minSdk 24 is also the floor
        // the product needs: MessagingStyle.extractMessagesFromBundle, which the
        // whole capture path reads, arrived in API 24.
        minSdk = 24
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            keystoreProperties.getProperty("storeFile")?.let { storeFile = file(it) }
            storePassword = keystoreProperties.getProperty("storePassword")
            keyAlias = keystoreProperties.getProperty("keyAlias")
            keyPassword = keystoreProperties.getProperty("keyPassword")
        }
    }

    buildTypes {
        release {
            // Falls back to the debug key when key.properties is absent, so a local
            // release build still works; release.yml checks the bundle's real
            // certificate, so CI cannot ship a debug-signed one by accident.
            signingConfig = if (rootProject.file("key.properties").exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
