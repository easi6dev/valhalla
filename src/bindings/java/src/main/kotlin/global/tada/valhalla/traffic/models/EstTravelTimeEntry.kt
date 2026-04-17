package global.tada.valhalla.traffic.models

import org.json.JSONObject

// LTA expressway travel time — direction 1=towards city, 2=away; estTime in minutes
data class EstTravelTimeEntry(
    val name: String,
    val direction: Int,
    val farEndPoint: String,
    val startPoint: String,
    val endPoint: String,
    val estTime: Int
) {
    companion object {
        fun fromJson(json: JSONObject): EstTravelTimeEntry {
            return EstTravelTimeEntry(
                name = json.optString("Name", ""),
                direction = json.optInt("Direction", 0),
                farEndPoint = json.optString("FarEndPoint", ""),
                startPoint = json.optString("StartPoint", ""),
                endPoint = json.optString("EndPoint", ""),
                estTime = json.optInt("EstTime", 0)
            )
        }
    }
}