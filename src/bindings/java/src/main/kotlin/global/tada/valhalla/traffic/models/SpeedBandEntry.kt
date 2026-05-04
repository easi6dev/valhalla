package global.tada.valhalla.traffic.models

import org.json.JSONObject

// LTA Speed Band entry — band 1 (gridlock) to 8 (70+ km/h)
data class SpeedBandEntry(
    val linkId: String,
    val roadName: String,
    val roadCategory: String,
    val speedBand: Int,
    val minimumSpeed: Int,
    val maximumSpeed: Int,
    val startLat: Double,
    val startLon: Double,
    val endLat: Double,
    val endLon: Double
) {
    fun averageSpeedKph(): Int = (minimumSpeed + maximumSpeed) / 2

    // Map to Valhalla's 0-63 congestion scale
    fun toCongestionLevel(): Int = when (speedBand) {
        1 -> 63  // gridlock
        2 -> 54  // heavy
        3 -> 45  // slow
        4 -> 36  // moderate
        5 -> 27  // flowing
        6 -> 18  // free flow
        7 -> 9   // fast
        8 -> 1   // very fast / minimal congestion
        else -> 0 // unknown
    }

    companion object {
        fun fromJson(json: JSONObject): SpeedBandEntry {
            return SpeedBandEntry(
                linkId = json.get("LinkID").toString(),
                roadName = json.optString("RoadName", ""),
                roadCategory = json.get("RoadCategory").toString(),
                speedBand = json.getInt("SpeedBand"),
                minimumSpeed = json.optInt("MinimumSpeed", 0),
                maximumSpeed = json.optInt("MaximumSpeed", 0),
                startLat = json.getDouble("StartLat"),
                startLon = json.getDouble("StartLon"),
                endLat = json.getDouble("EndLat"),
                endLon = json.getDouble("EndLon")
            )
        }
    }
}
