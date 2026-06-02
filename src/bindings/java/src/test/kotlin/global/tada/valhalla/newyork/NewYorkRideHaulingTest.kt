package global.tada.valhalla.newyork

import global.tada.valhalla.Actor
import org.json.JSONObject
import org.junit.jupiter.api.*
import org.junit.jupiter.api.Assertions.*
import org.junit.jupiter.api.Assumptions.assumeTrue
import java.io.File

/**
 * Integration test suite for NY tri-state ride-hailing scenarios against the
 * shared `nyc_tri_state` tiles. Mirrors SingaporeRideHaulingTest.
 *
 * The cross-state tests (NYC -> Newark NJ, NYC -> Stamford CT) are the reason
 * the shared tile group exists: all three states build into one tile set so
 * routing can cross state lines.
 *
 * Prerequisites (when run as a real integration test):
 * - Tri-state tiles built in data/valhalla_tiles/nyc_tri_state
 *     ./scripts/regions/merge-osm.sh nyc_tri_state
 *     ./scripts/regions/build-tiles.sh new_york --no-elevation
 * - Native JNI library on the path (gradle `buildNative`).
 *
 * When tiles or the native lib are absent (e.g. the default CI checkout that
 * runs `-x buildNative`), every test SKIPS via JUnit assumptions rather than
 * failing — so this file is safe to keep in the default test run.
 */
@TestInstance(TestInstance.Lifecycle.PER_CLASS)
@TestMethodOrder(MethodOrderer.OrderAnnotation::class)
class NewYorkRideHaulingTest {

    private var actor: Actor? = null

    companion object {
        // Shared tile group dir — NY/NJ/CT all serve from here.
        private const val TILE_DIR = "data/valhalla_tiles/nyc_tri_state"
    }

    @BeforeAll
    fun setup() {
        val tileDir = File(TILE_DIR)
        val hasTiles = tileDir.isDirectory &&
            tileDir.walkTopDown().any { it.extension == "gph" }

        // Skip the whole suite (no failure) when tiles are not present.
        assumeTrue(hasTiles, "nyc_tri_state tiles not found in $TILE_DIR — skipping integration tests")

        actor = try {
            Actor.createForRegion("new_york", File(TILE_DIR).canonicalPath)
        } catch (e: Throwable) {
            // Native lib missing (no buildNative) — skip rather than fail.
            assumeTrue(false, "Could not create Actor (native lib not built?): ${e.message}")
            null
        }
    }

    @AfterAll
    fun teardown() {
        actor?.close()
    }

    private fun requireActor(): Actor {
        val a = actor
        assumeTrue(a != null, "Actor not initialized — skipping")
        return a!!
    }

    private fun routeSummary(origin: Location, dest: Location, costing: String = "auto"): JSONObject {
        val request = """
        {
          "locations": [
            {"lat": ${origin.lat}, "lon": ${origin.lon}},
            {"lat": ${dest.lat}, "lon": ${dest.lon}}
          ],
          "costing": "$costing",
          "units": "kilometers"
        }
        """
        val result = requireActor().route(request)
        assertNotNull(result)
        val json = JSONObject(result)
        assertTrue(json.has("trip"), "response must contain a trip")
        return json.getJSONObject("trip").getJSONObject("summary")
    }

    @Test
    @Order(1)
    fun `test 01 - service status`() {
        val result = requireActor().status("""{"verbose": true}""")
        val json = JSONObject(result)
        assertTrue(json.has("version") || json.has("tileset_last_modified"))
    }

    @Test
    @Order(2)
    fun `test 02 - short intra-NYC route (Times Sq to Wall St)`() {
        val (o, d) = NewYorkLocations.TestRoutes.SHORT_ROUTE
        val summary = routeSummary(o, d)
        val km = summary.getDouble("length")
        assertTrue(km < 8.0, "short route should be < 8km, got $km")
    }

    @Test
    @Order(3)
    fun `test 03 - medium route (Times Sq to JFK)`() {
        val (o, d) = NewYorkLocations.TestRoutes.MEDIUM_ROUTE
        val summary = routeSummary(o, d)
        val km = summary.getDouble("length")
        assertTrue(km in 10.0..40.0, "JFK route should be 10-40km, got $km")
    }

    @Test
    @Order(4)
    fun `test 04 - taxi costing route`() {
        val (o, d) = NewYorkLocations.TestRoutes.SHORT_ROUTE
        val summary = routeSummary(o, d, costing = "taxi")
        assertTrue(summary.getDouble("length") > 0.0)
    }

    @Test
    @Order(5)
    fun `test 05 - matrix sources_to_targets`() {
        val drivers = NewYorkLocations.getDriverLocations(3)
        val locs = drivers.joinToString(",") { """{"lat": ${it.lat}, "lon": ${it.lon}}""" }
        val request = """
        {
          "sources": [$locs],
          "targets": [$locs],
          "costing": "auto"
        }
        """
        val result = requireActor().matrix(request)
        val json = JSONObject(result)
        assertTrue(json.has("sources_to_targets"))
    }

    @Test
    @Order(6)
    fun `test 06 - isochrone`() {
        val o = NewYorkLocations.TIMES_SQUARE
        val request = """
        {
          "locations": [{"lat": ${o.lat}, "lon": ${o.lon}}],
          "costing": "auto",
          "contours": [{"time": 10}]
        }
        """
        val result = requireActor().isochrone(request)
        val json = JSONObject(result)
        assertTrue(json.has("features") || json.has("type"))
    }

    @Test
    @Order(7)
    fun `test 07 - CROSS-STATE NYC to Newark NJ`() {
        // The headline shared-tile case: routing must cross the NY/NJ line.
        val (o, d) = NewYorkLocations.TestRoutes.NYC_TO_NJ
        val summary = routeSummary(o, d)
        val km = summary.getDouble("length")
        assertTrue(km in 8.0..60.0, "NYC->Newark should be 8-60km, got $km")
    }

    @Test
    @Order(8)
    fun `test 08 - CROSS-STATE NYC to Stamford CT`() {
        val (o, d) = NewYorkLocations.TestRoutes.NYC_TO_CT
        val summary = routeSummary(o, d)
        val km = summary.getDouble("length")
        assertTrue(km in 30.0..90.0, "NYC->Stamford should be 30-90km, got $km")
    }
}
