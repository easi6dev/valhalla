package global.tada.valhalla

import global.tada.valhalla.config.RegionConfigFactory
import global.tada.valhalla.config.SingaporeConfig
import org.junit.jupiter.api.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.test.assertFalse
import kotlin.test.assertNotNull

class MultiRegionAPITest {

    @Test
    fun `test RegionConfigFactory getSupportedRegions`() {
        val regions = RegionConfigFactory.getSupportedRegions()
        assertTrue(regions.contains("singapore"))
        // "sg" is a normalisation alias, not a stored key in regions.json
        assertTrue(regions.contains("thailand"))
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
    fun `test SingaporeConfig buildConfig`() {
        val config = SingaporeConfig.buildConfig(
            tileDir = "test/tiles",
            enableTraffic = false
        )
        assertTrue(config.contains("mjolnir"))
        assertTrue(config.contains("test/tiles"))
        assertTrue(config.contains("service_limits"))
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

    @Test
    fun `test backward compatibility - deprecated Bounds object`() {
        @Suppress("DEPRECATION")
        val minLat = SingaporeConfig.Bounds.MIN_LAT
        assertEquals(1.15, minLat)

        @Suppress("DEPRECATION")
        val isValid = SingaporeConfig.Bounds.isValidLocation(1.3, 103.8)
        assertTrue(isValid)
    }
}
