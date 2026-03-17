package global.tada.valhalla.helpers

/**
 * Helper class for building Valhalla route requests in tests.
 * This is a test utility and not part of the production API.
 *
 * Manually constructs JSON to avoid external dependencies in tests.
 */
data class RouteRequest(
    val locations: List<Location>,
    val costing: String = "auto",
    val units: String = "kilometers",
    val directionsOptions: DirectionsOptions? = null
) {
    data class Location(
        val lat: Double,
        val lon: Double,
        val type: String? = null,
        val heading: Int? = null
    ) {
        fun toJson(): String = buildString {
            append("{")
            append("\"lat\":$lat,")
            append("\"lon\":$lon")
            type?.let { append(",\"type\":\"$it\"") }
            heading?.let { append(",\"heading\":$it") }
            append("}")
        }
    }

    data class DirectionsOptions(
        val units: String? = null,
        val language: String? = null
    ) {
        fun toJson(): String = buildString {
            append("{")
            val parts = mutableListOf<String>()
            units?.let { parts.add("\"units\":\"$it\"") }
            language?.let { parts.add("\"language\":\"$it\"") }
            append(parts.joinToString(","))
            append("}")
        }
    }

    /**
     * Converts this request to JSON string for Valhalla Actor.
     */
    override fun toString(): String = buildString {
        append("{")
        append("\"locations\":[")
        append(locations.joinToString(",") { it.toJson() })
        append("],")
        append("\"costing\":\"$costing\",")
        append("\"units\":\"$units\"")
        directionsOptions?.let {
            append(",\"directionsOptions\":")
            append(it.toJson())
        }
        append("}")
    }

    /**
     * Converts this request to JSON string.
     */
    fun toJson(): String = toString()
}
