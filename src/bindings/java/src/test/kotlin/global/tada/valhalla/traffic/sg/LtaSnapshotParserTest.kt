package global.tada.valhalla.traffic.sg

import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import java.io.File
import java.nio.file.Path
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class LtaSnapshotParserTest {

    private fun buildSnapshotJson(type: String = "speed_bands", vararg pages: List<String>): String {
        val pagesJson = pages.joinToString(",") { entries ->
            val valuesJson = entries.joinToString(",")
            """{"value": [$valuesJson]}"""
        }
        return """{"type":"$type","timestamp":"2025-01-15T10:00:00Z","epochMs":1736935200000,"pageCount":${pages.size},"pages":[$pagesJson]}"""
    }

    private fun speedBandJson(
        linkId: String,
        speedBand: Int = 5,
        minSpeed: Int = 40,
        maxSpeed: Int = 50
    ): String {
        return """{"LinkID":"$linkId","RoadName":"Test Road","RoadCategory":"3","SpeedBand":$speedBand,"MinimumSpeed":$minSpeed,"MaximumSpeed":$maxSpeed,"StartLat":1.3,"StartLon":103.8,"EndLat":1.31,"EndLon":103.81}"""
    }

    private fun incidentJson(
        type: String = "Accident",
        lat: Double = 1.32,
        lon: Double = 103.85,
        message: String = "Test incident"
    ): String {
        return """{"Type":"$type","Latitude":$lat,"Longitude":$lon,"Message":"$message"}"""
    }

    private fun estTravelTimeJson(
        name: String = "PIE",
        direction: Int = 1,
        estTime: Int = 15
    ): String {
        return """{"Name":"$name","Direction":$direction,"FarEndPoint":"Tuas","StartPoint":"Changi","EndPoint":"Jurong","EstTime":$estTime}"""
    }

    @Test
    fun `parses valid snapshot`() {
        val json = buildSnapshotJson(
            "speed_bands",
            listOf(speedBandJson("L1"), speedBandJson("L2", minSpeed = 20, maxSpeed = 30))
        )

        val entries = LtaSnapshotParser.parseSpeedBandSnapshot(json)

        assertEquals(2, entries.size)
        assertEquals("L1", entries[0].linkId)
        assertEquals(40, entries[0].minimumSpeed)
        assertEquals(50, entries[0].maximumSpeed)
        assertEquals("L2", entries[1].linkId)
        assertEquals(20, entries[1].minimumSpeed)
        assertEquals(30, entries[1].maximumSpeed)
    }

    @Test
    fun `handles multiple pages`() {
        val json = buildSnapshotJson(
            "speed_bands",
            listOf(speedBandJson("L1"), speedBandJson("L2")),
            listOf(speedBandJson("L3"), speedBandJson("L4"))
        )

        val entries = LtaSnapshotParser.parseSpeedBandSnapshot(json)

        assertEquals(4, entries.size)
        assertEquals("L1", entries[0].linkId)
        assertEquals("L2", entries[1].linkId)
        assertEquals("L3", entries[2].linkId)
        assertEquals("L4", entries[3].linkId)
    }

    @Test
    fun `returns empty for invalid JSON`() {
        val entries = LtaSnapshotParser.parseSpeedBandSnapshot("not valid json {{{")

        assertTrue(entries.isEmpty())
    }

    @Test
    fun `skips unparseable entries`() {
        val validEntry = speedBandJson("L1")
        val brokenEntry = """{"LinkID":"L_BROKEN"}""" // missing required fields like SpeedBand
        val json = buildSnapshotJson("speed_bands", listOf(validEntry, brokenEntry))

        val entries = LtaSnapshotParser.parseSpeedBandSnapshot(json)

        assertEquals(1, entries.size)
        assertEquals("L1", entries[0].linkId)
    }

    @Test
    fun `loadSpeedBandsFromFile returns null for missing file`(@TempDir tempDir: Path) {
        val result = LtaSnapshotParser.loadSpeedBandsFromFile(
            File(tempDir.toFile(), "nonexistent.json").absolutePath
        )

        assertNull(result)
    }

    // --- Incident snapshot parsing ---

    @Test
    fun `parses valid incident snapshot`() {
        val json = buildSnapshotJson(
            "incidents",
            listOf(incidentJson("Accident", 1.32, 103.85, "Accident on PIE"), incidentJson("Roadwork", 1.33, 103.86, "Roadwork on CTE"))
        )

        val incidents = LtaSnapshotParser.parseIncidentSnapshot(json)

        assertEquals(2, incidents.size)
        assertEquals("Accident", incidents[0].type)
        assertEquals(1.32, incidents[0].latitude)
        assertEquals(103.85, incidents[0].longitude)
        assertEquals("Accident on PIE", incidents[0].message)
        assertEquals("Roadwork", incidents[1].type)
    }

    @Test
    fun `incident parser handles multiple pages`() {
        val json = buildSnapshotJson(
            "incidents",
            listOf(incidentJson("Accident")),
            listOf(incidentJson("Roadwork"), incidentJson("Vehicle Breakdown"))
        )

        val incidents = LtaSnapshotParser.parseIncidentSnapshot(json)

        assertEquals(3, incidents.size)
    }

    @Test
    fun `incident parser returns empty for invalid JSON`() {
        val incidents = LtaSnapshotParser.parseIncidentSnapshot("not valid json {{{")

        assertTrue(incidents.isEmpty())
    }

    @Test
    fun `incident parser skips unparseable entries`() {
        val valid = incidentJson("Accident", 1.32, 103.85, "Valid")
        val broken = """{"Type":"Broken"}""" // missing Latitude/Longitude
        val json = buildSnapshotJson("incidents", listOf(valid, broken))

        val incidents = LtaSnapshotParser.parseIncidentSnapshot(json)

        assertEquals(1, incidents.size)
        assertEquals("Accident", incidents[0].type)
    }

    @Test
    fun `loadIncidentsFromFile returns null for missing file`(@TempDir tempDir: Path) {
        val result = LtaSnapshotParser.loadIncidentsFromFile(
            File(tempDir.toFile(), "nonexistent.json").absolutePath
        )

        assertNull(result)
    }

    // --- Estimated travel time snapshot parsing ---

    @Test
    fun `parses valid est travel time snapshot`() {
        val json = buildSnapshotJson(
            "est_travel_times",
            listOf(estTravelTimeJson("PIE", 1, 15), estTravelTimeJson("CTE", 2, 22))
        )

        val entries = LtaSnapshotParser.parseEstTravelTimeSnapshot(json)

        assertEquals(2, entries.size)
        assertEquals("PIE", entries[0].name)
        assertEquals(1, entries[0].direction)
        assertEquals(15, entries[0].estTime)
        assertEquals("CTE", entries[1].name)
        assertEquals(2, entries[1].direction)
        assertEquals(22, entries[1].estTime)
    }

    @Test
    fun `est travel time parser handles multiple pages`() {
        val json = buildSnapshotJson(
            "est_travel_times",
            listOf(estTravelTimeJson("PIE")),
            listOf(estTravelTimeJson("CTE"), estTravelTimeJson("AYE"))
        )

        val entries = LtaSnapshotParser.parseEstTravelTimeSnapshot(json)

        assertEquals(3, entries.size)
    }

    @Test
    fun `est travel time parser returns empty for invalid JSON`() {
        val entries = LtaSnapshotParser.parseEstTravelTimeSnapshot("not valid json {{{")

        assertTrue(entries.isEmpty())
    }

    @Test
    fun `loadEstTravelTimesFromFile returns null for missing file`(@TempDir tempDir: Path) {
        val result = LtaSnapshotParser.loadEstTravelTimesFromFile(
            File(tempDir.toFile(), "nonexistent.json").absolutePath
        )

        assertNull(result)
    }
}
