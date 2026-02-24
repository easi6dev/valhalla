package global.tada.valhalla.config

import org.json.JSONObject
import java.io.File

/**
 * Factory for creating region-specific configurations
 *
 * This factory provides a centralized way to build Valhalla configurations
 * for different regions (Singapore, Thailand, etc.)
 *
 * Configuration Source: config/regions/regions.json (single source of truth)
 *
 * Environment Configuration:
 * - Tile directory root is configurable via VALHALLA_TILE_DIR environment variable
 * - Default: data/valhalla_tiles (development)
 * - Production: Set VALHALLA_TILE_DIR=/var/valhalla/tiles
 */
object RegionConfigFactory {

    private const val DEFAULT_REGIONS_FILE = "config/regions/regions.json"
    private const val DEFAULT_TILE_DIR_ROOT = "data/valhalla_tiles"

    // Cache for loaded regions config
    @Volatile
    private var cachedRegionsConfig: JSONObject? = null
    private val cacheLock = Any()

    /**
     * Get tile directory root from environment
     *
     * Checks in order:
     * 1. Environment variable: VALHALLA_TILE_DIR
     * 2. System property: valhalla.tile.dir
     * 3. Default: data/valhalla_tiles
     *
     * @return Tile directory root path
     */
    private fun getTileDirRoot(): String {
        return System.getenv("VALHALLA_TILE_DIR")
            ?: System.getProperty("valhalla.tile.dir")
            ?: DEFAULT_TILE_DIR_ROOT
    }

    /**
     * Load regions configuration from file
     * Uses caching to avoid repeated file reads
     * Validates configuration on load
     *
     * @param regionsFile Path to regions.json file
     * @param skipValidation Skip validation (for performance, default: false)
     * @return Parsed JSON object
     */
    private fun loadRegionsConfig(
        regionsFile: String = DEFAULT_REGIONS_FILE,
        skipValidation: Boolean = false
    ): JSONObject {
        // Double-check locking for cache
        cachedRegionsConfig?.let { return it }

        synchronized(cacheLock) {
            cachedRegionsConfig?.let { return it }

            val file = File(regionsFile)
            if (!file.exists()) {
                throw IllegalArgumentException(
                    "Regions config file not found: $regionsFile\n" +
                    "Expected location: ${file.absolutePath}"
                )
            }

            // Validate configuration before caching
            if (!skipValidation) {
                val validation = RegionConfigValidator.validate(regionsFile, validateTiles = false)
                if (validation.hasErrors()) {
                    throw IllegalArgumentException(
                        "Invalid regions configuration:\n${validation}"
                    )
                }
            }

            val config = JSONObject(file.readText())
            cachedRegionsConfig = config
            return config
        }
    }

    /**
     * Build configuration for a specific region
     *
     * Loads configuration from regions.json and builds Valhalla config
     *
     * @param region Region name (e.g., "singapore", "thailand", "sg", "th")
     * @param tileDir Full path to tile directory (if null, constructs from VALHALLA_TILE_DIR + region)
     * @param enableTraffic Enable traffic-aware routing
     * @param regionsFile Path to regions.json (default: config/regions/regions.json)
     * @return JSON configuration string
     * @throws IllegalArgumentException if region is not supported or disabled
     *
     * Environment Configuration:
     * - Set VALHALLA_TILE_DIR to configure tile directory root (e.g., /var/valhalla/tiles)
     * - Default: data/valhalla_tiles
     * - Or use system property: -Dvalhalla.tile.dir=/var/valhalla/tiles
     */
    fun buildConfig(
        region: String,
        tileDir: String? = null,
        enableTraffic: Boolean = false,
        regionsFile: String? = null
    ): String {
        val resolvedRegionsFile = regionsFile ?: DEFAULT_REGIONS_FILE
        val normalizedRegion = normalizeRegionName(region)
        val regionsConfig = loadRegionsConfig(resolvedRegionsFile)
        val regions = regionsConfig.getJSONObject("regions")

        if (!regions.has(normalizedRegion)) {
            throw IllegalArgumentException(
                "Unsupported region: $region\n" +
                "Supported regions: ${getSupportedRegions(resolvedRegionsFile).joinToString(", ")}\n" +
                "Using config file: $resolvedRegionsFile"
            )
        }

        val regionConfig = regions.getJSONObject(normalizedRegion)

        // Check if region is enabled
        if (!regionConfig.optBoolean("enabled", false)) {
            throw IllegalStateException(
                "Region '$region' is disabled in configuration.\n" +
                "Enable it in $resolvedRegionsFile by setting 'enabled': true"
            )
        }

        // Get tile directory
        // Priority: 1. Parameter override, 2. Construct from VALHALLA_TILE_DIR + region subdir
        val resolvedTileDir = tileDir ?: run {
            val tileDirRoot = getTileDirRoot()
            val regionSubdir = regionConfig.getString("tile_dir")
            "$tileDirRoot/$regionSubdir"
        }
        val absoluteTileDir = File(resolvedTileDir).canonicalPath.replace("\\", "/")

        // Build Valhalla configuration
        return buildValhallaConfig(
            regionConfig = regionConfig,
            tileDir = absoluteTileDir,
            enableTraffic = enableTraffic
        )
    }

