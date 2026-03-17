package global.tada.valhalla.config

import java.io.File

/**
 * Simple configuration for external tile folder locations
 *
 * This allows you to specify tile directories via:
 * 1. Environment variables
 * 2. System properties
 * 3. Configuration file
 * 4. Direct parameter
 *
 * Usage:
 * ```kotlin
 * // Option 1: Environment variable
 * // Set: VALHALLA_TILE_DIR=/mnt/tiles
 * val config = TileConfig.fromEnvironment()
 *
 * // Option 2: Direct path
 * val config = TileConfig.fromPath("/mnt/tiles/singapore")
 *
 * // Option 3: System property
 * // java -Dvalhalla.tiles.dir=/mnt/tiles
 * val config = TileConfig.fromSystemProperty()
 * ```
 */
object TileConfig {
    /**
     * Default tile directory locations to check
     */
    private val DEFAULT_TILE_PATHS = listOf(
        "data/valhalla_tiles",
        "/var/lib/valhalla/tiles",
        "/mnt/valhalla/tiles",
        "C:/valhalla/tiles"
    )

    /**
     * Get tile directory from environment variable
     *
     * Checks: VALHALLA_TILE_DIR, VALHALLA_TILES_DIR (legacy), TILES_DIR
     *
     * @param defaultPath Fallback path if env var not set
     * @return Tile directory path
     */
    fun fromEnvironment(defaultPath: String = "data/valhalla_tiles"): String {
        val envVars = listOf("VALHALLA_TILE_DIR", "VALHALLA_TILES_DIR", "TILES_DIR")

        for (envVar in envVars) {
            val path = System.getenv(envVar)
            if (!path.isNullOrBlank()) {
                return normalizePath(path)
            }
        }

        return normalizePath(defaultPath)
    }

    /**
     * Get tile directory from system property
     *
     * Checks: valhalla.tiles.dir, valhalla.tile.dir
     *
     * @param defaultPath Fallback path if property not set
     * @return Tile directory path
     */
    fun fromSystemProperty(defaultPath: String = "data/valhalla_tiles"): String {
        val properties = listOf("valhalla.tiles.dir", "valhalla.tile.dir")

        for (property in properties) {
            val path = System.getProperty(property)
            if (!path.isNullOrBlank()) {
                return normalizePath(path)
            }
        }

        return normalizePath(defaultPath)
    }

    /**
     * Get tile directory from direct path
     *
     * @param path Tile directory path
     * @return Normalized tile directory path
     */
    fun fromPath(path: String): String {
        return normalizePath(path)
    }

    /**
     * Get tile directory with automatic detection
     *
     * Checks in order:
     * 1. System property (valhalla.tiles.dir)
     * 2. Environment variable (VALHALLA_TILE_DIR)
     * 3. Environment variable (VALHALLA_TILES_DIR) — legacy alias, kept for backward compat
     * 4. Default locations (data/valhalla_tiles, /var/lib/valhalla/tiles, etc.)
     *
     * @param region Optional region subdirectory (e.g., "singapore")
     * @return Tile directory path
     */
    fun autoDetect(region: String? = null): String {
        // Try system property first
        val sysPropPath = System.getProperty("valhalla.tiles.dir")
        if (!sysPropPath.isNullOrBlank()) {
            return resolvePath(sysPropPath, region)
        }

        // Try canonical env var, then legacy alias for backward compat
        val envPath = System.getenv("VALHALLA_TILE_DIR") ?: System.getenv("VALHALLA_TILES_DIR")
        if (!envPath.isNullOrBlank()) {
            return resolvePath(envPath, region)
        }

        // Try default locations
        for (defaultPath in DEFAULT_TILE_PATHS) {
            val path = resolvePath(defaultPath, region)
            val dir = File(path)
            if (dir.exists() && dir.isDirectory) {
                return normalizePath(path)
            }
        }

        // Fallback to first default with region
        return resolvePath(DEFAULT_TILE_PATHS.first(), region)
    }

    /**
     * Get tile directory for specific region
     *
     * @param region Region name (e.g., "singapore", "thailand")
     * @param baseDir Base tile directory
     * @return Region-specific tile directory path
     */
    fun forRegion(region: String, baseDir: String = autoDetect()): String {
        return resolvePath(baseDir, region)
    }

    /**
     * Validate that tile directory exists and contains tiles
     *
     * @param path Tile directory path
     * @return True if valid, false otherwise
     */
    fun validate(path: String): Boolean {
        val dir = File(path)
        if (!dir.exists() || !dir.isDirectory) {
            return false
        }

        // Check for common tile structure (2/ directory for zoom level 2)
        val tileDir = File(dir, "2")
        return tileDir.exists() && tileDir.isDirectory
    }

    /**
     * Normalize path (resolve canonical path, replace backslashes)
     */
    private fun normalizePath(path: String): String {
        return try {
            File(path).canonicalPath.replace("\\", "/")
        } catch (e: Exception) {
            path.replace("\\", "/")
        }
    }

    /**
     * Resolve path with optional region subdirectory
     */
    private fun resolvePath(basePath: String, region: String?): String {
        return if (region != null && region.isNotBlank()) {
            File(basePath, region).path
        } else {
            basePath
        }
    }
}

/**
 * Extension functions for easy tile configuration
 */

/**
 * Create Valhalla config with custom tile directory
 */
fun createConfigWithTileDir(tileDir: String, region: String = "singapore"): String {
    val resolvedPath = TileConfig.fromPath(tileDir)

    return when (region.lowercase()) {
        "singapore" -> RegionConfigFactory.buildConfig(
            region = "singapore",
            tileDir = resolvedPath,
            enableTraffic = false
        )
        else -> """
        {
          "mjolnir": {
            "tile_dir": "$resolvedPath",
            "max_cache_size": 1073741824,
            "concurrency": 4
          },
          "loki": {
            "actions": ["route", "locate", "sources_to_targets", "optimized_route", "isochrone"],
            "service_defaults": {
              "minimum_reachability": 50,
              "radius": 0,
              "search_cutoff": 35000
            }
          }
        }
        """.trimIndent()
    }
}
