plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.listenjar.desktop"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.listenjar.desktop"
        // Android 9 (API 28), the first with Credential Manager's passkeys
        // (lib/signin.dart).
        minSdk = 28
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // The URL scheme the sign-in page opens the app with (appScheme in
        // lib/config.dart); debug builds use their own.
        manifestPlaceholders["urlScheme"] = "listenjar"
    }

    // ListenJar's one release key, a PKCS12 keystore whose store password is
    // also the key's, and the only key release builds are signed with.
    // Android installs an update only over an APK signed with the same key,
    // and listenjar.com's passkeys accept only its certificate (passkeys.ts):
    // never replace it. CI names it in ANDROID_KEYSTORE_PATH,
    // ANDROID_KEYSTORE_PASSWORD and ANDROID_KEY_ALIAS; a Mac with
    // ~/.secrets/listenjar/desktop-signing/android needs none of them
    // (README.md's "Releases").
    signingConfigs {
        create("release") {
            val secrets = File(System.getProperty("user.home"), ".secrets/listenjar/desktop-signing/android")
            fun env(name: String) = System.getenv(name)?.takeIf { it.isNotEmpty() }
            storeFile = file(env("ANDROID_KEYSTORE_PATH") ?: "$secrets/release.p12")
            storeType = "pkcs12"
            storePassword = env("ANDROID_KEYSTORE_PASSWORD")
                ?: File(secrets, "keystore-password").takeIf { it.exists() }?.readText()?.trim()
            keyAlias = env("ANDROID_KEY_ALIAS") ?: "listenjar"
            keyPassword = storePassword
        }
    }

    buildTypes {
        debug {
            // Its own app beside an installed release: its own data and links.
            applicationIdSuffix = ".dev"
            manifestPlaceholders["urlScheme"] = "listenjar-dev"
        }
        release {
            signingConfig = signingConfigs.getByName("release")
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
