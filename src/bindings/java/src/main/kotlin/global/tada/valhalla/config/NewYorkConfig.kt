package global.tada.valhalla.config

import kotlin.math.cos

/**
 * New York tri-state constants and costing profiles for Valhalla Actor.
 *
 * The `new_york`, `new_jersey`, and `connecticut` regions in regions.json all
 * share the `nyc_tri_state` tile group, so routing crosses state lines (e.g.
 * NYC <-> Newark NJ <-> Stamford CT). The [bounds] here cover the union of all
 * three states for app-layer location checks.
 *
 * Provides:
 * - Geographic bounds for the tri-state area
 * - Locale metadata (timezone, locale, currency)
 * - Costing profile JSON snippets for route requests (auto, motorcycle, taxi)
 *
 * For Actor config building use RegionConfigFactory.buildConfig("new_york", ...)
 * (or the "nyc" / "ny" / "nj" / "ct" aliases).
 *
 * Mirrors the structure of [SingaporeConfig].
 */
object NewYorkConfig {

    val regionName = "New York"
    val timezone = "America/New_York"
    val locale = "en-US"
    val currency = "USD"

    /**
     * Tri-state geographic bounds (union of NY, NJ, CT).
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

    /**
     * Union bounds covering New York, New Jersey, and Connecticut.
     * min over the three states' min, max over their max (see regions.json).
     *
     * NOTE — DELIBERATELY WIDER than the per-state `new_york` bounds in
     * regions.json (NY state only). Use [bounds] for "is this point anywhere in
     * the tri-state service area?" checks; use
     * RegionConfigFactory.getRegionInfo("new_york"/"new_jersey"/"connecticut")
     * bounds for per-state checks. Don't mix the two.
     */
    val bounds = BoundsData(
        minLat = 38.79,
        maxLat = 45.02,
        minLon = -79.77,
        maxLon = -71.78
    )

    /**
     * Auto costing — US highways and tolls enabled, higher top speed than SG.
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
              "top_speed": 110,
              "closure_factor": 9.0,
              "shortest": false
            }
          }
        }
        """.trimIndent()

    /**
     * Motorcycle costing.
     */
    fun motorcycleProfile() = """
        {
          "costing": "motorcycle",
          "costing_options": {
            "motorcycle": {
              "maneuver_penalty": 5,
              "use_highways": 1.0,
              "use_tolls": 1.0,
              "top_speed": 110
            }
          }
        }
        """.trimIndent()

    /**
     * Taxi costing — optimized for ride-hailing with frequent stops.
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
              "top_speed": 110,
              "closure_factor": 9.0,
              "shortest": false
            }
          }
        }
        """.trimIndent()
}
