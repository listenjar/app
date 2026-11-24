pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    // Google's repositories only: Maven Central through Google's mirror of
    // it, which also serves plugins before the Plugin Portal, which would
    // redirect their jars to Maven Central. Maven Central rate-limits GitHub's
    // runners (429) and refuses some networks outright (403).
    repositories {
        google()
        maven("https://maven-central.storage-download.googleapis.com/maven2/")
        gradlePluginPortal()
    }
}

// Every plugin's own mavenCentral(), in its repositories and its buildscript's,
// resolves through the same mirror (tool/maven-mirror.gradle does this for
// Gradle builds outside the app's).
gradle.beforeProject {
    for (handler in listOf(repositories, buildscript.repositories)) {
        handler.withType(MavenArtifactRepository::class.java).configureEach {
            if (url.toString().startsWith("https://repo.maven.apache.org/maven2")) {
                setUrl("https://maven-central.storage-download.googleapis.com/maven2/")
            }
        }
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.3.1" apply false
    id("org.jetbrains.kotlin.android") version "2.4.20" apply false
}

include(":app")
