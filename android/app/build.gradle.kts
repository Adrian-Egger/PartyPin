// android/app/build.gradle.kts
import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("com.google.gms.google-services")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.partypin.party_pin"
    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = JavaVersion.VERSION_17.toString() }

    defaultConfig {
        applicationId = "com.partypin.party_pin"
        minSdk = 24
        targetSdk = 36
        versionCode = 1
        versionName = "1.0.0"
    }

    // --- Upload-Keystore ist Pflicht ---
    val keystorePropsFile = rootProject.file("key.properties")
    require(keystorePropsFile.exists()) {
        "key.properties fehlt – Release kann nicht ohne Upload-Keystore gebaut werden."
    }
    val keystoreProps = Properties().apply {
        load(FileInputStream(keystorePropsFile))
    }

    signingConfigs {
        create("release") {
            // Pfad ist relativ zum app-Ordner. Wenn die JKS in android/app liegt:
            storeFile = file(keystoreProps["storeFile"] as String)   // z.B. "upload-keystore.jks"
            storePassword = keystoreProps["storePassword"] as String
            keyAlias = keystoreProps["keyAlias"] as String
            keyPassword = keystoreProps["keyPassword"] as String
        }
    }

    buildTypes {
        getByName("debug") { }

        getByName("release") {
            isDebuggable = false
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            signingConfig = signingConfigs.getByName("release")
        }
    }
}
