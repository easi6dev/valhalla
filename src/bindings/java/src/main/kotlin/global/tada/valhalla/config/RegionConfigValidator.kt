package global.tada.valhalla.config

import org.json.JSONObject
import java.io.File

/**
 * Validator for region configuration files
 *
 * Validates regions.json schema, bounds, tile directories, and configuration consistency
 */
object RegionConfigValidator {

    /**
     * Validation result
     */
    data class ValidationResult(
        val isValid: Boolean,
        val errors: List<String> = emptyList(),
        val warnings: List<String> = emptyList()
    ) {
        fun hasErrors() = errors.isNotEmpty()
        fun hasWarnings() = warnings.isNotEmpty()

        override fun toString(): String {
            val sb = StringBuilder()
            sb.appendLine("Validation Result: ${if (isValid) "✅ VALID" else "❌ INVALID"}")

            if (errors.isNotEmpty()) {
                sb.appendLine("\nErrors (${errors.size}):")
                errors.forEachIndexed { index, error ->
                    sb.appendLine("  ${index + 1}. $error")
                }
            }

            if (warnings.isNotEmpty()) {
                sb.appendLine("\nWarnings (${warnings.size}):")
                warnings.forEachIndexed { index, warning ->
                    sb.appendLine("  ${index + 1}. $warning")
                }
            }

            return sb.toString()
        }
    }

    /**
     * Validate regions configuration file
     *
     * @param regionsFile Path to regions.json
     * @param validateTiles Whether to validate tile directories exist (default: true)
     * @return Validation result with errors and warnings
     */
    fun validate(regionsFile: String = "config/regions/regions.json", validateTiles: Boolean = true): ValidationResult {
        val errors = mutableListOf<String>()
        val warnings = mutableListOf<String>()

        // Check file exists
        val file = File(regionsFile)
        if (!file.exists()) {
            errors.add("Config file not found: ${file.absolutePath}")
            return ValidationResult(isValid = false, errors = errors)
        }

        try {
            val config = JSONObject(file.readText())

            // Validate top-level structure
            if (!config.has("regions")) {
                errors.add("Missing required field: 'regions'")
                return ValidationResult(isValid = false, errors = errors)
            }

            val regions = config.getJSONObject("regions")
            if (regions.length() == 0) {
                warnings.add("No regions defined in configuration")
            }

            // Validate each region
            for (regionKey in regions.keys()) {
                val regionErrors = validateRegion(regionKey, regions.getJSONObject(regionKey), validateTiles)
                errors.addAll(regionErrors.map { "[$regionKey] $it" })
            }

            // Validate metadata if present
            if (config.has("metadata")) {
                val metadataErrors = validateMetadata(config.getJSONObject("metadata"))
                warnings.addAll(metadataErrors)
            }

        } catch (e: Exception) {
            errors.add("Failed to parse JSON: ${e.message}")
        }

        return ValidationResult(
            isValid = errors.isEmpty(),
            errors = errors,
            warnings = warnings
        )
    }

    /**
     * Validate a single region configuration
     */
    private fun validateRegion(regionKey: String, regionConfig: JSONObject, validateTiles: Boolean): List<String> {
        val errors = mutableListOf<String>()

        // Required fields
        val requiredFields = listOf("name", "enabled", "tile_dir", "bounds")
        for (field in requiredFields) {
            if (!regionConfig.has(field)) {
                errors.add("Missing required field: '$field'")
            }
        }

        if (errors.isNotEmpty()) {
            return errors // Early return if required fields missing
        }

        // Validate name
        val name = regionConfig.optString("name", "")
        if (name.isBlank()) {
            errors.add("Field 'name' cannot be empty")
        }

        // Validate enabled flag
        if (regionConfig.get("enabled") !is Boolean) {
            errors.add("Field 'enabled' must be a boolean")
        }

        // Validate tile_dir
        val tileDir = regionConfig.getString("tile_dir")
        if (tileDir.isBlank()) {
            errors.add("Field 'tile_dir' cannot be empty")
        } else if (validateTiles) {
            val tileDirFile = File(tileDir)
            if (!tileDirFile.exists()) {
                errors.add("Tile directory does not exist: ${tileDirFile.absolutePath}")
            } else if (!tileDirFile.isDirectory) {
                errors.add("Tile directory is not a directory: ${tileDirFile.absolutePath}")
            } else {
                // Check for actual tile files
                val hasTiles = tileDirFile.walkTopDown()
                    .filter { it.extension == "gph" }
                    .any()
                if (!hasTiles) {
                    errors.add("No tile files (.gph) found in: ${tileDirFile.absolutePath}")
                }
            }
        }

        // Validate bounds
        if (regionConfig.has("bounds")) {
            val boundsErrors = validateBounds(regionConfig.getJSONObject("bounds"))
            errors.addAll(boundsErrors)
        }

        // Validate optional fields
        if (regionConfig.has("osm_source")) {
            val osmSource = regionConfig.getString("osm_source")
            if (osmSource.isNotBlank() && !osmSource.startsWith("http")) {
                errors.add("Field 'osm_source' should be a valid HTTP(S) URL")
            }
        }

        // Validate supported_costings if present
        if (regionConfig.has("supported_costings")) {
            val costings = regionConfig.getJSONArray("supported_costings")
            val validCostings = setOf("auto", "bicycle", "pedestrian", "motorcycle", "bus", "truck", "taxi")
            for (i in 0 until costings.length()) {
                val costing = costings.getString(i)
                if (costing !in validCostings) {
                    errors.add("Invalid costing type: '$costing'. Valid: ${validCostings.joinToString()}")
                }
            }
        }

        return errors
    }

