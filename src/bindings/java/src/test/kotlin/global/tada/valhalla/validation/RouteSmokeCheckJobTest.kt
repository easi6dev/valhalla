package global.tada.valhalla.validation

import org.json.JSONObject
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class RouteSmokeCheckJobTest {

    @Test
    fun `buildRouteRequestJson produces a two-location auto-costing request`() {
        val json = RouteSmokeCheckJob.buildRouteRequestJson(1.2897 to 103.8501, 1.2834 to 103.8607)

        val parsed = JSONObject(json)
        assertEquals("auto", parsed.getString("costing"))

        val locations = parsed.getJSONArray("locations")
        assertEquals(2, locations.length())
        assertEquals(1.2897, locations.getJSONObject(0).getDouble("lat"))
        assertEquals(103.8501, locations.getJSONObject(0).getDouble("lon"))
        assertEquals(1.2834, locations.getJSONObject(1).getDouble("lat"))
        assertEquals(103.8607, locations.getJSONObject(1).getDouble("lon"))
    }

    @Test
    fun `run returns exit 2 when fewer than 2 arguments are given`() {
        assertEquals(2, RouteSmokeCheckJob.run(arrayOf("singapore")))
        assertEquals(2, RouteSmokeCheckJob.run(arrayOf()))
    }

    @Test
    fun `run returns EXIT_NO_SAMPLE_LOCATIONS for a region with no sample locations configured`() {
        assertEquals(
            RouteSmokeCheckJob.EXIT_NO_SAMPLE_LOCATIONS,
            RouteSmokeCheckJob.run(arrayOf("thailand", "/tmp/some-tile-dir")),
        )
    }

    @Test
    fun `singapore and new_york both have sample locations configured`() {
        assertTrue(RouteSmokeCheckJob.SAMPLE_LOCATIONS.containsKey("singapore"))
        assertTrue(RouteSmokeCheckJob.SAMPLE_LOCATIONS.containsKey("new_york"))
    }
}
