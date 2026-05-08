package global.tada.valhalla.traffic

import org.json.JSONObject
import org.slf4j.LoggerFactory
import java.io.File

/**
 * Snapshot of the LTA fetch cron's last run, read from `traffic-status.json`.
 *
 * Written by the Python cron in `tada-valhalla-data-builder`'s
 * `core/status.py`. This Kotlin object is read-only — consumers call
 * [TrafficStatusFile.isTrafficFresh] to gate live-traffic vs. static-layer
 * routing.
 *
 * Schema is locked by the Python writer. Field names use camelCase, matching
 * the JSON keys exactly. Do not rename without coordinating across both repos.
 */
data class TrafficStatusData(
    val epochMs: Long,
    val speedBandCount: Int,
    val incidentCount: Int,
    val estTravelTimeCount: Int,
    val mappedEdges: Int,
    val tilesWithTraffic: Int,
    val blockedRoads: Int,
    val speedBandsLastSuccessMs: Long,
    val incidentsLastSuccessMs: Long,
    val estTravelTimesLastSuccessMs: Long
)

object TrafficStatusFile {

    private val logger = LoggerFactory.getLogger(TrafficStatusFile::class.java)

    @JvmStatic
    fun read(path: String): TrafficStatusData? {
        return try {
            val file = File(path)
            if (!file.exists()) return null

            val json = JSONObject(file.readText())
            TrafficStatusData(
                epochMs = json.getLong("epochMs"),
                speedBandCount = json.optInt("speedBandCount", 0),
                incidentCount = json.optInt("incidentCount", 0),
                estTravelTimeCount = json.optInt("estTravelTimeCount", 0),
                mappedEdges = json.optInt("mappedEdges", 0),
                tilesWithTraffic = json.optInt("tilesWithTraffic", 0),
                blockedRoads = json.optInt("blockedRoads", 0),
                speedBandsLastSuccessMs = json.optLong("speedBandsLastSuccessMs", 0),
                incidentsLastSuccessMs = json.optLong("incidentsLastSuccessMs", 0),
                estTravelTimesLastSuccessMs = json.optLong("estTravelTimesLastSuccessMs", 0)
            )
        } catch (e: Exception) {
            logger.warn("Failed to read traffic status file {}: {}", path, e.message)
            null
        }
    }

    // Compares epochMs inside the file (not mtime) to avoid cross-pod clock skew
    @JvmStatic
    fun isTrafficFresh(path: String, staleThresholdMinutes: Int): Boolean {
        val status = read(path) ?: return false
        val ageMinutes = (System.currentTimeMillis() - status.epochMs) / 60_000
        return ageMinutes < staleThresholdMinutes
    }
}
