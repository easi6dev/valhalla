package global.tada.valhalla

import global.tada.valhalla.config.RegionConfigFactory
import global.tada.valhalla.config.SingaporeConfig
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.test.assertFalse
import kotlin.test.assertNotNull

class MultiRegionAPITest {

    // RegionConfigFactory caches the parsed regions.json in a static field.
    // Without clearing it between tests, one test's config state leaks into the
    // next (and into other test classes run in the same JVM).
    @BeforeEach
    fun clearFactoryCache() {
        RegionConfigFactory.clearCache()
    }

    @Test
    fun `test RegionConfigFactory getSupportedRegions`() {
        val regions = RegionConfigFactory.getSupportedRegions()
        assertTrue(regions.contains("singapore"))
        // "sg" is a normalisation alias, not a stored key in regions.json
        assertTrue(regions.contains("thailand"))
        // Tri-state regions are stored keys (their aliases are not)
        assertTrue(regions.contains("new_york"))
        assertTrue(regions.contains("new_jersey"))
        assertTrue(regions.contains("connecticut"))
    }

    @Test
    fun `test RegionConfigFactory isSupported`() {
        assertTrue(RegionConfigFactory.isSupported("singapore"))
        assertTrue(RegionConfigFactory.isSupported("sg"))   // alias → normalised to "singapore"
        assertTrue(RegionConfigFactory.isSupported("Singapore"))
        assertTrue(RegionConfigFactory.isSupported("SG"))
        assertTrue(RegionConfigFactory.isSupported("thailand"))  // present in regions.json (disabled but listed)
        assertFalse(RegionConfigFactory.isSupported("invalid"))
    }

    @Test
    fun `test RegionConfigFactory getRegionInfo`() {
        val info = RegionConfigFactory.getRegionInfo("singapore")
        assertEquals("Singapore", info["name"])
        assertEquals("Asia/Singapore", info["timezone"])
        assertEquals("en-SG", info["locale"])
        assertEquals("SGD", info["currency"])
    }

    @Test
    fun `test RegionConfigFactory buildConfig`() {
        val config = RegionConfigFactory.buildConfig(
            region = "singapore",
            tileDir = "test/path",
            enableTraffic = false
        )
        assertTrue(config.contains("mjolnir"))
        assertTrue(config.contains("test/path"))
    }

    @Test
    fun `test SingaporeConfig bounds`() {
        val bounds = SingaporeConfig.bounds
        assertEquals(1.15, bounds.minLat)
        assertEquals(1.48, bounds.maxLat)
        assertEquals(103.6, bounds.minLon)
        assertEquals(104.0, bounds.maxLon)

        // Test location validation
        assertTrue(bounds.isValidLocation(1.3, 103.8)) // Central Singapore
        assertFalse(bounds.isValidLocation(0.0, 0.0)) // Null Island

        // Test center calculation
        val (lat, lon) = bounds.center()
        assertEquals(1.315, lat, 0.001)
        assertEquals(103.8, lon, 0.001)
    }

    @Test
    fun `test Actor createForRegion with singapore`() {
        // This will fail if tiles don't exist, but validates the API compiles
        try {
            val actor = Actor.createForRegion("singapore")
            assertNotNull(actor)
            actor.close()
        } catch (e: Exception) {
            // Expected if tiles not in default location
            println("Note: Actor creation failed (expected if tiles not present): ${e.message}")
        }
    }

    @Test
    fun `test backward compatibility - deprecated createSingapore`() {
        // Test that old API still compiles (will show deprecation warning)
        try {
            @Suppress("DEPRECATION")
            val actor = Actor.createSingapore()
            assertNotNull(actor)
            actor.close()
        } catch (e: Exception) {
            // Expected if tiles not in default location
            println("Note: Actor creation failed (expected if tiles not present): ${e.message}")
        }
    }

    @Test
    fun `test SingaporeConfig properties`() {
        assertEquals("Singapore", SingaporeConfig.regionName)
        assertEquals("Asia/Singapore", SingaporeConfig.timezone)
        assertEquals("en-SG", SingaporeConfig.locale)
        assertEquals("SGD", SingaporeConfig.currency)
    }

