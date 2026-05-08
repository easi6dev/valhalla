package global.tada.valhalla.traffic

import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import java.nio.file.Path
import kotlin.io.path.writeText
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Unit tests for [TrafficStatusFile].
 *
 * Fixtures are written inline matching the schema produced by the Python
 * cron's `core/status.py` (in `tada-valhalla-data-builder`). The test JSON
 * shape is the contract; if either side drifts the round-trip breaks here.
 */
class TrafficStatusFileTest {

    /**
     * Build a status JSON matching what the Python writer emits. Defaults
     * mirror `core/status.py::write_status` defaults so test cases only
     * have to override what they care about.
     */
    private fun statusJson(
        epochMs: Long,
        speedBandCount: Int = 0,
        incidentCount: Int = 0,
        estTravelTimeCount: Int = 0,
        mappedEdges: Int = 0,
        tilesWithTraffic: Int = 0,
        blockedRoads: Int = 0,
        speedBandsLastSuccessMs: Long = 0,
        incidentsLastSuccessMs: Long = 0,
        estTravelTimesLastSuccessMs: Long = 0,
    ): String = """
        {
          "epochMs": $epochMs,
          "timestamp": "2026-05-08T00:00:00+00:00",
          "speedBandCount": $speedBandCount,
          "incidentCount": $incidentCount,
          "estTravelTimeCount": $estTravelTimeCount,
          "mappedEdges": $mappedEdges,
          "tilesWithTraffic": $tilesWithTraffic,
          "blockedRoads": $blockedRoads,
          "speedBandsLastSuccessMs": $speedBandsLastSuccessMs,
          "incidentsLastSuccessMs": $incidentsLastSuccessMs,
          "estTravelTimesLastSuccessMs": $estTravelTimesLastSuccessMs
        }
    """.trimIndent()

    @Test
    fun `read parses every field from a well-formed status JSON`() {
        val path = createStatusFile(
            statusJson(
                epochMs = 1_700_000_000_000,
                speedBandCount = 143735,
                incidentCount = 28,
                estTravelTimeCount = 192,
                mappedEdges = 72099,
                tilesWithTraffic = 8,
                blockedRoads = 0,
                speedBandsLastSuccessMs = 1_700_000_000_000,
                incidentsLastSuccessMs = 1_700_000_000_000,
                estTravelTimesLastSuccessMs = 1_700_000_000_000,
            )
        )

        val status = TrafficStatusFile.read(path.toString())

        assertEquals(1_700_000_000_000, status?.epochMs)
        assertEquals(143735, status?.speedBandCount)
        assertEquals(28, status?.incidentCount)
        assertEquals(192, status?.estTravelTimeCount)
        assertEquals(72099, status?.mappedEdges)
        assertEquals(8, status?.tilesWithTraffic)
        assertEquals(0, status?.blockedRoads)
        assertEquals(1_700_000_000_000, status?.speedBandsLastSuccessMs)
        assertEquals(1_700_000_000_000, status?.incidentsLastSuccessMs)
        assertEquals(1_700_000_000_000, status?.estTravelTimesLastSuccessMs)
    }

    @Test
    fun `read returns null when file is absent`() {
        assertNull(TrafficStatusFile.read("/does/not/exist.json"))
    }

    @Test
    fun `read returns null on malformed JSON`() {
        val path = createStatusFile("{ this isn't json")
        assertNull(TrafficStatusFile.read(path.toString()))
    }

    @Test
    fun `read returns null when the required epochMs key is missing`() {
        // Python's writer always emits epochMs; the reader uses getLong (not
        // optLong), so its absence raises and the catch block returns null.
        val path = createStatusFile("""{"speedBandCount": 100}""")
        assertNull(TrafficStatusFile.read(path.toString()))
    }

    @Test
    fun `read tolerates missing optional count fields by defaulting to zero`() {
        // The Python writer always emits all fields, but defensive coding on
        // the reader: if a future cron version drops a field we shouldn't crash.
        val minimal = """{"epochMs": 1700000000000}"""
        val path = createStatusFile(minimal)

        val status = TrafficStatusFile.read(path.toString())

        assertEquals(1_700_000_000_000, status?.epochMs)
        assertEquals(0, status?.speedBandCount)
        assertEquals(0, status?.blockedRoads)
        assertEquals(0L, status?.speedBandsLastSuccessMs)
    }

    @Test
    fun `isTrafficFresh returns true for a recent epochMs`() {
        val path = createStatusFile(
            statusJson(epochMs = System.currentTimeMillis() - 60_000) // 1 min old
        )
        assertTrue(TrafficStatusFile.isTrafficFresh(path.toString(), staleThresholdMinutes = 15))
    }

    @Test
    fun `isTrafficFresh returns false when status is older than threshold`() {
        val path = createStatusFile(
            statusJson(epochMs = System.currentTimeMillis() - 60 * 60_000) // 60 min old
        )
        assertFalse(TrafficStatusFile.isTrafficFresh(path.toString(), staleThresholdMinutes = 15))
    }

    @Test
    fun `isTrafficFresh returns false when status file is missing`() {
        // Don't write anything; ask about a path that doesn't exist.
        assertFalse(TrafficStatusFile.isTrafficFresh("/does/not/exist.json", staleThresholdMinutes = 15))
    }

    @Test
    fun `isTrafficFresh compares epochMs from file content not file mtime`() {
        // Comment in TrafficStatusFile says: "Compares epochMs inside the
        // file (not mtime) to avoid cross-pod clock skew." Pin that
        // behaviour: write a file whose epochMs is stale even though the
        // file was just created.
        val path = createStatusFile(
            statusJson(epochMs = System.currentTimeMillis() - 30 * 60_000) // 30 min old
        )
        // File mtime is "now". If the implementation accidentally checked mtime
        // it would return true. epochMs check should return false.
        assertFalse(TrafficStatusFile.isTrafficFresh(path.toString(), staleThresholdMinutes = 15))
    }

    /** Write [json] to a tmp file and return its path. */
    private fun createStatusFile(json: String): Path {
        val file = tempDir.resolve("traffic-status.json")
        file.writeText(json)
        return file
    }

    @TempDir
    lateinit var tempDir: Path
}
