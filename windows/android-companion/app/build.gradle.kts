plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

val productVersion = rootProject.file("../../VERSION").readText().trim()
val versionParts = productVersion.split('.').map(String::toInt)

android {
    namespace = "com.anyway.windows.mock"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.anyway.windows.mock"
        minSdk = 26
        targetSdk = 35
        versionCode = versionParts[0] * 10000 + versionParts[1] * 100 + versionParts[2]
        versionName = productVersion
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
}

