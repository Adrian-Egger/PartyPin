// Top-level build.gradle.kts

// Versionen müssen mit settings.gradle.kts (pluginManagement) konsistent
// bleiben. Subprojekte mit Legacy `apply plugin:` Syntax (z. B. das
// vendored qr_code_scanner) ziehen Klassenpfade aus diesem buildscript-Block
// → falsche Version hier verursacht Kotlin-Metadata-Konflikte.
buildscript {
    repositories {
        google()
        mavenCentral()
    }
    dependencies {
        classpath("com.android.tools.build:gradle:8.9.1")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:2.2.20")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// Optional: Build-Ordner anpassen
val newBuildDir = rootProject.layout.buildDirectory.dir("../../build").get()
rootProject.layout.buildDirectory.set(newBuildDir)

subprojects {
    val newSubprojectBuildDir = newBuildDir.dir(project.name)
    project.layout.buildDirectory.set(newSubprojectBuildDir)
    project.evaluationDependsOn(":app")
}

// Clean task
tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
