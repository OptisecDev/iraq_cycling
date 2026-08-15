plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.optisec.iraq_cycling"
    // Raised from flutter.compileSdkVersion (35): maplibre_gl and flutter_tts
    // both require compiling against SDK 36.
    compileSdk = 36
    // Raised from 25.1.8937393: maplibre_gl requires NDK 28.1.13356709;
    // flutter_tts/geolocator_android/path_provider_android/
    // permission_handler_android/reactive_ble_mobile/sqflite_android all
    // request 27.0.12077973 or lower, so the highest requirement wins (NDKs
    // are backward compatible).
    ndkVersion = "28.1.13356709"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        applicationId = "com.optisec.iraq_cycling"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // Raised from Flutter's default (21) to 24: flutter_tts (Phase 3)
        // requires minSdk 24. All other plugins in this project require 21
        // or lower, so this is a safe, compatible bump.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}
