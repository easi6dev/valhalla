package global.tada.valhalla.dispatch

import global.tada.valhalla.pool.ActorPool
import org.json.JSONObject
import org.junit.jupiter.api.Assumptions.assumeTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.Timeout
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Tests for [DriverSelection].
 *
 * The request-building and matrix-parsing/ranking logic is PURE (no native
 * engine) and fully tested here. One end-to-end test against a live pool is
 * gated with [assumeTrue] and runs in CI / on the Linux builder.
 */
class DriverSelectionTest {

    private val rider = DriverSelection.Point(1.290270, 103.851959)
    private val drivers = listOf(
        DriverSelection.Point(1.300, 103.850),  // index 0
        DriverSelection.Point(1.310, 103.860),  // index 1
        DriverSelection.Point(1.320, 103.870)   // index 2
    )

    // ── Request building ─────────────────────────────────────────────────────

    @Test
    fun `buildMatrixRequest has one source and K targets`() {
        val req = DriverSelection.buildMatrixRequest(rider, drivers, "auto", null)
        val json = JSONObject(req)
        assertEquals(1, json.getJSONArray("sources").length())
        assertEquals(3, json.getJSONArray("targets").length())
        assertEquals("auto", json.getString("costing"))
        assertTrue(json.getBoolean("verbose"), "request must pin verbose for a deterministic shape")
        // Source is the rider.
        val src = json.getJSONArray("sources").getJSONObject(0)
        assertEquals(rider.lat, src.getDouble("lat"))
        assertEquals(rider.lon, src.getDouble("lon"))
        assertFalse(json.has("costing_options"))
    }

    @Test
    fun `buildMatrixRequest merges costing options when provided`() {
        val req = DriverSelection.buildMatrixRequest(
            rider, drivers, "taxi", """{"taxi":{"top_speed":110}}"""
        )
        val json = JSONObject(req)
        assertEquals(110, json.getJSONObject("costing_options").getJSONObject("taxi").getInt("top_speed"))
    }

    // ── Parsing + ranking ─────────────────────────────────────────────────────

    /** Build a 1-source→K-target matrix response with the given (time,dist) cells. */
    private fun matrixResponse(cells: List<Pair<Double?, Double?>>): String {
        val row = cells.mapIndexed { i, (t, d) ->
            buildString {
                append("{\"from_index\":0,\"to_index\":$i")
                append(",\"time\":${t ?: "null"}")
                append(",\"distance\":${d ?: "null"}}")
            }
        }.joinToString(",")
        return """{"sources_to_targets":[[$row]]}"""
    }

    @Test
    fun `ranks by time ascending best-first`() {
        val resp = matrixResponse(listOf(
            300.0 to 5000.0,   // driver 0 — slowest
            120.0 to 2000.0,   // driver 1 — fastest
            200.0 to 3000.0    // driver 2
        ))
        val ranked = DriverSelection.parseAndRank(resp, 3, DriverSelection.RankBy.TIME, false)
        assertEquals(listOf(1, 2, 0), ranked.map { it.index })
        assertEquals(120.0, ranked.first().timeSeconds)
    }

    @Test
    fun `ranks by distance when requested`() {
        val resp = matrixResponse(listOf(
            300.0 to 5000.0,
            120.0 to 9000.0,   // fastest by time but farthest by distance
            200.0 to 1000.0    // nearest by distance
        ))
        val ranked = DriverSelection.parseAndRank(resp, 3, DriverSelection.RankBy.DISTANCE, false)
        assertEquals(listOf(2, 0, 1), ranked.map { it.index })
    }

    @Test
    fun `unreachable drivers are excluded by default`() {
        val resp = matrixResponse(listOf(
            300.0 to 5000.0,
            null to null,      // driver 1 unreachable
            200.0 to 3000.0
        ))
        val ranked = DriverSelection.parseAndRank(resp, 3, DriverSelection.RankBy.TIME, false)
        assertEquals(listOf(2, 0), ranked.map { it.index })
        assertTrue(ranked.all { it.reachable })
    }

    @Test
    fun `unreachable drivers appended last when included`() {
        val resp = matrixResponse(listOf(
            300.0 to 5000.0,
            null to null,      // unreachable
            200.0 to 3000.0
        ))
        val ranked = DriverSelection.parseAndRank(resp, 3, DriverSelection.RankBy.TIME, true)
        assertEquals(listOf(2, 0, 1), ranked.map { it.index })
        assertFalse(ranked.last().reachable)
    }

    @Test
    fun `parses slim matrix format durations and distances`() {
        // The non-verbose shape Valhalla emits without verbose:true.
        val resp = """
            {"sources_to_targets":{
              "durations":[[300, 120, 200]],
              "distances":[[5000, 2000, 3000]]
            },"units":"kilometers"}
        """.trimIndent()
        val ranked = DriverSelection.parseAndRank(resp, 3, DriverSelection.RankBy.TIME, false)
        assertEquals(listOf(1, 2, 0), ranked.map { it.index })
        assertEquals(120.0, ranked.first().timeSeconds)
        assertEquals(2000.0, ranked.first().distanceMeters)
    }

    @Test
    fun `parses slim matrix with unreachable null entry`() {
        val resp = """
            {"sources_to_targets":{
              "durations":[[300, null, 200]],
              "distances":[[5000, null, 3000]]
            }}
        """.trimIndent()
        val ranked = DriverSelection.parseAndRank(resp, 3, DriverSelection.RankBy.TIME, false)
        assertEquals(listOf(2, 0), ranked.map { it.index })
    }

    @Test
    fun `parseAndRank tolerates fewer cells than expected`() {
        // Engine returned 2 cells but we asked for 3 — must not throw, ranks the 2.
        val resp = matrixResponse(listOf(300.0 to 5000.0, 120.0 to 2000.0))
        val ranked = DriverSelection.parseAndRank(resp, 3, DriverSelection.RankBy.TIME, false)
        assertEquals(listOf(1, 0), ranked.map { it.index })
    }

    // ── End-to-end (gated) ─────────────────────────────────────────────────────

    @Test
    @Timeout(60)
    fun `end-to-end rank over a live pool returns reachable ranked drivers`() {
        val pool = try {
            ActorPool.forRegion("singapore", poolSize = 2)
        } catch (e: Throwable) {
            null
        }
        assumeTrue(pool != null, "Valhalla native/tiles not available — skipping live DriverSelection test")
        pool!!.use { p ->
            val ranked = p.withActor { actor ->
                DriverSelection.rank(actor, rider, drivers, costing = "auto")
            }
            // Singapore drivers near the rider should be reachable and time-ordered.
            assertTrue(ranked.isNotEmpty(), "expected at least one reachable driver")
            assertTrue(ranked.all { it.reachable })
            val times = ranked.mapNotNull { it.timeSeconds }
            assertEquals(times.sorted(), times, "drivers must be time-ascending")
        }
    }
}
