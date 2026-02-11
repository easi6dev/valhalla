// Root Gradle settings for Valhalla project
// This enables IntelliJ IDEA to recognize the Java/Kotlin subproject

rootProject.name = "valhalla"

// Include Java bindings subproject
include(":java-bindings")
project(":java-bindings").projectDir = file("src/bindings/java")
