pluginManagement {
    repositories { google(); mavenCentral(); gradlePluginPortal() }
}
dependencyResolutionManagement {
    repositories { google(); mavenCentral() }
}
rootProject.name = "L1ne"
include(":core")                         // pure Kotlin: vCard, provisioning, accounts. Builds with just a JDK.
// The Compose app needs the Android SDK; it is included only when one is installed.
val sdk = System.getenv("ANDROID_HOME") ?: System.getenv("ANDROID_SDK_ROOT")
    ?: file("local.properties").takeIf { it.exists() }?.readLines()?.firstOrNull { it.startsWith("sdk.dir=") }
if (sdk != null) include(":app")
