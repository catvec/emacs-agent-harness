plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "app.harness.harness_client"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // The voice audio probe (tool/voice_audio_probe.dart) is a build of
        // this app with no screen of it, installed beside the app rather than
        // over it: a probe must never replace the app a person has paired
        // with their harness, and a debug-signed probe could not anyway.
        // tool/voice_audio_probe.sh passes -PvoiceProbe=true.
        applicationId = if (project.hasProperty("voiceProbe")) {
            "app.harness.client.probe"
        } else {
            "app.harness.client"
        }
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // Pack only the ABI named by harness.packageAbi, when one is named
        // (tool/qr_install.sh names the ABI of a phone connected already).
        // Flutter's plugin fills abiFilters with every ABI it supports before
        // this block runs, and the manifest's native-code list is read from
        // them, so leaving them at all three with one ABI's libraries packed
        // would tell a phone of another ABI that the APK is for it.  Nothing
        // is narrowed unless asked for: an APK built without this serves any
        // phone.
        val packedAbi = (project.findProperty("harness.packageAbi") ?: "").toString()
        if (packedAbi.isNotEmpty()) {
            ndk { abiFilters.clear(); abiFilters.add(packedAbi) }
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
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
