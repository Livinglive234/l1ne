plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "com.livenet.l1ne"
    compileSdk = 36
    ndkVersion = "29.0.14206865"      // keep in step with NDK_VERSION in scripts/lib.sh (the native libraries are built with the same NDK)
    defaultConfig {
        applicationId = "com.livenet.l1ne"
        minSdk = 26
        targetSdk = 36
        // CI sets these for releases. Android only installs an APK over an older one when its versionCode is higher, so CI passes its run number.
        versionCode = (System.getenv("L1NE_VERSION_CODE") ?: "1").toInt()
        versionName = System.getenv("L1NE_VERSION_NAME") ?: "1.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        ndk { abiFilters += listOf("arm64-v8a", "armeabi-v7a") }     // 64-bit for current phones, 32-bit ARM for the many older and budget phones that still run a 32-bit system
    }
    // Release signing comes from environment variables (CI fills them from repository secrets); the key is never stored in the repository.
    // Without them, assembleRelease still works but gives an unsigned APK.
    val releaseKeystore = System.getenv("L1NE_KEYSTORE")
    signingConfigs {
        if (releaseKeystore != null) create("release") {
            storeFile = file(releaseKeystore)
            storePassword = System.getenv("L1NE_KEYSTORE_PASSWORD")
            keyAlias = System.getenv("L1NE_KEY_ALIAS")
            keyPassword = System.getenv("L1NE_KEY_PASSWORD")
        }
    }
    buildTypes {
        release {
            if (releaseKeystore != null) signingConfig = signingConfigs.getByName("release")
            isMinifyEnabled = false     // not shrunk (yet): the PJSIP bridge and Compose are untested under R8
        }
    }
    externalNativeBuild { cmake { path = file("src/main/cpp/CMakeLists.txt") } }
    defaultConfig { externalNativeBuild { cmake { arguments += "-DANDROID_STL=c++_static" } } }
    buildFeatures { compose = true }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
    kotlin { jvmToolchain(21) }
}

dependencies {
    implementation(project(":core"))
    val bom = platform("androidx.compose:compose-bom:2025.10.00")
    implementation(bom)
    implementation("androidx.activity:activity-compose:1.11.0")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.core:core-ktx:1.17.0")
    val camerax = "1.4.2"
    implementation("androidx.camera:camera-core:$camerax")
    implementation("androidx.camera:camera-camera2:$camerax")
    implementation("androidx.camera:camera-lifecycle:$camerax")
    implementation("androidx.camera:camera-view:$camerax")
    implementation("com.unboundid:unboundid-ldapsdk:7.0.1")         // LDAP directory lookup
    implementation("com.google.mlkit:barcode-scanning:17.3.0")     // model bundled in the app: scanning works offline
    testImplementation("junit:junit:4.13.2")
    testImplementation(kotlin("test-junit"))
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation(kotlin("test-junit"))
}