    /**
     * Build Valhalla configuration JSON from region config
     */
    private fun buildValhallaConfig(
        regionConfig: JSONObject,
        tileDir: String,
        enableTraffic: Boolean
    ): String {
        // Get costing options if present
        val costingOptions = regionConfig.optJSONObject("costing_options")

        return """
        {
          "mjolnir": {
            "tile_dir": "$tileDir",
            "max_cache_size": 1073741824,
            "concurrency": 4
          },
          "loki": {
            "actions": [
              "locate",
              "route",
              "sources_to_targets",
              "optimized_route",
              "isochrone",
              "trace_route",
              "trace_attributes",
              "status"
            ],
            "service_defaults": {
              "minimum_reachability": 50,
              "radius": 0,
              "search_cutoff": 35000,
              "node_snap_tolerance": 5,
              "street_side_tolerance": 5,
              "street_side_max_distance": 1000,
              "heading_tolerance": 60
            }
          },
          "thor": {
            "source_to_target_algorithm": "select_optimal",
            "extended_search": false
          },
          "meili": {
            "mode": "auto",
            "customizable": ["mode", "search_radius", "turn_penalty_factor", "gps_accuracy", "interpolation_distance", "sigma_z", "beta", "max_route_distance_factor", "max_route_time_factor"],
            "default": {
              "sigma_z": 4.07,
              "gps_accuracy": 5.0,
              "beta": 3,
              "max_route_distance_factor": 5,
              "max_route_time_factor": 5,
              "breakage_distance": 2000,
              "interpolation_distance": 10,
              "search_radius": 50,
              "geometry": false,
              "route": true,
              "turn_penalty_factor": 200
            },
            "auto": {
              "turn_penalty_factor": 200,
              "search_radius": 50
            },
            "pedestrian": {
              "turn_penalty_factor": 100,
              "search_radius": 25
            },
            "bicycle": {
              "turn_penalty_factor": 140,
              "search_radius": 25
            },
            "grid": {
              "size": 500,
              "cache_size": 100240
            }
          },
          "service_limits": {
            "auto": {
              "max_distance": 5000000.0,
              "max_locations": 20,
              "max_matrix_distance": 400000.0,
              "max_matrix_location_pairs": 5000
            },
            "taxi": {
              "max_distance": 5000000.0,
              "max_locations": 20,
              "max_matrix_distance": 400000.0,
              "max_matrix_location_pairs": 5000
            },
            "motorcycle": {
              "max_distance": 500000.0,
              "max_locations": 50,
              "max_matrix_distance": 200000.0,
              "max_matrix_location_pairs": 2500
            },
            "pedestrian": {
              "max_distance": 250000.0,
              "max_locations": 50,
              "max_matrix_distance": 200000.0,
              "max_matrix_location_pairs": 2500,
              "min_transit_walking_distance": 1,
              "max_transit_walking_distance": 10000
            },
            "bicycle": {
              "max_distance": 500000.0,
              "max_locations": 50,
              "max_matrix_distance": 200000.0,
              "max_matrix_location_pairs": 2500
            },
            "isochrone": {
              "max_contours": 4,
              "max_time_contour": 120,
              "max_distance": 200000.0,
              "max_locations": 1,
              "max_distance_contour": 200
            },
            "trace": {
              "max_distance": 200000.0,
              "max_gps_accuracy": 100.0,
              "max_search_radius": 100.0,
              "max_shape": 16000,
              "max_best_paths": 4,
              "max_best_paths_shape": 100,
              "max_alternates": 3,
              "max_alternates_shape": 100
            },
            "skadi": {
              "max_shape": 500000,
              "min_resample": 10.0
            },
            "max_exclude_locations": 50,
            "max_reachability": 100,
            "max_radius": 200,
            "max_timedep_distance": 500000,
            "max_alternates": 2,
            "max_exclude_polygons_length": 10000,
            "status": {}
          }
        }
        """.trimIndent()
    }

