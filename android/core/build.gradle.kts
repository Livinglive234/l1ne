plugins { kotlin("jvm") }

kotlin { jvmToolchain(21) }

dependencies { testImplementation(kotlin("test")) }

tasks.test {
    useJUnitPlatform()
    // the same fixtures the iOS parser tests read
    systemProperty("fixtures", rootProject.projectDir.parentFile.resolve("tests/fixtures").absolutePath)
    testLogging { events("passed", "failed"); showStandardStreams = true }
}
