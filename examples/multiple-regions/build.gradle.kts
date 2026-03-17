plugins {
    kotlin("jvm") version "2.0.21"
    application
}

group = "examples"
version = "1.0.0"

repositories {
    mavenLocal()
    mavenCentral()
}

dependencies {
    implementation("global.tada.valhalla:valhalla-jni:1.0.0-SNAPSHOT")
    implementation(kotlin("stdlib"))
}

application {
    mainClass.set("examples.MultiRegionExampleKt")
}

tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile> {
    kotlinOptions {
        jvmTarget = "17"
    }
}

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}