    /**
     * Validate bounds object
     */
    private fun validateBounds(bounds: JSONObject): List<String> {
        val errors = mutableListOf<String>()

        val requiredBounds = listOf("min_lat", "max_lat", "min_lon", "max_lon")
        for (field in requiredBounds) {
            if (!bounds.has(field)) {
                errors.add("Bounds missing required field: '$field'")
            }
        }

        if (errors.isNotEmpty()) {
            return errors
        }

        try {
            val minLat = bounds.getDouble("min_lat")
            val maxLat = bounds.getDouble("max_lat")
            val minLon = bounds.getDouble("min_lon")
            val maxLon = bounds.getDouble("max_lon")

            // Validate latitude range
            if (minLat < -90 || minLat > 90) {
                errors.add("min_lat out of valid range [-90, 90]: $minLat")
            }
            if (maxLat < -90 || maxLat > 90) {
                errors.add("max_lat out of valid range [-90, 90]: $maxLat")
            }

            // Validate longitude range
            if (minLon < -180 || minLon > 180) {
                errors.add("min_lon out of valid range [-180, 180]: $minLon")
            }
            if (maxLon < -180 || maxLon > 180) {
                errors.add("max_lon out of valid range [-180, 180]: $maxLon")
            }

            // Validate min < max
            if (minLat >= maxLat) {
                errors.add("min_lat ($minLat) must be less than max_lat ($maxLat)")
            }
            if (minLon >= maxLon) {
                errors.add("min_lon ($minLon) must be less than max_lon ($maxLon)")
            }

        } catch (e: Exception) {
            errors.add("Bounds values must be numbers: ${e.message}")
        }

        return errors
    }

    /**
     * Validate metadata section
     */
    private fun validateMetadata(metadata: JSONObject): List<String> {
        val warnings = mutableListOf<String>()

        if (!metadata.has("version")) {
            warnings.add("Metadata missing 'version' field")
        }

        if (!metadata.has("last_updated")) {
            warnings.add("Metadata missing 'last_updated' field")
        }

        return warnings
    }

    /**
     * Validate that a location is within region bounds
     *
     * @param lat Latitude
     * @param lon Longitude
     * @param regionKey Region key (e.g., "singapore")
     * @param regionsFile Path to regions.json
     * @return True if location is within bounds
     */
    fun isLocationInRegion(
        lat: Double,
        lon: Double,
        regionKey: String,
        regionsFile: String = "config/regions/regions.json"
    ): Boolean {
        val file = File(regionsFile)
        if (!file.exists()) {
            throw IllegalArgumentException("Config file not found: ${file.absolutePath}")
        }

        val config = JSONObject(file.readText())
        val regions = config.getJSONObject("regions")

        if (!regions.has(regionKey)) {
            throw IllegalArgumentException("Region not found: $regionKey")
        }

        val regionConfig = regions.getJSONObject(regionKey)
        val bounds = regionConfig.getJSONObject("bounds")

        val minLat = bounds.getDouble("min_lat")
        val maxLat = bounds.getDouble("max_lat")
        val minLon = bounds.getDouble("min_lon")
        val maxLon = bounds.getDouble("max_lon")

        return lat in minLat..maxLat && lon in minLon..maxLon
    }

    /**
     * Find which region(s) contain a given location
     *
     * @param lat Latitude
     * @param lon Longitude
     * @param regionsFile Path to regions.json
     * @return List of region keys that contain this location
     */
    fun findRegionsForLocation(
        lat: Double,
        lon: Double,
        regionsFile: String = "config/regions/regions.json"
    ): List<String> {
        val file = File(regionsFile)
        if (!file.exists()) {
            return emptyList()
        }

        val config = JSONObject(file.readText())
        val regions = config.getJSONObject("regions")
        val matchingRegions = mutableListOf<String>()

        for (regionKey in regions.keys()) {
            if (isLocationInRegion(lat, lon, regionKey, regionsFile)) {
                matchingRegions.add(regionKey)
            }
        }

        return matchingRegions
    }

    /**
     * Validate a configuration string (not file)
     *
     * @param configJson Configuration JSON string
     * @return Validation result
     */
    fun validateConfigString(configJson: String): ValidationResult {
        val errors = mutableListOf<String>()

        try {
            val config = JSONObject(configJson)

            // Validate essential Valhalla config sections
            val requiredSections = listOf("mjolnir", "loki", "service_limits")
            for (section in requiredSections) {
                if (!config.has(section)) {
                    errors.add("Missing required section: '$section'")
                }
            }

            // Validate mjolnir section
            if (config.has("mjolnir")) {
                val mjolnir = config.getJSONObject("mjolnir")
                if (!mjolnir.has("tile_dir")) {
                    errors.add("mjolnir section missing 'tile_dir'")
                } else {
                    val tileDir = mjolnir.getString("tile_dir")
                    if (tileDir.isBlank()) {
                        errors.add("mjolnir.tile_dir cannot be empty")
                    }
                }
            }

        } catch (e: Exception) {
            errors.add("Failed to parse configuration JSON: ${e.message}")
        }

        return ValidationResult(
            isValid = errors.isEmpty(),
            errors = errors
        )
    }
}
