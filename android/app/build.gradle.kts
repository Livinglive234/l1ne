import com.android.build.api.variant.FilterConfiguration

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
}

// ./gradlew -Pl1ne.splits=true :app:assembleRelease  makes one APK per architecture (arm64-v8a, armeabi-v7a) plus a universal one that works on both.
val splitApks = providers.gradleProperty("l1ne.splits").orNull == "true"

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
        // Everyday builds carry both architectures in one APK. Release builds are split instead (see `splits` below), so each phone downloads only its own.
        if (!splitApks) ndk { abiFilters += listOf("arm64-v8a", "armeabi-v7a") }
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
    splits {
        abi {
            isEnable = splitApks
            reset()
            include("arm64-v8a", "armeabi-v7a")     // 64-bit for current phones; 32-bit ARM for the many older and budget phones that still run a 32-bit system
            isUniversalApk = true                   // one bigger file that works everywhere, for people who do not know which to pick
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
    implementation("com.google.zxing:core:3.5.3")                  // QR decoding: small, open source, works offline, no Google libraries
    testImplementation("junit:junit:4.13.2")
    testImplementation(kotlin("test-junit"))
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation(kotlin("test-junit"))
}

// Each split APK gets its own versionCode (base x 10 + a digit for the architecture). The numbers only ever go up from one release to the next,
// and a phone that could run either picks the 64-bit one. Without this, every APK of a release would carry the same number.
androidComponents {
    onVariants { variant ->
        variant.outputs.forEach { output ->
            val abi = output.filters.firstOrNull { it.filterType == FilterConfiguration.FilterType.ABI }?.identifier
            val base = output.versionCode.get() ?: 1
            output.versionCode.set(base * 10 + when (abi) { "arm64-v8a" -> 2; "armeabi-v7a" -> 1; else -> 0 })
        }
    }
}
