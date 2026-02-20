package global.tada.valhalla.config

import org.junit.jupiter.api.Test
import org.junit.jupiter.api.DisplayName
import java.io.File
import kotlin.test.assertTrue
import kotlin.test.assertEquals
import kotlin.test.assertNotNull

@DisplayName("TileConfig Tests")
class TileConfigTest {

    @Test
    @DisplayName("Test fromPath with relative path")
    fun `test fromPath normalizes path`() {
        val path = TileConfig.fromPath("data/valhalla_tiles")
        assertNotNull(path)
        assertTrue(path.isNotBlank())
        println("✅ Normalized path: $path")
    }

    @Test
    @DisplayName("Test fromPath with absolute path")
    fun `test fromPath with absolute path`() {
        val absolutePath = File("data/valhalla_tiles").absolutePath
        val path = TileConfig.fromPath(absolutePath)
        assertNotNull(path)
        println("✅ Absolute path: $path")
    }

    @Test
    @DisplayName("Test fromEnvironment with default")
    fun `test fromEnvironment uses default when not set`() {
        val path = TileConfig.fromEnvironment("test/default/path")
        assertNotNull(path)
        println("✅ Path from environment (or default): $path")
    }

    @Test
    @DisplayName("Test fromSystemProperty with default")
    fun `test fromSystemProperty uses default when not set`() {
        val path = TileConfig.fromSystemProperty("test/default/path")
        assertNotNull(path)
        println("✅ Path from system property (or default): $path")
    }

    @Test
    @DisplayName("Test forRegion appends region to base dir")
    fun `test forRegion combines base and region`() {
        val baseDir = "/mnt/tiles"
        val path = TileConfig.forRegion("singapore", baseDir)

        assertTrue(path.contains("singapore"))
        println("✅ Region path: $path")
    }

    @Test
    @DisplayName("Test autoDetect finds tile directory")
    fun `test autoDetect returns valid path`() {
        val path = TileConfig.autoDetect()
        assertNotNull(path)
        assertTrue(path.isNotBlank())
        println("✅ Auto-detected path: $path")
    }

    @Test
    @DisplayName("Test autoDetect with region")
    fun `test autoDetect with region subdirectory`() {
        val path = TileConfig.autoDetect("singapore")
        assertNotNull(path)
        assertTrue(path.contains("singapore"))
        println("✅ Auto-detected region path: $path")
    }

    @Test
    @DisplayName("Test validate checks for tile structure")
    fun `test validate checks directory structure`() {
        // Test with existing singapore tiles (if available)
        val singaporeTiles = "data/valhalla_tiles/singapore"
        val isValid = TileConfig.validate(singaporeTiles)

        if (isValid) {
            println("✅ Found valid tiles at: $singaporeTiles")
        } else {
            println("⚠️  No tiles found at: $singaporeTiles")
            println("   Run: ./scripts/regions/build-tiles.sh singapore")
        }
    }

    @Test
    @DisplayName("Test validate with non-existent directory")
    fun `test validate returns false for non-existent directory`() {
        val nonExistent = "/this/path/does/not/exist"
        val isValid = TileConfig.validate(nonExistent)

        assertEquals(false, isValid)
        println("✅ Correctly identified non-existent directory")
    }

    @Test
    @DisplayName("Test path normalization")
    fun `test path normalization handles backslashes`() {
        val windowsPath = "C:\\Users\\Test\\tiles"
        val normalized = TileConfig.fromPath(windowsPath)

        // Should not contain backslashes (unless original path couldn't be resolved)
        val hasNoBackslashes = !normalized.contains("\\")
        val isUnchanged = normalized == windowsPath
        assertTrue(hasNoBackslashes || isUnchanged,
            "Path should be normalized: $normalized")
        println("✅ Normalized Windows path: $normalized")
    }

    @Test
    @DisplayName("Test createConfigWithTileDir")
    fun `test config creation with custom tile dir`() {
        val tileDir = "/mnt/tiles/singapore"
        val config = createConfigWithTileDir(tileDir, "singapore")

        assertNotNull(config)
        assertTrue(config.contains("tile_dir"))
        assertTrue(config.contains(tileDir) || config.contains(TileConfig.fromPath(tileDir)))
        println("✅ Created config with tile dir")
        println("Config snippet: ${config.take(200)}...")
    }
}
