// ============================================
// Valhalla JNI Settings
// ============================================
// Phase 4 Optimizations:
// - Dependency resolution optimization
// - Build cache configuration
// - Plugin management
// ============================================

rootProject.name = "valhalla-jni"

// ============================================
// Dependency Resolution Management
// ============================================
dependencyResolutionManagement {
    // Use version catalog
    versionCatalogs {
        create("libs") {
            from(files("../../../gradle/libs.versions.toml"))
        }
    }

    // Repository order (fastest first)
    repositories {
        mavenCentral()
        google()
    }

    // Repository filtering (security + performance)
    repositoriesMode.set(RepositoriesMode.PREFER_SETTINGS)
}

// ============================================
// Plugin Management
// ============================================
pluginManagement {
    repositories {
        gradlePluginPortal()
        mavenCentral()
        google()
    }
}

// ============================================
// Build Cache
// ============================================
buildCache {
    local {
        isEnabled = true
        directory = file("${rootDir}/.gradle/build-cache")
        removeUnusedEntriesAfterDays = 30
    }

    // Remote cache (optional - for CI/CD or team sharing)
    // remote<HttpBuildCache> {
    //     url = uri("https://your-build-cache-server.example.com/cache/")
    //     credentials {
    //         username = System.getenv("BUILD_CACHE_USERNAME")
    //         password = System.getenv("BUILD_CACHE_PASSWORD")
    //     }
    //     isPush = System.getenv("CI")?.toBoolean() == true
    // }
}

// ============================================
// Feature Previews (Experimental)
// ============================================
enableFeaturePreview("TYPESAFE_PROJECT_ACCESSORS")
enableFeaturePreview("STABLE_CONFIGURATION_CACHE")

// ============================================
// Gradle Enterprise (Optional)
// ============================================
// plugins {
//     id("com.gradle.enterprise") version "3.16"
// }
//
// gradleEnterprise {
//     buildScan {
//         termsOfServiceUrl = "https://gradle.com/terms-of-service"
//         termsOfServiceAgree = "yes"
//     }
// }
