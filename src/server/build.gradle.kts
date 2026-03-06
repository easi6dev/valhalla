plugins {
    alias(libs.plugins.kotlin.jvm)
    application
}

group = "global.tada.valhalla"
version = "1.0.0-SNAPSHOT"

val ktorVersion = "2.3.12"

repositories {
    mavenCentral()
}

dependencies {
    // Valhalla JNI library (sibling subproject)
    implementation(project(":java-bindings"))

    // Ktor server
    implementation("io.ktor:ktor-server-core:$ktorVersion")
    implementation("io.ktor:ktor-server-netty:$ktorVersion")
    implementation("io.ktor:ktor-server-content-negotiation:$ktorVersion")
    implementation("io.ktor:ktor-server-status-pages:$ktorVersion")
    implementation("io.ktor:ktor-server-call-logging:$ktorVersion")
    implementation("io.ktor:ktor-serialization-kotlinx-json:$ktorVersion")

    // Kotlin
    implementation(libs.bundles.kotlin)

    // Logging
    implementation(libs.slf4j.api)
    implementation(libs.logback.classic)
}

application {
    mainClass.set("global.tada.valhalla.server.ApplicationKt")
}

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

kotlin {
    jvmToolchain(17)
}

// Fat JAR — includes all dependencies so the server can run standalone
tasks.jar {
    manifest {
        attributes["Main-Class"] = "global.tada.valhalla.server.ApplicationKt"
    }
    from(configurations.runtimeClasspath.get().map { if (it.isDirectory) it else zipTree(it) })
    duplicatesStrategy = DuplicatesStrategy.EXCLUDE
}
