package examples

import global.tada.valhalla.Actor
import global.tada.valhalla.ValhallaException
import global.tada.valhalla.config.TileConfig

/**
 * Multiple Regions Example
 *
 * Demonstrates managing multiple region actors simultaneously.
 *
 * Usage:
 *   export VALHALLA_TILE_DIR=data/valhalla_tiles
 *   ./gradlew run
 */
fun main() {
    println("═══════════════════════════════════════════════════════════")
    println("  Valhalla Multiple Regions Example")
    println("═══════════════════════════════════════════════════════════")
    println()

    // Define regions to use
    val regions = listOf("singapore", "thailand")

    // Detect base tile directory
    val baseTileDir = TileConfig.fromEnvironment("data/valhalla_tiles/singapore/latest")
    println("📁 Base tile directory: $baseTileDir")
    println()

    // Create actors for each region
    val actors = mutableMapOf<String, Actor>()

    for (region in regions) {
        val regionTileDir = TileConfig.forRegion(region, baseTileDir)
        println("🔍 Checking $region tiles: $regionTileDir")

        if (TileConfig.validate(regionTileDir)) {
            try {
                val actor = Actor.createWithTilePath(regionTileDir, region)
                actors[region] = actor
                println("✅ $region actor created successfully")
            } catch (e: Exception) {
                println("❌ Failed to create $region actor: ${e.message}")
            }
        } else {
            println("⚠️  $region tiles not found or invalid")
        }
        println()
    }

    if (actors.isEmpty()) {
        println("❌ No actors created. Please ensure tiles are available.")
        return
    }

    println("═══════════════════════════════════════════════════════════")
    println("  Testing Routes in Different Regions")
    println("═══════════════════════════════════════════════════════════")
    println()

    // Test Singapore routes
    actors["singapore"]?.let { singaporeActor ->
        println("🇸🇬 Singapore Routes:")
        println("─────────────────────────────────────────────────────────")

        val singaporeRoutes = listOf(
            Triple("Marina Bay → Changi", 1.2834 to 103.8607, 1.3644 to 103.9915),
            Triple("CBD → Sentosa", 1.2897 to 103.8501, 1.2494 to 103.8303),
            Triple("Orchard → Jurong", 1.3048 to 103.8318, 1.3329 to 103.7436)
        )

        for ((name, from, to) in singaporeRoutes) {
            testRoute(singaporeActor, name, from, to)
        }
        println()
    }

    // Test Thailand routes (if available)
    actors["thailand"]?.let { thailandActor ->
        println("🇹🇭 Thailand Routes:")
        println("─────────────────────────────────────────────────────────")

        val thailandRoutes = listOf(
            Triple("Bangkok Center", 13.7563 to 100.5018, 13.7467 to 100.5339)
        )

        for ((name, from, to) in thailandRoutes) {
            testRoute(thailandActor, name, from, to)
        }
        println()
    }

    // Matrix calculation example
    actors["singapore"]?.let { singaporeActor ->
        println("📊 Matrix Calculation (Singapore)")
        println("─────────────────────────────────────────────────────────")

        val matrixRequest = """
        {
          "sources": [
            {"lat": 1.2834, "lon": 103.8607}
          ],
          "targets": [
            {"lat": 1.3644, "lon": 103.9915},
            {"lat": 1.2897, "lon": 103.8501},
            {"lat": 1.3048, "lon": 103.8318}
          ],
          "costing": "auto"
        }
        """

        try {
            val result = singaporeActor.matrix(matrixRequest)
            println("✅ Matrix calculated: 1 source → 3 targets")
            println("   Response length: ${result.length} characters")
        } catch (e: ValhallaException) {
            println("❌ Matrix error: ${e.message}")
        }
        println()
    }

    // Clean up all actors
    println("═══════════════════════════════════════════════════════════")
    println("  Cleanup")
    println("═══════════════════════════════════════════════════════════")
    println()

    actors.forEach { (region, actor) ->
        actor.close()
        println("✅ Closed $region actor")
    }

    println()
    println("═══════════════════════════════════════════════════════════")
    println("  Example completed!")
    println("  Processed ${actors.size} region(s)")
    println("═══════════════════════════════════════════════════════════")
}

/**
 * Test a single route
 */
fun testRoute(actor: Actor, name: String, from: Pair<Double, Double>, to: Pair<Double, Double>) {
    val request = """
    {
      "locations": [
        {"lat": ${from.first}, "lon": ${from.second}},
        {"lat": ${to.first}, "lon": ${to.second}}
      ],
      "costing": "auto"
    }
    """

    try {
        val result = actor.route(request)
        println("  ✅ $name")
        println("     Response: ${result.length} chars")
    } catch (e: ValhallaException) {
        println("  ❌ $name: ${e.message}")
    }
}
