// ============================================
// Valhalla JNI Bindings - Optimized Gradle Build
// ============================================
// Phase 4 Optimizations:
// - Version catalog for centralized dependency management
// - Build cache enabled
// - Parallel execution
// - Incremental compilation
// - Code quality plugins (Detekt)
// - Performance benchmarking (JMH)
// - Documentation generation (Dokka)
// ============================================

import java.time.Instant
import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.jetbrains.kotlin.gradle.tasks.KotlinCompile

plugins {
    alias(libs.plugins.kotlin.jvm)
    `java-library`
    `maven-publish`
    alias(libs.plugins.dokka)
    alias(libs.plugins.detekt)
    alias(libs.plugins.jmh)
    idea
}

group = "global.tada"
// version is defined in gradle.properties (single source of truth)

repositories {
    mavenCentral()
}

// ============================================
// Java/Kotlin Configuration
// ============================================
java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
    withSourcesJar()
    withJavadocJar()
}


kotlin {
    jvmToolchain(17)

    // Explicit API mode (helps catch issues early)
    // Disabled for now - re-enable after adding visibility modifiers to all public APIs
    // explicitApi()
}

// ============================================
// Dependencies (Using Version Catalog)
// ============================================
dependencies {
    // Kotlin
    implementation(libs.bundles.kotlin)

    // Logging
    implementation(libs.slf4j.api)

    // JSON parsing
    implementation(libs.json)

    // Testing
    testImplementation(libs.bundles.testing)
    testRuntimeOnly(libs.logback.classic)

    // JMH (Performance benchmarking)
    jmhImplementation(libs.bundles.jmh)
}

// ============================================
// Kotlin Compilation Options
// ============================================
tasks.withType<KotlinCompile>().configureEach {
    compilerOptions {
        freeCompilerArgs.addAll(
            "-Xjsr305=strict",                    // Strict null-safety
            "-opt-in=kotlin.RequiresOptIn",       // Opt-in annotations
            "-Xjvm-default=all",                   // Default methods in interfaces
            "-Xcontext-receivers"                  // Context receivers (Kotlin 1.9+)
        )
        jvmTarget.set(JvmTarget.JVM_17)
        allWarningsAsErrors.set(false)            // Set to true in CI
    }
}

// ============================================
// Testing Configuration
// ============================================
tasks.test {
    useJUnitPlatform {
        // Exclude load/stress tests from the default test run — they require explicit opt-in
        // via ./gradlew test -Pload or the dedicated loadTest task below
        if (!project.hasProperty("load")) {
            excludeTags("load", "slow")
        }
    }

    // Native library is NOT thread-safe across parallel JVM forks; use 1 fork
    maxParallelForks = 1

    // Run tests from the repo root so relative paths like config/regions/regions.json
    // and data/valhalla_tiles/ resolve correctly.
    // rootDir = .../valhalla/src/bindings/java  →  three parentFile calls reach valhalla/
    workingDir = rootDir.parentFile.parentFile.parentFile

    // Native library path configuration
    systemProperty("java.library.path",
        "${layout.buildDirectory.get().asFile}/libs/native/Release:${System.getProperty("java.library.path")}")

    // Test reporting
    testLogging {
        events("passed", "skipped", "failed")
        exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL
        showStandardStreams = false
    }

    // Test execution options
    failFast = false

    // Memory settings for tests
    minHeapSize = "512m"
    maxHeapSize = "2g"
}

// Dedicated task to run load/stress tests explicitly
val loadTest by tasks.registering(Test::class) {
    group = "verification"
    description = "Run load and stress tests (requires Singapore tiles)"

    useJUnitPlatform {
        includeTags("load")
    }

    maxParallelForks = 1
    workingDir = rootDir.parentFile.parentFile.parentFile

    systemProperty("java.library.path",
        "${layout.buildDirectory.get().asFile}/libs/native/Release:${System.getProperty("java.library.path")}")

    testLogging {
        events("passed", "skipped", "failed")
        exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL
        showStandardStreams = true
    }

    minHeapSize = "512m"
    maxHeapSize = "4g"
}

