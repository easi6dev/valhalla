package global.tada.valhalla.traffic.sg

import global.tada.valhalla.traffic.models.TrafficIncident
import org.json.JSONArray
import org.json.JSONObject
import org.slf4j.LoggerFactory
import java.io.File

// Persists active incidents as incidents.json — atomic write via temp+rename
object IncidentStore {

    private val logger = LoggerFactory.getLogger(IncidentStore::class.java)

    @JvmStatic
    fun write(path: String, incidents: List<TrafficIncident>, epochMs: Long) {
        try {
            val arr = JSONArray()
            for (inc in incidents) {
                arr.put(JSONObject().apply {
                    put("type", inc.type)
                    put("latitude", inc.latitude)
                    put("longitude", inc.longitude)
                    put("message", inc.message)
                })
            }

            val json = JSONObject().apply {
                put("epochMs", epochMs)
                put("count", incidents.size)
                put("incidents", arr)
            }

            val file = File(path)
            file.parentFile?.mkdirs()

            val temp = File(file.parent, ".incidents.tmp.json")
            temp.writeText(json.toString(2))
            if (!temp.renameTo(file)) {
                temp.copyTo(file, overwrite = true)
                temp.delete()
            }

            logger.debug("Incidents written: count={}", incidents.size)
        } catch (e: Exception) {
            logger.warn("Failed to write incidents file {}: {}", path, e.message)
        }
    }

    @JvmStatic
    fun read(path: String): List<TrafficIncident> {
        return try {
            val file = File(path)
            if (!file.exists()) return emptyList()

            val json = JSONObject(file.readText())
            val arr = json.optJSONArray("incidents") ?: return emptyList()

            val result = mutableListOf<TrafficIncident>()
            for (i in 0 until arr.length()) {
                val obj = arr.optJSONObject(i) ?: continue
                // Keys are lowercase (as written by write() above), not the uppercase LTA API format
                result.add(TrafficIncident(
                    type = obj.optString("type", "Miscellaneous"),
                    latitude = obj.optDouble("latitude", 0.0),
                    longitude = obj.optDouble("longitude", 0.0),
                    message = obj.optString("message", "")
                ))
            }
            result
        } catch (e: Exception) {
            logger.warn("Failed to read incidents file {}: {}", path, e.message)
            emptyList()
        }
    }
}
