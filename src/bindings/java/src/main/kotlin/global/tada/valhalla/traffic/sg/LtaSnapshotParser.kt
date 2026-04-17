package global.tada.valhalla.traffic.sg

import global.tada.valhalla.traffic.models.EstTravelTimeEntry
import global.tada.valhalla.traffic.models.SpeedBandEntry
import global.tada.valhalla.traffic.models.TrafficIncident
import org.json.JSONObject
import org.slf4j.LoggerFactory

// Parses snapshot files from LtaSnapshotStore back into domain objects
object LtaSnapshotParser {

    private val logger = LoggerFactory.getLogger(LtaSnapshotParser::class.java)

    @JvmStatic
    fun parseSpeedBandSnapshot(snapshotJson: String): List<SpeedBandEntry> {
        return parseSnapshot(snapshotJson, "speed band") { SpeedBandEntry.fromJson(it) }
    }

    @JvmStatic
    fun parseIncidentSnapshot(snapshotJson: String): List<TrafficIncident> {
        return parseSnapshot(snapshotJson, "incident") { TrafficIncident.fromJson(it) }
    }

    @JvmStatic
    fun parseEstTravelTimeSnapshot(snapshotJson: String): List<EstTravelTimeEntry> {
        return parseSnapshot(snapshotJson, "est travel time") { EstTravelTimeEntry.fromJson(it) }
    }

    @JvmStatic
    fun loadSpeedBandsFromFile(filePath: String): List<SpeedBandEntry>? {
        val json = LtaSnapshotStore.readSnapshot(filePath) ?: return null
        return parseSpeedBandSnapshot(json)
    }

    @JvmStatic
    fun loadIncidentsFromFile(filePath: String): List<TrafficIncident>? {
        val json = LtaSnapshotStore.readSnapshot(filePath) ?: return null
        return parseIncidentSnapshot(json)
    }

    @JvmStatic
    fun loadEstTravelTimesFromFile(filePath: String): List<EstTravelTimeEntry>? {
        val json = LtaSnapshotStore.readSnapshot(filePath) ?: return null
        return parseEstTravelTimeSnapshot(json)
    }

    private fun <T> parseSnapshot(
        snapshotJson: String,
        typeName: String,
        parser: (JSONObject) -> T
    ): List<T> {
        return try {
            val envelope = JSONObject(snapshotJson)
            val pages = envelope.optJSONArray("pages") ?: return emptyList()

            val entries = mutableListOf<T>()
            var skipped = 0

            for (i in 0 until pages.length()) {
                val page = pages.optJSONObject(i) ?: continue
                val values = page.optJSONArray("value") ?: continue

                for (j in 0 until values.length()) {
                    try {
                        val entryJson = values.getJSONObject(j)
                        entries.add(parser(entryJson))
                    } catch (e: Exception) {
                        skipped++
                        logger.debug("Skipping unparseable {} entry at page {} index {}: {}", typeName, i, j, e.message)
                    }
                }
            }

            if (skipped > 0) {
                logger.debug("Parsed {} {} entries, skipped {} unparseable", entries.size, typeName, skipped)
            }

            entries
        } catch (e: Exception) {
            logger.warn("Failed to parse {} snapshot: {}", typeName, e.message)
            emptyList()
        }
    }
}