// ============================================
// Native Library Build Task
// ============================================
val buildNative by tasks.registering(Exec::class) {
    group = "build"
    description = "Build native JNI library using CMake"

    workingDir = projectDir

    // Only build if library doesn't exist or is outdated
    val nativeLib = file("${layout.buildDirectory.get().asFile}/libs/native/Release/libvalhalla_jni.so")
    val cppSource = file("src/main/cpp/valhalla_jni.cc")

    inputs.file(cppSource)
    outputs.file(nativeLib)

    onlyIf {
        !nativeLib.exists() || cppSource.lastModified() > nativeLib.lastModified()
    }

    // Platform-specific command
    if (System.getProperty("os.name").lowercase().contains("windows")) {
        commandLine("cmd", "/c", "cmake -B build -S . && cmake --build build --config Release")
    } else {
        commandLine("sh", "-c", "cmake -B build -S . && cmake --build build --config Release -j$(nproc)")
    }

    // Log output
    doFirst {
        logger.lifecycle("Building native JNI library...")
    }

    doLast {
        logger.lifecycle("Native library built: $nativeLib")
    }
}

// ============================================
// Resource Processing
// ============================================
tasks.processResources {
    // All .so files under lib/ are real files in Docker (symlinks copied as files in Step B of Dockerfile.prod)
}

// ============================================
// JAR Configuration
// ============================================
tasks.jar {
    dependsOn(buildNative)

    manifest {
        attributes(
            mapOf(
                "Implementation-Title" to project.name,
                "Implementation-Version" to project.version,
                "Implementation-Vendor" to "Valhalla",
                "Built-By" to System.getProperty("user.name"),
                "Built-JDK" to System.getProperty("java.version"),
                "Build-Time" to Instant.now().toString()
            )
        )
    }

    // Reproducible builds
    isPreserveFileTimestamps = false
    isReproducibleFileOrder = true
}

// ============================================
// Documentation (Dokka)
// ============================================
tasks.dokkaHtml.configure {
    outputDirectory.set(layout.buildDirectory.dir("dokka"))

    dokkaSourceSets {
        named("main") {
            moduleName.set("Valhalla JNI")
            includes.from("docs/packages.md")

            sourceLink {
                localDirectory.set(file("src/main/kotlin"))
                remoteUrl.set(uri("https://github.com/valhalla/valhalla/tree/master/src/bindings/java/src/main/kotlin").toURL())
                remoteLineSuffix.set("#L")
            }
        }
    }
}

// ============================================
// Code Quality (Detekt)
// ============================================
detekt {
    buildUponDefaultConfig = true
    allRules = false
    config.setFrom(files("$rootDir/detekt-config.yml"))
    ignoreFailures = true  // Don't fail build on code quality issues
}

tasks.withType<io.gitlab.arturbosch.detekt.Detekt>().configureEach {
    jvmTarget = "17"

    // Exclude generated files
    exclude("**/build/**")

    reports {
        html.required.set(true)
        xml.required.set(false)
        txt.required.set(false)
        sarif.required.set(true)
    }
}

// ============================================
// Performance Benchmarking (JMH)
// ============================================
jmh {
    // JMH version is managed by version catalog
    includes.add(".*Benchmark.*")

    // Benchmark configuration
    iterations.set(5)
    warmupIterations.set(3)
    fork.set(1)

    // Output
    resultFormat.set("JSON")
    resultsFile.set(layout.buildDirectory.file("reports/jmh/results.json"))

    // JVM arguments
    jvmArgs.addAll(listOf("-Xmx4g", "-Xms2g"))
}

