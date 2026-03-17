// Root Gradle settings for Valhalla project

rootProject.name = "valhalla"

pluginManagement {
    repositories {
        gradlePluginPortal()
        mavenCentral()
        google()
    }
}

// Centralized version catalog (shared by all subprojects)
dependencyResolutionManagement {
    versionCatalogs {
        create("libs") {
            from(files("gradle/libs.versions.toml"))
        }
    }
    repositories {
        mavenCentral()
        google()
    }
    repositoriesMode.set(RepositoriesMode.PREFER_SETTINGS)
}

buildCache {
    local {
        isEnabled = true
        directory = file("${rootDir}/.gradle/build-cache")
        removeUnusedEntriesAfterDays = 30
    }
}

enableFeaturePreview("TYPESAFE_PROJECT_ACCESSORS")

// Subprojects
include(":java-bindings")
project(":java-bindings").projectDir = file("src/bindings/java")
