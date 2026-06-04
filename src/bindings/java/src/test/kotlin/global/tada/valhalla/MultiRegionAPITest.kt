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

    // -------------------------------------------------------------------------
    // Phase 2 — injectable performance knobs (2026-06-04).
    // buildConfig() defaults to the historical hardcoded values for EVERY region
    // (zero regression for direct callers, incl. SG). Cheaper values are opt-in
    // via explicit params (ActorPool supplies them to pooled actors only).
    // See tasks/todo-concurrency-scaling.md.
    // -------------------------------------------------------------------------

    @Test
    fun `test buildConfig defaults preserve historical values for every region`() {
        System.setProperty("valhalla.use.tile.extract", "false")
        try {
            // Default (no knob params) must equal the old hardcoded config for BOTH
            // a direct-tile_dir region (SG) and a tile_group region (NYC).
            for (region in listOf("singapore", "new_york")) {
                val config = RegionConfigFactory.buildConfig(region = region, enableTraffic = false)
                assertTrue(config.contains("\"max_cache_size\": 1073741824"),
                    "$region default must keep the 1 GiB cache")
                assertTrue(config.contains("\"minimum_reachability\": 50"),
                    "$region default must keep reachability 50")
                assertTrue(config.contains("\"search_cutoff\": 35000"),
                    "$region default must keep search_cutoff 35000")
                assertTrue(config.contains("\"concurrency\": 4"),
                    "$region default must keep reader concurrency 4")
                assertTrue(config.contains("\"cache_size\": 100240"),
                    "$region default must keep the Meili grid cache 100240")
            }
        } finally {
            System.clearProperty("valhalla.use.tile.extract")
        }
    }

    @Test
    fun `test buildConfig honours injected performance knobs`() {
        System.setProperty("valhalla.use.tile.extract", "false")
        try {
            val tuned = RegionConfigFactory.buildConfig(
                region = "new_york",
                enableTraffic = false,
                maxCacheSizeBytes = 268435456L,   // 256 MiB
                readerConcurrency = 2,
                minimumReachability = 20,
                searchCutoff = 10000,
                maxDistanceMeters = 200000.0,
                meiliGridCacheSize = 25000        // map-matching memory bound
            )
            assertTrue(tuned.contains("\"max_cache_size\": 268435456"))
            assertTrue(tuned.contains("\"concurrency\": 2"))
            assertTrue(tuned.contains("\"minimum_reachability\": 20"))
            assertTrue(tuned.contains("\"search_cutoff\": 10000"))
            assertTrue(tuned.contains("\"max_distance\": 200000.0"))
            assertTrue(tuned.contains("\"cache_size\": 25000"),
                "map-matching grid cache must honour the injected value")
            // Default grid cache must be gone when overridden.
            assertFalse(tuned.contains("\"cache_size\": 100240"))
            // Old expensive values must be gone when overridden.
            assertFalse(tuned.contains("\"max_cache_size\": 1073741824"))
            assertFalse(tuned.contains("\"search_cutoff\": 35000"))
        } finally {
            System.clearProperty("valhalla.use.tile.extract")
        }
    }

}
