package global.tada.valhalla.traffic

import org.json.JSONObject
import org.slf4j.LoggerFactory
import java.io.File
import java.time.Instant

/**
 * Snapshot of the LTA fetch cron's last run, read from `traffic-status.json`.
 *
 * Production writer is now the Python cron in `tada-valhalla-data-builder`'s
 * `core/status.py`. The Kotlin [TrafficStatusFile.write] below is retained
 * only for the legacy in-process [global.tada.valhalla.traffic.sg.LtaFetchJob]
 * that the Python cron has replaced; once that legacy job is removed,
 * `write()` should be deleted with it.
 *
 * The routing-service path is read-only: it consumes
 * [TrafficStatusFile.isTrafficFresh] to gate live-traffic vs. free-flow.
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

    /**
     * Legacy in-process writer used by [global.tada.valhalla.traffic.sg.LtaFetchJob],
     * the Kotlin cron that the Python `tada-valhalla-data-builder` cron has
     * replaced. Slated for removal alongside the legacy job; do not call from
     * new code.
     */
    @Deprecated("Production writer is the Python cron's core/status.py; retained only for the legacy LtaFetchJob being phased out.")
    @JvmStatic
    fun write(path: String, data: TrafficStatusData) {
        try {
            val json = JSONObject().apply {
                put("epochMs", data.epochMs)
                put("timestamp", Instant.ofEpochMilli(data.epochMs).toString())
                put("speedBandCount", data.speedBandCount)
                put("incidentCount", data.incidentCount)
                put("estTravelTimeCount", data.estTravelTimeCount)
                put("mappedEdges", data.mappedEdges)
                put("tilesWithTraffic", data.tilesWithTraffic)
                put("blockedRoads", data.blockedRoads)
                put("speedBandsLastSuccessMs", data.speedBandsLastSuccessMs)
                put("incidentsLastSuccessMs", data.incidentsLastSuccessMs)
                put("estTravelTimesLastSuccessMs", data.estTravelTimesLastSuccessMs)
            }

            val file = File(path)
            file.parentFile?.mkdirs()

            val temp = File(file.parent, ".traffic-status.tmp.json")
            temp.writeText(json.toString(2))
            if (!temp.renameTo(file)) {
                temp.copyTo(file, overwrite = true)
                temp.delete()
            }

            logger.debug("Traffic status written: epochMs={}, mapped={}", data.epochMs, data.mappedEdges)
        } catch (e: Exception) {
            logger.warn("Failed to write traffic status file {}: {}", path, e.message)
        }
    }

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