    /**
     * Normalize region name (handle aliases like "sg" -> "singapore")
     */
    private fun normalizeRegionName(region: String): String {
        return when (region.lowercase().trim()) {
            "sg" -> "singapore"
            "th" -> "thailand"
            "my" -> "malaysia"
            else -> region.lowercase().trim()
        }
    }

    /**
     * Get list of supported regions from configuration
     *
     * @param regionsFile Path to regions.json
     * @return List of region keys
     */
    fun getSupportedRegions(regionsFile: String = DEFAULT_REGIONS_FILE): List<String> {
        val regionsConfig = loadRegionsConfig(regionsFile)
        val regions = regionsConfig.getJSONObject("regions")
        return regions.keys().asSequence().toList()
    }

    /**
     * Check if a region is supported
     *
     * @param region Region name
     * @param regionsFile Path to regions.json
     * @return True if region is supported
     */
    fun isSupported(region: String, regionsFile: String = DEFAULT_REGIONS_FILE): Boolean {
        val normalizedRegion = normalizeRegionName(region)
        return normalizedRegion in getSupportedRegions(regionsFile)
    }

    /**
     * Get region information
     *
     * @param region Region name
     * @param regionsFile Path to regions.json
     * @return Map of region metadata (name, timezone, locale, currency, bounds, etc.)
     */
    fun getRegionInfo(region: String, regionsFile: String = DEFAULT_REGIONS_FILE): Map<String, Any> {
        val normalizedRegion = normalizeRegionName(region)
        val regionsConfig = loadRegionsConfig(regionsFile)
        val regions = regionsConfig.getJSONObject("regions")

        if (!regions.has(normalizedRegion)) {
            throw IllegalArgumentException("Unsupported region: $region")
        }

        val regionConfig = regions.getJSONObject(normalizedRegion)

        return mapOf(
            "key" to normalizedRegion,
            "name" to regionConfig.getString("name"),
            "enabled" to regionConfig.getBoolean("enabled"),
            "timezone" to regionConfig.optString("timezone", "UTC"),
            "locale" to regionConfig.optString("locale", "en"),
            "currency" to regionConfig.optString("currency", "USD"),
            "tile_dir" to regionConfig.getString("tile_dir"),
            "osm_source" to regionConfig.optString("osm_source", ""),
            "bounds" to getBoundsMap(regionConfig.getJSONObject("bounds"))
        )
    }

    /**
     * Convert bounds JSON to map
     */
    private fun getBoundsMap(bounds: JSONObject): Map<String, Double> {
        return mapOf(
            "min_lat" to bounds.getDouble("min_lat"),
            "max_lat" to bounds.getDouble("max_lat"),
            "min_lon" to bounds.getDouble("min_lon"),
            "max_lon" to bounds.getDouble("max_lon")
        )
    }

    /**
     * Clear configuration cache (useful for testing or config hot-reload)
     */
    fun clearCache() {
        synchronized(cacheLock) {
            cachedRegionsConfig = null
        }
    }
}
