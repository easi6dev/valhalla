package examples

import global.tada.valhalla.Actor
import global.tada.valhalla.ValhallaException
import global.tada.valhalla.config.TileConfig

/**
 * Simple Routing Example
 *
 * Demonstrates basic routing with external tile configuration.
 *
 * Usage:
 * 1. Set environment variable:
 *    export VALHALLA_TILE_DIR=data/valhalla_tiles/singapore/latest
 *
 * 2. Run:
 *    ./gradlew run
 */
fun main() {
    println("═══════════════════════════════════════════════════════════")
    println("  Valhalla Simple Routing Example")
    println("═══════════════════════════════════════════════════════════")
    println()

    // Detect tile location
    val tileDir = TileConfig.autoDetect("singapore")
    println("🔍 Detected tile directory: $tileDir")

    // Validate tiles
    if (!TileConfig.validate(tileDir)) {
        println("❌ Error: Invalid or missing tiles at: $tileDir")
        println()
        println("Please ensure:")
        println("  1. Tiles are built for Singapore")
        println("  2. Directory structure exists: $tileDir/2/000/...")
        println("  3. Or set VALHALLA_TILE_DIR environment variable")
        return
    }

    println("✅ Tiles validated successfully")
    println()

    try {
        // Create actor with external tiles
        println("🚀 Creating Valhalla Actor...")
        val actor = Actor.createWithExternalTiles("singapore")
        println("✅ Actor created successfully")
        println()

        // Example 1: Simple route from Marina Bay to Changi Airport
        println("📍 Route 1: Marina Bay → Changi Airport")
        val route1 = """
        {
          "locations": [
            {"lat": 1.2834, "lon": 103.8607},
            {"lat": 1.3644, "lon": 103.9915}
          ],
          "costing": "auto",
          "units": "kilometers"
        }
        """

        val result1 = actor.route(route1)
        println("✅ Route calculated successfully")
        println("Response length: ${result1.length} characters")
        println()

        // Example 2: Short route in CBD
        println("📍 Route 2: Raffles Place → Marina Bay Sands")
        val route2 = """
        {
          "locations": [
            {"lat": 1.2897, "lon": 103.8501},
            {"lat": 1.2834, "lon": 103.8607}
          ],
          "costing": "auto",
          "directions_options": {
            "units": "kilometers"
          }
        }
        """

        val result2 = actor.route(route2)
        println("✅ Route calculated successfully")
        println("Response length: ${result2.length} characters")
        println()

        // Example 3: Motorcycle routing
        println("📍 Route 3: Orchard Road → Bugis (Motorcycle)")
        val route3 = """
        {
          "locations": [
            {"lat": 1.3048, "lon": 103.8318},
            {"lat": 1.3005, "lon": 103.8557}
          ],
          "costing": "motorcycle"
        }
        """

        val result3 = actor.route(route3)
        println("✅ Motorcycle route calculated successfully")
        println("Response length: ${result3.length} characters")
        println()

        // Clean up
        actor.close()
        println("✅ Actor closed")

    } catch (e: ValhallaException) {
        println("❌ Valhalla Error: ${e.message}")
        e.printStackTrace()
    } catch (e: Exception) {
        println("❌ Unexpected Error: ${e.message}")
        e.printStackTrace()
    }

    println()
    println("═══════════════════════════════════════════════════════════")
    println("  Example completed successfully!")
    println("═══════════════════════════════════════════════════════════")
}
