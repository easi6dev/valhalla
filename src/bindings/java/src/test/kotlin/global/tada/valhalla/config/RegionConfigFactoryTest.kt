package global.tada.valhalla.config

import org.json.JSONObject
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

@DisplayName("RegionConfigFactory tile_extract reconciliation")
class RegionConfigFactoryTest {

    @AfterEach
    fun clearProps() {
        System.clearProperty("valhalla.use.tile.extract")
    }

    @Test
    @DisplayName("Default: emits valid JSON with tile_extract under latest symlink")
    fun `default uses tile extract and latest`() {
        val json = RegionConfigFactory.buildConfig(
            region = "singapore"
        )
        // Must be parseable JSON (guards against template trailing-comma/brace bugs)
        val mjolnir = JSONObject(json).getJSONObject("mjolnir")

        val tileDir = mjolnir.getString("tile_dir")
        assertTrue(tileDir.endsWith("/singapore/latest"), "tile_dir should end with /singapore/latest, got: $tileDir")

        assertTrue(mjolnir.has("tile_extract"), "tile_extract should be present by default")
        val extract = mjolnir.getString("tile_extract")
        assertTrue(
            extract.endsWith("/singapore/latest/singapore.tar"),
            "tile_extract should point at latest/singapore.tar, got: $extract"
        )
        println("✅ default tile_extract: $extract")
    }

    @Test
    @DisplayName("Disabled via system property: omits tile_extract and latest")
    fun `disabled omits tile extract`() {
        System.setProperty("valhalla.use.tile.extract", "false")
        val json = RegionConfigFactory.buildConfig(
            region = "singapore"
        )
        val mjolnir = JSONObject(json).getJSONObject("mjolnir")

        val tileDir = mjolnir.getString("tile_dir")
        assertTrue(tileDir.endsWith("/singapore"), "tile_dir should end with /singapore (no /latest), got: $tileDir")
        assertFalse(tileDir.endsWith("/latest"), "tile_dir must not append /latest when disabled")
        assertFalse(mjolnir.has("tile_extract"), "tile_extract must be omitted when disabled")
        println("✅ disabled tile_dir: $tileDir")
    }

    @Test
    @DisplayName("thor memory-tuning keys present and valid")
    fun `thor tuning keys emitted`() {
        val json = RegionConfigFactory.buildConfig(region = "singapore")
        val thor = JSONObject(json).getJSONObject("thor")
        assertTrue(thor.getBoolean("clear_reserved_memory"), "clear_reserved_memory should be true")
        assertEquals(1000000, thor.getInt("max_reserved_labels_count_bidir_dijkstras"))
        assertEquals(1000000, thor.getInt("max_reserved_labels_count_astar"))
        assertEquals(500000, thor.getInt("max_reserved_labels_count_bidir_astar"))
        assertEquals(2000000, thor.getInt("max_reserved_labels_count_dijkstras"))
        println("✅ thor tuning keys present")
    }

    @Test
    @DisplayName("Traffic block still valid alongside tile_extract")
    fun `traffic and tile extract coexist as valid json`() {
        val json = RegionConfigFactory.buildConfig(
            region = "singapore",
            enableTraffic = true
        )
        val mjolnir = JSONObject(json).getJSONObject("mjolnir")
        assertTrue(mjolnir.has("tile_extract"))
        assertTrue(mjolnir.has("traffic_extract"))
        assertEquals(1073741824L, mjolnir.getLong("max_cache_size"))
        println("✅ traffic + extract JSON valid")
    }
}