// ============================================
// Maven Publishing
// ============================================
publishing {
    repositories {
        maven {
            name = "GitHubPackages"
            url = uri("https://maven.pkg.github.com/easi6dev/valhalla")
            credentials {
                username = System.getenv("GITHUB_USERNAME")
                password = System.getenv("GITHUB_TOKEN")
            }
        }
    }

    publications {
        register("gpr", MavenPublication::class) {
            artifactId = "valhalla-jni"
            from(components["java"])
            // sourcesJar is auto-created by java { withSourcesJar() } above
        }
    }
}

// ============================================
// Custom Tasks
// ============================================

// Task: Clean native build
val cleanNative by tasks.registering(Delete::class) {
    group = "build"
    description = "Clean native build directory"
    delete("${projectDir}/build/libs/native")
}

tasks.clean {
    dependsOn(cleanNative)
}

// Task: Build report
val buildReport by tasks.registering {
    group = "help"
    description = "Generate build report with metrics"

    doLast {
        val report = StringBuilder()
        report.appendLine("=" .repeat(60))
        report.appendLine("Valhalla JNI Build Report")
        report.appendLine("=" .repeat(60))
        report.appendLine("Project: ${project.name}")
        report.appendLine("Version: ${project.version}")
        report.appendLine("Group: ${project.group}")
        report.appendLine()
        report.appendLine("Build Configuration:")
        report.appendLine("  - Kotlin: ${libs.versions.kotlin.get()}")
        report.appendLine("  - Java: 17")
        report.appendLine("  - Parallel: ${gradle.startParameter.isParallelProjectExecutionEnabled}")
        report.appendLine("  - Build Cache: ${gradle.startParameter.isBuildCacheEnabled}")
        report.appendLine("  - Max Workers: ${gradle.startParameter.maxWorkerCount}")
        report.appendLine()
        report.appendLine("Dependencies:")
        configurations.runtimeClasspath.get().resolvedConfiguration.resolvedArtifacts.forEach {
            report.appendLine("  - ${it.moduleVersion.id}")
        }
        report.appendLine()
        report.appendLine("Build Directory: ${layout.buildDirectory.get().asFile}")
        report.appendLine("=" .repeat(60))

        println(report.toString())

        // Save to file
        val reportFile = layout.buildDirectory.file("reports/build-report.txt").get().asFile
        reportFile.parentFile.mkdirs()
        reportFile.writeText(report.toString())

        logger.lifecycle("Build report saved to: ${reportFile.absolutePath}")
    }
}

// Task: Dependency updates check
val checkDependencyUpdates by tasks.registering {
    group = "help"
    description = "Check for dependency updates"

    doLast {
        logger.lifecycle("Run './gradlew dependencyUpdates' to check for available dependency updates")
        logger.lifecycle("(Requires: id(\"com.github.ben-manes.versions\") plugin)")
    }
}

// Task: Full build with all checks
val fullBuild by tasks.registering {
    group = "build"
    description = "Run full build with all checks (tests, detekt, dokka)"

    dependsOn(
        tasks.clean,
        tasks.build,
        tasks.test,
        tasks.detekt,
        tasks.dokkaHtml
    )

    doLast {
        val buildDirPath = layout.buildDirectory.get().asFile
        logger.lifecycle("✅ Full build completed successfully!")
        logger.lifecycle("📊 Reports available at:")
        logger.lifecycle("  - Tests: ${buildDirPath}/reports/tests/test/index.html")
        logger.lifecycle("  - Detekt: ${buildDirPath}/reports/detekt/detekt.html")
        logger.lifecycle("  - Dokka: ${buildDirPath}/dokka/index.html")
    }
}

// ============================================
// IDE Configuration
// ============================================
idea {
    module {
        isDownloadJavadoc = true
        isDownloadSources = true
    }
}

// ============================================
// Gradle Wrapper Validation
// ============================================
// Note: wrapper task only exists at root project level, not in subprojects
// Configure wrapper in the root build.gradle.kts if needed
