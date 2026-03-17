package global.tada.valhalla

import org.junit.jupiter.api.Assertions.*
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows

/**
 * Test suite for Valhalla Actor.
 *
 * Note: These tests require a valid Valhalla configuration and tile data.
 * Set VALHALLA_TILE_DIR environment variable to the path containing tiles.
 */
class ActorTest {

    private val testConfig: String
        get() {
            val tileDir = System.getenv("VALHALLA_TILE_DIR") ?: "/path/to/tiles"
            return """
            {
              "mjolnir": {
                "tile_dir": "$tileDir",
                "concurrency": 1
              },
              "loki": {
                "actions": ["route", "locate", "sources_to_targets"],
                "service_defaults": {
                  "minimum_reachability": 50,
                  "radius": 0
                }
              }
            }
            """.trimIndent()
        }

    @Test
    fun `test actor creation with valid config`() {
        // This test will fail if VALHALLA_TILE_DIR is not set correctly
        // or if native library is not loaded
        assertThrows<ValhallaException> {
            Actor(testConfig).use { actor ->
                assertNotNull(actor)
            }
        }
    }

    @Test
    fun `test actor creation with invalid config`() {
        val invalidConfig = "{ invalid json }"

        assertThrows<ValhallaException> {
            Actor(invalidConfig)
        }
    }

    @Test
    fun `test actor close multiple times`() {
        assertThrows<ValhallaException> {
            val actor = Actor(testConfig)
            actor.close()
            actor.close() // Should not throw
        }
    }

    @Test
    fun `test route after close throws exception`() {
        assertThrows<ValhallaException> {
            val actor = Actor(testConfig)
            actor.close()

            assertThrows<IllegalStateException> {
                actor.route("""{"locations": []}""")
            }
        }
    }

    // Note: The following tests require valid tile data
    // They are commented out as examples

    /*
    @Test
    fun `test basic route calculation`() {
        Actor(testConfig).use { actor ->
            val request = """
            {
              "locations": [
                {"lat": 40.748817, "lon": -73.985428},
                {"lat": 40.751455, "lon": -73.989541}
              ],
              "costing": "auto"
            }
            """.trimIndent()

            val result = actor.route(request)
            assertNotNull(result)
            assertTrue(result.contains("trip"))
        }
    }

    @Test
    fun `test matrix calculation`() {
        Actor(testConfig).use { actor ->
            val request = """
            {
              "sources": [
                {"lat": 40.748817, "lon": -73.985428}
              ],
              "targets": [
                {"lat": 40.751455, "lon": -73.989541}
              ],
              "costing": "auto"
            }
            """.trimIndent()

            val result = actor.matrix(request)
            assertNotNull(result)
        }
    }

    @Test
    fun `test async route calculation`() {
        Actor(testConfig).use { actor ->
            val request = """
            {
              "locations": [
                {"lat": 40.748817, "lon": -73.985428},
                {"lat": 40.751455, "lon": -73.989541}
              ],
              "costing": "auto"
            }
            """.trimIndent()

            val future = actor.routeAsync(request)
            val result = future.get()

            assertNotNull(result)
            assertTrue(result.contains("trip"))
        }
    }
    */
}
