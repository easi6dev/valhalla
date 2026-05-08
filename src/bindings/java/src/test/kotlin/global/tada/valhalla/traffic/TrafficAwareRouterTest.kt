package global.tada.valhalla.traffic

import org.json.JSONObject
import org.junit.jupiter.api.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Unit tests for [TrafficAwareRouter]'s static request-shaping helpers.
 *
 * Covers the JSON manipulation in `stripCurrentFromSpeedTypes` and
 * `ensureDateTimeForTraffic`. No native library required; freshness
 * gating is exercised via [TrafficStatusFileTest] against a real
 * Python-cron status file.
 */
class TrafficAwareRouterTest {

    // ─── stripCurrentFromSpeedTypes tests ───

    @Test
    fun `stripCurrentFromSpeedTypes removes current from existing speed_types`() {
        val request = """
        {
            "locations": [{"lat": 1.3, "lon": 103.8}],
            "costing": "auto",
            "costing_options": {
                "auto": {
                    "speed_types": ["freeflow", "constrained", "predicted", "current"]
                }
            }
        }
        """.trimIndent()

        val result = TrafficAwareRouter.stripCurrentFromSpeedTypes(request)
        val json = JSONObject(result)
        val speedTypes = json.getJSONObject("costing_options")
            .getJSONObject("auto")
            .getJSONArray("speed_types")

        val types = (0 until speedTypes.length()).map { speedTypes.getString(it) }
        assertTrue("freeflow" in types)
        assertTrue("constrained" in types)
        assertTrue("predicted" in types)
        assertFalse("current" in types)
    }

    @Test
    fun `stripCurrentFromSpeedTypes adds speed_types when absent`() {
        val request = """
        {
            "locations": [{"lat": 1.3, "lon": 103.8}],
            "costing": "auto"
        }
        """.trimIndent()

        val result = TrafficAwareRouter.stripCurrentFromSpeedTypes(request)
        val json = JSONObject(result)
        val speedTypes = json.getJSONObject("costing_options")
            .getJSONObject("auto")
            .getJSONArray("speed_types")

        val types = (0 until speedTypes.length()).map { speedTypes.getString(it) }
        assertEquals(3, types.size)
        assertTrue("freeflow" in types)
        assertTrue("constrained" in types)
        assertTrue("predicted" in types)
    }

    @Test
    fun `stripCurrentFromSpeedTypes handles missing costing_options`() {
        val request = """{"costing": "taxi"}"""

        val result = TrafficAwareRouter.stripCurrentFromSpeedTypes(request)
        val json = JSONObject(result)
        val speedTypes = json.getJSONObject("costing_options")
            .getJSONObject("taxi")
            .getJSONArray("speed_types")

        val types = (0 until speedTypes.length()).map { speedTypes.getString(it) }
        assertFalse("current" in types)
        assertEquals(3, types.size)
    }

    @Test
    fun `stripCurrentFromSpeedTypes defaults to auto when costing not specified`() {
        val request = """{"locations": [{"lat": 1.3, "lon": 103.8}]}"""

        val result = TrafficAwareRouter.stripCurrentFromSpeedTypes(request)
        val json = JSONObject(result)

        assertTrue(json.getJSONObject("costing_options").has("auto"))
    }

    // ─── ensureDateTimeForTraffic tests ───

    @Test
    fun `ensureDateTimeForTraffic injects date_time type 0 when absent`() {
        val request = """{"locations": [{"lat": 1.3, "lon": 103.8}], "costing": "auto"}"""

        val result = TrafficAwareRouter.ensureDateTimeForTraffic(request)
        val json = JSONObject(result)

        assertTrue(json.has("date_time"))
        assertEquals(0, json.getJSONObject("date_time").getInt("type"))
    }

    @Test
    fun `ensureDateTimeForTraffic preserves existing date_time`() {
        val request = """
        {
            "locations": [{"lat": 1.3, "lon": 103.8}],
            "costing": "auto",
            "date_time": {"type": 1, "value": "2026-05-08T09:00"}
        }
        """.trimIndent()

        val result = TrafficAwareRouter.ensureDateTimeForTraffic(request)
        val dateTime = JSONObject(result).getJSONObject("date_time")

        assertEquals(1, dateTime.getInt("type"))
        assertEquals("2026-05-08T09:00", dateTime.getString("value"))
    }

    @Test
    fun `ensureDateTimeForTraffic includes current in speed_types`() {
        val request = """{"locations": [{"lat": 1.3, "lon": 103.8}], "costing": "auto"}"""

        val result = TrafficAwareRouter.ensureDateTimeForTraffic(request)
        val speedTypes = JSONObject(result)
            .getJSONObject("costing_options")
            .getJSONObject("auto")
            .getJSONArray("speed_types")
        val types = (0 until speedTypes.length()).map { speedTypes.getString(it) }

        assertTrue("current" in types)
        assertTrue("freeflow" in types)
        assertTrue("predicted" in types)
    }

    @Test
    fun `ensureDateTimeForTraffic creates costing_options when missing`() {
        val request = """{"locations": [{"lat": 1.3, "lon": 103.8}], "costing": "taxi"}"""

        val result = TrafficAwareRouter.ensureDateTimeForTraffic(request)
        val json = JSONObject(result)

        assertTrue(json.getJSONObject("costing_options").has("taxi"))
        assertTrue(
            json.getJSONObject("costing_options")
                .getJSONObject("taxi")
                .has("speed_types")
        )
    }

    @Test
    fun `ensureDateTimeForTraffic defaults to auto when costing absent`() {
        val request = """{"locations": [{"lat": 1.3, "lon": 103.8}]}"""

        val result = TrafficAwareRouter.ensureDateTimeForTraffic(request)
        val json = JSONObject(result)

        assertTrue(json.getJSONObject("costing_options").has("auto"))
    }

}
