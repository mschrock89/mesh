plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

val meshCommit = providers.exec {
    workingDir(rootDir.parentFile)
    commandLine("git", "rev-parse", "HEAD")
}.standardOutput.asText.get().trim()
val meshVersionCode = providers.exec {
    workingDir(rootDir.parentFile)
    commandLine("git", "rev-list", "--count", "HEAD")
}.standardOutput.asText.get().trim().toInt()

android {
    namespace = "com.mitchellschrock.mesh"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.mitchellschrock.mesh"
        minSdk = 26
        targetSdk = 35
        versionCode = meshVersionCode
        versionName = "1.0"
        buildConfigField("String", "MESH_COMMIT", "\"$meshCommit\"")
        buildConfigField("String", "MESH_REPO", "\"mschrock89/mesh\"")
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            // USB installs use this same key, so published APKs can update them in place.
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }
}

tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

dependencies {
    implementation(project(":mesh-core"))
    implementation(platform("androidx.compose:compose-bom:2024.12.01"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
    implementation("org.jmdns:jmdns:3.6.1")
}
