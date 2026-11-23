plugins {
    kotlin("jvm") version "2.2.21" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.2.21" apply false
    id("com.android.application") version "9.5.2" apply false     // AGP 9 has Kotlin built in (no kotlin-android plugin)
}
