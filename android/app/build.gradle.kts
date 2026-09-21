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
    namespace = "com.oasisforge.replybox"
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
        applicationId = "com.oasisforge.replybox"
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

    testOptions {
        unitTests {
            // android.jar on the unit-test classpath is a stub whose every method
            // throws "not mocked". CaptureStore and CaptureQueue reach android.util.Log
            // from inside the catch blocks that are the whole point of the fail-closed
            // tests (CAP-1) -- so a throwing Log would turn the path under test into an
            // exception before the assertion. Returning defaults leaves those paths
            // running and asserts what they do, not what the stub does.
            //
            // It does NOT make framework classes usable: a Bundle still answers null to
            // everything, which is why NotificationProjection.project is not exercised
            // here (see NotificationProjectionTest).
            isReturnDefaultValues = true
        }
    }
}

// A green run that ran nothing looks exactly like a green run that ran everything,
// and this task is the only thing that exercises CAP-1's native filter and CAP-15's
// prune at all. So every test names itself in the log and CI's own output is the
// evidence, rather than an HTML report nobody opens.
tasks.withType<Test>().configureEach {
    testLogging {
        events("passed", "skipped", "failed")
        exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL
        showStackTraces = true
    }
}

dependencies {
    testImplementation(kotlin("test"))
    // The real org.json, ahead of the stub android.jar on the test classpath.
    // CaptureQueue's line-per-row format and CaptureStore's file are both org.json
    // end to end (CAP-15), and a stubbed JSONObject that answers null would make
    // every one of those assertions pass for the wrong reason. AGP appends the
    // mockable android.jar last, so this artifact is what the tests link against.
    //
    // It is the *reference* implementation, not Android's, and the two differ in
    // one way that has already cost a privacy leak: Android's
    // `JSONTokener.toString()` is `" at character " + pos + " of " + in`, so a
    // JSONException there carries the entire string it failed to parse, while this
    // one carries only the class and position. A test that inspected a parse
    // failure here would therefore see none of the content that reaches logcat on a
    // device. Nothing about that can be fixed on the classpath, so INB-24 is held
    // structurally instead: CaptureLogTest asserts the capture package makes one
    // android.util.Log call in total and that it is fed a String with no throwable
    // in it. Read that file before changing this line.
    testImplementation("org.json:json:20240303")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
