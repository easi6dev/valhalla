package global.tada.valhalla.config

import org.json.JSONObject
import java.io.File

/**
 * Multi-region configuration helper for Valhalla Actor
 * Supports loading configuration for different regions (Singapore, Thailand, etc.)
 */
object RegionConfig {

    /**
     * Supported regions
     */
    enum class Region(val key: String, val displayName: String) {
        SINGAPORE("singapore", "Singapore"),
        THAILAND("thailand", "Thailand");

        companion object {
            fun fromKey(key: String): Region? = values().find { it.key == key }
        }
    }

    /**
     * Load region configuration from regions.json
     *
     * @param region Region to load
     * @param regionsConfigFile Path to regions.json (default: config/regions/regions.json)
     * @return Configuration string for the region
     */
    fun loadRegionConfig(
        region: Region,
        regionsConfigFile: String = "config/regions/regions.json"
    ): String {
        val file = File(regionsConfigFile)
        if (!file.exists()) {
            throw IllegalArgumentException("Regions config file not found: $regionsConfigFile")
        }

        val json = JSONObject(file.readText())
        val regions = json.getJSONObject("regions")

        if (!regions.has(region.key)) {
            throw IllegalArgumentException("Region '${region.key}' not found in config")
        }

        val regionConfig = regions.getJSONObject(region.key)

        // Check if region is enabled
        if (!regionConfig.getBoolean("enabled")) {
            throw IllegalStateException(
                "Region '${region.displayName}' is disabled. " +
                "Enable it in $regionsConfigFile"
            )
        }

        // Extract region configuration
        val tileDir = regionConfig.getString("tile_dir")
        val costingOptions = if (regionConfig.has("costing_options")) {
            regionConfig.getJSONObject("costing_options")
        } else {
            JSONObject()
        }

        // Build Valhalla configuration
        return buildRegionConfig(
            region = region,
            tileDir = tileDir,
            costingOptions = costingOptions
        )
    }

    /**
     * Build configuration for a specific region
     */
    private fun buildRegionConfig(
        region: Region,
        tileDir: String,
        costingOptions: JSONObject
    ): String {
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
              "status"
            ],
            "service_defaults": {
              "minimum_reachability": 50,
              "radius": 0,
              "search_cutoff": 35000
            }
          },
          "thor": {
            "source_to_target_algorithm": "select_optimal"
          },
          "service_limits": {
            "auto": {
              "max_distance": 5000000.0,
              "max_locations": 20,
              "max_matrix_distance": 400000.0,
              "max_matrix_location_pairs": 5000
            }
          }
        }
        """.trimIndent()
    }

    /**
     * Get region bounds from configuration
     */
    fun getRegionBounds(
        region: Region,
        regionsConfigFile: String = "config/regions/regions.json"
    ): RegionBounds {
        val file = File(regionsConfigFile)
        if (!file.exists()) {
            throw IllegalArgumentException("Regions config file not found: $regionsConfigFile")
        }

        val json = JSONObject(file.readText())
        val regionConfig = json.getJSONObject("regions").getJSONObject(region.key)
        val bounds = regionConfig.getJSONObject("bounds")

        return RegionBounds(
            minLat = bounds.getDouble("min_lat"),
            maxLat = bounds.getDouble("max_lat"),
            minLon = bounds.getDouble("min_lon"),
            maxLon = bounds.getDouble("max_lon")
        )
    }

    /**
     * Check if a location is within region bounds
     */
    fun isLocationInRegion(
        lat: Double,
        lon: Double,
        region: Region,
        regionsConfigFile: String = "config/regions/regions.json"
    ): Boolean {
        val bounds = getRegionBounds(region, regionsConfigFile)
        return lat in bounds.minLat..bounds.maxLat && lon in bounds.minLon..bounds.maxLon
    }

    /**
     * Get all available regions from configuration
     */
    fun getAvailableRegions(
        regionsConfigFile: String = "config/regions/regions.json"
    ): List<RegionInfo> {
        val file = File(regionsConfigFile)
        if (!file.exists()) {
            return emptyList()
        }

        val json = JSONObject(file.readText())
        val regions = json.getJSONObject("regions")
        val result = mutableListOf<RegionInfo>()

        for (key in regions.keys()) {
            val regionConfig = regions.getJSONObject(key)
            result.add(RegionInfo(
                key = key,
                name = regionConfig.getString("name"),
                enabled = regionConfig.getBoolean("enabled"),
                osmSource = regionConfig.optString("osm_source", "")
            ))
        }

        return result
    }

    /**
     * Region bounds data class
     */
    data class RegionBounds(
        val minLat: Double,
        val maxLat: Double,
        val minLon: Double,
        val maxLon: Double
    )

    /**
     * Region information data class
     */
    data class RegionInfo(
        val key: String,
        val name: String,
        val enabled: Boolean,
        val osmSource: String
    )
}
