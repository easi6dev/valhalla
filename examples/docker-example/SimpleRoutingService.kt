package examples

import global.tada.valhalla.Actor
import global.tada.valhalla.ValhallaException
import global.tada.valhalla.config.TileConfig

/**
 * Simple HTTP Routing Service for Docker
 *
 * This is a minimal example. In production, use a proper HTTP framework
 * like Ktor, Spring Boot, or Micronaut.
 */
fun main() {
    println("═══════════════════════════════════════════════════════════")
    println("  Valhalla Routing Service (Docker Example)")
    println("═══════════════════════════════════════════════════════════")
    println()

    // Detect tile location
    val tileDir = TileConfig.autoDetect("singapore")
    println("📁 Tile directory: $tileDir")

    // Validate tiles
    if (!TileConfig.validate(tileDir)) {
        System.err.println("❌ Error: Invalid or missing tiles at: $tileDir")
        System.err.println("Mount tiles at /tiles when running container:")
        System.err.println("  docker run -v /host/tiles:/tiles:ro ...")
        System.exit(1)
    }

    println("✅ Tiles validated")
    println()

    // Create actor
    println("🚀 Initializing Valhalla Actor...")
    val actor = try {
        Actor.createWithExternalTiles("singapore")
    } catch (e: Exception) {
        System.err.println("❌ Failed to create actor: ${e.message}")
        e.printStackTrace()
        System.exit(1)
        return
    }

    println("✅ Actor initialized")
    println()

    // Test route to verify functionality
    println("🧪 Running test route...")
    val testRequest = """
    {
      "locations": [
        {"lat": 1.2834, "lon": 103.8607},
        {"lat": 1.3644, "lon": 103.9915}
      ],
      "costing": "auto"
    }
    """

    try {
        val result = actor.route(testRequest)
        println("✅ Test route successful (${result.length} chars)")
    } catch (e: ValhallaException) {
        System.err.println("❌ Test route failed: ${e.message}")
        actor.close()
        System.exit(1)
    }

    println()
    println("═══════════════════════════════════════════════════════════")
    println("  Service Ready!")
    println("  Press Ctrl+C to stop")
    println("═══════════════════════════════════════════════════════════")
    println()

    // Add shutdown hook
    Runtime.getRuntime().addShutdownHook(Thread {
        println()
        println("🛑 Shutting down...")
        actor.close()
        println("✅ Service stopped")
    })

    // Keep service running
    // In production, this would be a proper HTTP server
    while (true) {
        Thread.sleep(1000)
    }
}

/**
 * Health check for Docker
 */
object HealthCheck {
    @JvmStatic
    fun main(args: Array<String>) {
        val tileDir = TileConfig.autoDetect("singapore")
        if (TileConfig.validate(tileDir)) {
            System.exit(0)  // Healthy
        } else {
            System.exit(1)  // Unhealthy
        }
    }
}
