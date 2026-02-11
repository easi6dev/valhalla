plugins {
    kotlin("jvm") version "1.9.25"
    `java-library`
    `maven-publish`
}

group = findProperty("group") as String? ?: "global.tada.valhalla"
version = findProperty("version") as String? ?: "1.0.0-SNAPSHOT"

repositories {
    mavenCentral()
}

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
    withSourcesJar()
    withJavadocJar()
}

kotlin {
    jvmToolchain(17)
}

dependencies {
    // Kotlin Standard Library
    implementation(kotlin("stdlib"))
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.8.1")

    // SLF4J for logging (optional, but recommended)
    implementation("org.slf4j:slf4j-api:2.0.13")

    // JSON parsing (used in config classes)
    implementation("org.json:json:20240303")

    // Testing
    testImplementation(kotlin("test"))
    testImplementation("org.junit.jupiter:junit-jupiter:5.10.3")
    testImplementation("org.assertj:assertj-core:3.26.3")
    testRuntimeOnly("ch.qos.logback:logback-classic:1.5.6")
}

tasks.test {
    useJUnitPlatform()

    // Native library path 설정
    systemProperty("java.library.path",
        "${project.buildDir}/libs/native/Release:${System.getProperty("java.library.path")}")
}

tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile> {
    kotlinOptions {
        freeCompilerArgs = listOf(
            "-Xjsr305=strict",
            "-opt-in=kotlin.RequiresOptIn"
        )
        jvmTarget = "17"
    }
}

// Native library 빌드를 위한 커스텀 태스크
tasks.register<Exec>("buildNative") {
    group = "build"
    description = "Build native JNI library using CMake"

    workingDir = projectDir

    onlyIf {
        file("${project.buildDir}/libs/native/Release").listFiles().isEmpty()
    }

    // Windows에서는 cmd를 통해 실행
    if (System.getProperty("os.name").lowercase().contains("windows")) {
        commandLine("cmd", "/c", "cmake", "-B", "build", "-S", ".", "&&", "cmake", "--build", "build", "--config", "Release")
    } else {
        commandLine("sh", "-c", "cmake -B build -S . && cmake --build build --config Release")
    }
}

// jar 빌드 전에 네이티브 라이브러리 빌드
tasks.named("jar") {
    dependsOn("buildNative")
}

publishing {
    publications {
        create<MavenPublication>("maven") {
            from(components["java"])

            pom {
                name.set("Valhalla JNI")
                description.set("Java/Kotlin bindings for Valhalla routing engine")
                url.set("https://github.com/valhalla/valhalla")

                licenses {
                    license {
                        name.set("MIT License")
                        url.set("https://opensource.org/licenses/MIT")
                    }
                }

                developers {
                    developer {
                        id.set("valhalla")
                        name.set("Valhalla Contributors")
                    }
                }

                scm {
                    connection.set("scm:git:git://github.com/valhalla/valhalla.git")
                    developerConnection.set("scm:git:ssh://github.com/valhalla/valhalla.git")
                    url.set("https://github.com/valhalla/valhalla")
                }
            }
        }
    }
}