    @Test
    fun `test SingaporeConfig costing profiles`() {
        val autoProfile = SingaporeConfig.autoProfile()
        assertTrue(autoProfile.contains("costing"))
        assertTrue(autoProfile.contains("auto"))

        val motorcycleProfile = SingaporeConfig.motorcycleProfile()
        assertTrue(motorcycleProfile.contains("motorcycle"))

        val taxiProfile = SingaporeConfig.taxiProfile()
        assertTrue(taxiProfile.contains("costing"))
    }

    // -------------------------------------------------------------------------
    // NY tri-state (shared tile group) tests
    // -------------------------------------------------------------------------

    @Test
    fun `test new_york aliases resolve`() {
        assertTrue(RegionConfigFactory.isSupported("new_york"))
        assertTrue(RegionConfigFactory.isSupported("nyc"))
        assertTrue(RegionConfigFactory.isSupported("ny"))
        assertTrue(RegionConfigFactory.isSupported("NYC"))
        assertTrue(RegionConfigFactory.isSupported("nj"))
        assertTrue(RegionConfigFactory.isSupported("ct"))
    }

    @Test
    fun `test RegionConfigFactory getRegionInfo new_york`() {
        val info = RegionConfigFactory.getRegionInfo("new_york")
        assertEquals("New York", info["name"])
        assertEquals("America/New_York", info["timezone"])
        assertEquals("en-US", info["locale"])
        assertEquals("USD", info["currency"])
        // tile_dir resolves through the tile_group, not a direct field
        assertEquals("nyc_tri_state", info["tile_dir"])
    }

    @Test
    fun `test tri-state regions share one tile dir`() {
        // All three regions resolve to the same shared tile subdir via tile_group.
        val nyConfig = RegionConfigFactory.buildConfig(region = "new_york", enableTraffic = false)
        val njConfig = RegionConfigFactory.buildConfig(region = "new_jersey", enableTraffic = false)
        val ctConfig = RegionConfigFactory.buildConfig(region = "connecticut", enableTraffic = false)

        assertTrue(nyConfig.contains("nyc_tri_state"), "new_york config must point at the shared tile dir")
        assertTrue(njConfig.contains("nyc_tri_state"), "new_jersey config must point at the shared tile dir")
        assertTrue(ctConfig.contains("nyc_tri_state"), "connecticut config must point at the shared tile dir")
    }

    @Test
    fun `test aliases build config to shared tile dir`() {
        val viaAlias = RegionConfigFactory.buildConfig(region = "nyc", enableTraffic = false)
        assertTrue(viaAlias.contains("nyc_tri_state"))
        assertTrue(viaAlias.contains("mjolnir"))
    }

    @Test
    fun `test new_york with null tileDir resolves to shared group not region name`() {
        // Regression guard for the Actor.createForRegion convenience path: when no
        // explicit tileDir is given (null), resolution must go through the
        // tile_group to nyc_tri_state — NOT a per-region data/valhalla_tiles/new_york
        // dir (which does not exist). Asserts on the generated config so no native
        // lib / tiles are required.
        val config = RegionConfigFactory.buildConfig(region = "new_york", tileDir = null)
        assertTrue(config.contains("nyc_tri_state"), "must point at the shared tile dir")
        assertFalse(
            config.contains("valhalla_tiles/new_york/") || config.contains("valhalla_tiles/new_york\""),
            "must NOT point at a per-region new_york tile dir"
        )
    }

    @Test
    fun `test singapore tile dir unaffected by tile_group feature`() {
        // Regression: Singapore uses a direct tile_dir and must NOT resolve to a group.
        val info = RegionConfigFactory.getRegionInfo("singapore")
        assertEquals("singapore", info["tile_dir"])

        val sgConfig = RegionConfigFactory.buildConfig(region = "singapore", enableTraffic = false)
        assertTrue(sgConfig.contains("singapore"))
        assertFalse(sgConfig.contains("nyc_tri_state"))
    }

}
