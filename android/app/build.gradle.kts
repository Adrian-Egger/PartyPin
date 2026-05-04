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
    // Vom qr_code_scanner-Plugin verlangt — Mismatch mit der vorher
    // genutzten NDK-27-Version war der Build-Blocker.
    ndkVersion = "28.2.13676358"

    compileOptions {
        // Aktiviert Core-Library-Desugaring (Java 8+ APIs auf älteren
        // Android-Versionen). qr_code_scanner verlangt das.
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = JavaVersion.VERSION_17.toString() }

    defaultConfig {
        applicationId = "com.partypin.party_pin"
        minSdk = 24
        targetSdk = 36
        versionCode = 5
        versionName = "1.4.0"
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

dependencies {
    // Liefert die Java-8+-API-Stubs für ältere Android-Versionen — wird
    // durch `isCoreLibraryDesugaringEnabled = true` aktiviert.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4")
}
