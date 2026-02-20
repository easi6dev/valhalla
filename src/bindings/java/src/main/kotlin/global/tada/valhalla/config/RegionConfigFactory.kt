package global.tada.valhalla.config

/**
 * Factory for creating region-specific configurations
 *
 * This factory provides a centralized way to build Valhalla configurations
 * for different regions (Singapore, Thailand, etc.)
 */
object RegionConfigFactory {

    /**
     * Build configuration for a specific region
     *
     * @param region Region name (e.g., "singapore", "thailand")
     * @param tileDir Path to tile directory
     * @param enableTraffic Enable traffic-aware routing
     * @return JSON configuration string
     * @throws IllegalArgumentException if region is not supported
     */
    fun buildConfig(
        region: String,
        tileDir: String,
        enableTraffic: Boolean = false
    ): String {
        return when (region.lowercase().trim()) {
            "singapore", "sg" -> SingaporeConfig.buildConfig(tileDir, enableTraffic)
            else -> throw IllegalArgumentException(
                "Unsupported region: $region. Supported regions: singapore, sg"
            )
        }
    }

    /**
     * Get list of supported regions
     */
    fun getSupportedRegions(): List<String> {
        return listOf("singapore", "sg")
    }

    /**
     * Check if a region is supported
     */
    fun isSupported(region: String): Boolean {
        return region.lowercase().trim() in getSupportedRegions()
    }

    /**
     * Get region information
     */
    fun getRegionInfo(region: String): Map<String, Any> {
        return when (region.lowercase().trim()) {
            "singapore", "sg" -> mapOf(
                "name" to SingaporeConfig.regionName,
                "timezone" to SingaporeConfig.timezone,
                "locale" to SingaporeConfig.locale,
                "currency" to SingaporeConfig.currency
            )
            else -> throw IllegalArgumentException("Unsupported region: $region")
        }
    }
}
