package global.tada.valhalla.traffic.models

import org.json.JSONObject

// LTA traffic incident — disappears from the feed once resolved (no status flag)
data class TrafficIncident(
    val type: String,
    val latitude: Double,
    val longitude: Double,
    val message: String
) {
    enum class IncidentType(val ltaName: String) {
        ACCIDENT("Accident"),
        ROADWORK("Roadwork"),
        VEHICLE_BREAKDOWN("Vehicle Breakdown"),
        WEATHER("Weather"),
        OBSTACLE("Obstacle"),
        ROAD_BLOCK("Road Block"),
        HEAVY_TRAFFIC("Heavy Traffic"),
        MISCELLANEOUS("Miscellaneous"),
        DIVERSION("Diversion"),
        UNATTENDED_VEHICLE("Unattended Vehicle"),
        FIRE("Fire"),
        PLANT_FAILURE("Plant Failure"),
        REVERSE_FLOW("Reverse Flow");

        companion object {
            fun fromLtaName(name: String): IncidentType {
                return entries.find { it.ltaName.equals(name, ignoreCase = true) }
                    ?: MISCELLANEOUS
            }
        }
    }

    fun incidentType(): IncidentType = IncidentType.fromLtaName(type)

    companion object {
        fun fromJson(json: JSONObject): TrafficIncident {
            return TrafficIncident(
                type = json.optString("Type", "Miscellaneous"),
                latitude = json.getDouble("Latitude"),
                longitude = json.getDouble("Longitude"),
                message = json.optString("Message", "")
            )
        }
    }
}