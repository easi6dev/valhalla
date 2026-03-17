package global.tada.valhalla.config

import kotlin.math.cos

/**
 * Singapore-specific constants and costing profiles for Valhalla Actor.
 *
 * Provides:
 * - Geographic bounds for Singapore
 * - Locale metadata (timezone, locale, currency)
 * - Costing profile JSON snippets for route requests (auto, motorcycle, taxi)
 *
 * For Actor config building use RegionConfigFactory.buildConfig("singapore", ...).
 */
object SingaporeConfig {

    val regionName = "Singapore"
    val timezone = "Asia/Singapore"
    val locale = "en-SG"
    val currency = "SGD"

    /**
     * Singapore geographic bounds
     */
    data class BoundsData(
        val minLat: Double,
        val maxLat: Double,
        val minLon: Double,
        val maxLon: Double
    ) {
        fun isValidLocation(lat: Double, lon: Double): Boolean {
            return lat in minLat..maxLat && lon in minLon..maxLon
        }

        fun center(): Pair<Double, Double> {
            return Pair((minLat + maxLat) / 2, (minLon + maxLon) / 2)
        }

        fun approximateArea(): Double {
            // Rough calculation in km²
            val latDiff = maxLat - minLat
            val lonDiff = maxLon - minLon
            return latDiff * lonDiff * 111.0 * 111.0 * cos(Math.toRadians((minLat + maxLat) / 2))
        }
    }

    val bounds = BoundsData(
        minLat = 1.15,
        maxLat = 1.48,
        minLon = 103.6,
        maxLon = 104.0
    )

    /**
     * Auto costing with ERP and CBD awareness
     */
    fun autoProfile() = """
        {
          "costing": "auto",
          "costing_options": {
            "auto": {
              "maneuver_penalty": 5,
              "gate_cost": 30,
              "toll_booth_cost": 15,
              "use_highways": 1.0,
              "use_tolls": 1.0,
              "top_speed": 90,
              "closure_factor": 9.0,
              "shortest": false
            }
          }
        }
        """.trimIndent()

    /**
     * Motorcycle costing with lane restrictions
     */
    fun motorcycleProfile() = """
        {
          "costing": "motorcycle",
          "costing_options": {
            "motorcycle": {
              "maneuver_penalty": 5,
              "use_highways": 1.0,
              "use_tolls": 1.0,
              "top_speed": 90
            }
          }
        }
        """.trimIndent()

    /**
     * Taxi costing with taxi-specific optimizations
     * Optimized for: Ride-hailing, taxi services, frequent stops
     */
    fun taxiProfile() = """
        {
          "costing": "taxi",
          "costing_options": {
            "taxi": {
              "maneuver_penalty": 5,
              "gate_cost": 30,
              "toll_booth_cost": 15,
              "use_highways": 1.0,
              "use_tolls": 1.0,
              "top_speed": 90,
              "closure_factor": 9.0,
              "shortest": false
            }
          }
        }
        """.trimIndent()
}
