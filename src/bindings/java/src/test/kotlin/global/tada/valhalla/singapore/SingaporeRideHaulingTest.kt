package global.tada.valhalla.singapore

import global.tada.valhalla.Actor
import org.json.JSONObject
import org.junit.jupiter.api.*
import org.junit.jupiter.api.Assertions.*
import java.io.File

/**
 * Comprehensive test suite for Singapore ride-hailing scenarios
 * Tests the JNI bindings with real Singapore locations and routes
 *
 * Prerequisites:
 * - Singapore tiles must be built in data/valhalla_tiles/singapore
 * - Run: ./scripts/singapore/build-tiles.sh singapore
 */
@TestInstance(TestInstance.Lifecycle.PER_CLASS)
@TestMethodOrder(MethodOrderer.OrderAnnotation::class)
class SingaporeRideHaulingTest {

    private lateinit var actor: Actor
    private val testResults = mutableListOf<TestResult>()

    companion object {
        private const val TILE_DIR = "data/valhalla_tiles/singapore"
    }

    data class TestResult(
        val testName: String,
        val passed: Boolean,
        val durationMs: Long,
        val details: String
    )

    @BeforeAll
    fun setup() {
        println("=".repeat(80))
        println("Singapore Ride-Hailing Test Suite - JNI Bindings")
        println("=".repeat(80))

        // Check if tiles exist
        val tileDir = File(TILE_DIR)
        if (!tileDir.exists() || !tileDir.isDirectory) {
            throw IllegalStateException(
                """
                Singapore tiles not found!
                Please build tiles first:
                  cd ${System.getProperty("user.dir")}
                  ./scripts/singapore/download-region-osm.sh singapore
                  ./scripts/singapore/build-tiles.sh singapore
                """.trimIndent()
            )
        }

        // Check tile count
        val tileCount = tileDir.walkTopDown()
            .filter { it.extension == "gph" }
            .count()

        if (tileCount == 0) {
            throw IllegalStateException("No tile files found in $TILE_DIR")
        }

        println("✓ Found $tileCount tile files")

        // Use Actor.createSingapore() helper with absolute path
        val absoluteTileDir = File(TILE_DIR).canonicalPath

        println("✓ Using tile directory: $absoluteTileDir")

        // Create actor using the helper method
        try {
            actor = Actor.createSingapore(absoluteTileDir)
            println("✓ Valhalla Actor created successfully")
        } catch (e: Exception) {
            throw IllegalStateException("Failed to create Actor: ${e.message}", e)
        }

        println("")
    }

    @AfterAll
    fun teardown() {
        actor.close()
        println("")
        println("=".repeat(80))
        println("Test Summary")
        println("=".repeat(80))
        println("Total tests: ${testResults.size}")
        println("Passed: ${testResults.count { it.passed }}")
        println("Failed: ${testResults.count { !it.passed }}")
        println("")

        if (testResults.isNotEmpty()) {
            println("Performance Summary:")
            val avgDuration = testResults.map { it.durationMs }.average()
            val maxDuration = testResults.maxOf { it.durationMs }
            val minDuration = testResults.minOf { it.durationMs }
            println("  Average: %.2f ms".format(avgDuration))
            println("  Min:     $minDuration ms")
            println("  Max:     $maxDuration ms")
        }
        println("=".repeat(80))
    }

    private fun runTest(testName: String, block: () -> Unit) {
        val startTime = System.currentTimeMillis()
        var passed = false
        var details = ""

        try {
            block()
            passed = true
            details = "Success"
        } catch (e: Exception) {
            details = "Failed: ${e.message}"
            throw e
        } finally {
            val duration = System.currentTimeMillis() - startTime
            testResults.add(TestResult(testName, passed, duration, details))
            println("  ✓ Completed in ${duration}ms")
        }
    }

    @Test
    @Order(1)
    fun `test 01 - Service Status Check`() = runTest("Service Status") {
        println("\nTest 1: Service Status Check")

        val request = """
        {
          "verbose": true
        }
        """

        val result = actor.status(request)
        assertNotNull(result)

        val json = JSONObject(result)
        assertTrue(json.has("tileset_last_modified") || json.has("version"))
        println("  Status: OK")
    }

    @Test
    @Order(2)
    fun `test 02 - Short Route (CBD) - Raffles Place to Marina Bay`() = runTest("Short Route") {
        println("\nTest 2: Short Route - Raffles Place to Marina Bay Sands")

        val (origin, dest) = SingaporeLocations.TestRoutes.SHORT_ROUTE

        val request = """
        {
          "locations": [
            {"lat": ${origin.lat}, "lon": ${origin.lon}},
            {"lat": ${dest.lat}, "lon": ${dest.lon}}
          ],
          "costing": "auto",
          "units": "kilometers"
        }
        """

        val result = actor.route(request)
        assertNotNull(result)

        val json = JSONObject(result)
        assertTrue(json.has("trip"))

        val trip = json.getJSONObject("trip")
        val summary = trip.getJSONObject("summary")
        val distanceKm = summary.getDouble("length")
        val timeMin = summary.getInt("time") / 60.0

        assertTrue(distanceKm < 5.0, "Short route should be < 5km, got $distanceKm km")
        println("  Distance: %.2f km, Time: %.1f min".format(distanceKm, timeMin))
    }

    @Test
    @Order(3)
    fun `test 03 - Medium Route - Orchard to Changi Airport`() = runTest("Medium Route") {
        println("\nTest 3: Medium Route - Orchard Road to Changi Airport")

        val (origin, dest) = SingaporeLocations.TestRoutes.MEDIUM_ROUTE

        val request = """
        {
          "locations": [
            {"lat": ${origin.lat}, "lon": ${origin.lon}},
            {"lat": ${dest.lat}, "lon": ${dest.lon}}
          ],
          "costing": "auto",
          "units": "kilometers"
        }
        """

        val result = actor.route(request)
        val json = JSONObject(result)
        val summary = json.getJSONObject("trip").getJSONObject("summary")
        val distanceKm = summary.getDouble("length")
        val timeMin = summary.getInt("time") / 60.0

        assertTrue(distanceKm in 5.0..25.0, "Medium route should be 5-25km, got $distanceKm km")
        println("  Distance: %.2f km, Time: %.1f min".format(distanceKm, timeMin))
    }

    @Test
    @Order(4)
    fun `test 04 - Long Route - Singapore Zoo to Sentosa`() = runTest("Long Route") {
        println("\nTest 4: Long Route - Singapore Zoo to Sentosa")

        val (origin, dest) = SingaporeLocations.TestRoutes.LONG_ROUTE

        val request = """
        {
          "locations": [
            {"lat": ${origin.lat}, "lon": ${origin.lon}},
            {"lat": ${dest.lat}, "lon": ${dest.lon}}
          ],
          "costing": "auto",
          "units": "kilometers"
        }
        """

        val result = actor.route(request)
        val json = JSONObject(result)
        val summary = json.getJSONObject("trip").getJSONObject("summary")
        val distanceKm = summary.getDouble("length")
        val timeMin = summary.getInt("time") / 60.0

        assertTrue(distanceKm > 15.0, "Long route should be > 15km, got $distanceKm km")
        println("  Distance: %.2f km, Time: %.1f min".format(distanceKm, timeMin))
    }

    @Test
    @Order(5)
    fun `test 05 - Expressway Route - Jurong East to Changi Airport`() = runTest("Expressway Route") {
        println("\nTest 5: Expressway Route - Jurong East to Changi Airport")

        val (origin, dest) = SingaporeLocations.TestRoutes.EXPRESSWAY_ROUTE

        val request = """
        {
          "locations": [
            {"lat": ${origin.lat}, "lon": ${origin.lon}},
            {"lat": ${dest.lat}, "lon": ${dest.lon}}
          ],
          "costing": "auto",
          "costing_options": {
            "auto": {
              "use_highways": 1.0
            }
          },
          "units": "kilometers"
        }
        """

        val result = actor.route(request)
        val json = JSONObject(result)
        val summary = json.getJSONObject("trip").getJSONObject("summary")
        val distanceKm = summary.getDouble("length")
        val timeMin = summary.getInt("time") / 60.0

        assertTrue(distanceKm > 20.0, "Cross-island route should be > 20km")
        println("  Distance: %.2f km, Time: %.1f min".format(distanceKm, timeMin))
    }

    @Test
    @Order(6)
    fun `test 06 - Multi-Waypoint Optimization (TSP)`() = runTest("Multi-Waypoint") {
        println("\nTest 6: Multi-Waypoint Route Optimization")

        val waypoints = SingaporeLocations.getMultiWaypoints()
        println("  Optimizing ${waypoints.size} waypoints")

        val locationsJson = waypoints.joinToString(",") {
            """{"lat": ${it.lat}, "lon": ${it.lon}}"""
        }

        val request = """
        {
          "locations": [$locationsJson],
          "costing": "auto",
          "units": "kilometers"
        }
        """

        val result = actor.optimizedRoute(request)
        val json = JSONObject(result)
        val summary = json.getJSONObject("trip").getJSONObject("summary")
        val distanceKm = summary.getDouble("length")

        assertTrue(distanceKm > 0, "Optimized route should have distance")
        println("  Optimized total distance: %.2f km".format(distanceKm))
    }

    @Test
    @Order(7)
    fun `test 07 - Driver Dispatch (Matrix API)`() = runTest("Driver Dispatch") {
        println("\nTest 7: Find Closest Drivers (Matrix API)")

        val pickup = SingaporeLocations.ORCHARD_ROAD
        val drivers = SingaporeLocations.getDriverLocations(5)
        println("  Pickup: ${pickup.name}")
        println("  Testing with ${drivers.size} driver locations")

        val targetsJson = drivers.joinToString(",") {
            """{"lat": ${it.lat}, "lon": ${it.lon}}"""
        }

        val request = """
        {
          "sources": [{"lat": ${pickup.lat}, "lon": ${pickup.lon}}],
          "targets": [$targetsJson],
          "costing": "auto"
        }
        """

        val result = actor.matrix(request)
        val json = JSONObject(result)
        assertTrue(json.has("sources_to_targets"))

        val matrix = json.getJSONArray("sources_to_targets")
        assertTrue(matrix.length() > 0, "Should return driver distances")

        // Matrix is 2D array: sources_to_targets[source_index][target_index]
        val sourceRow = matrix.getJSONArray(0)  // First (and only) source
        println("  Found ${sourceRow.length()} driver ETAs")

        // Find closest driver
        var minTime = Double.MAX_VALUE
        var closestIdx = -1
        for (i in 0 until sourceRow.length()) {
            val target = sourceRow.getJSONObject(i)
            val time = target.getDouble("time")
            if (time < minTime) {
                minTime = time
                closestIdx = i
            }
        }

        if (closestIdx >= 0) {
            val closestDriver = drivers[closestIdx]
            println("  Closest driver: ${closestDriver.name} (${minTime.toInt()}s)")
        }
    }

    @Test
    @Order(8)
    fun `test 08 - Motorcycle Route`() = runTest("Motorcycle Route") {
        println("\nTest 8: Motorcycle Routing")

        val (origin, dest) = SingaporeLocations.TestRoutes.MEDIUM_ROUTE

        val request = """
        {
          "locations": [
            {"lat": ${origin.lat}, "lon": ${origin.lon}},
            {"lat": ${dest.lat}, "lon": ${dest.lon}}
          ],
          "costing": "motorcycle",
          "units": "kilometers"
        }
        """

        val result = actor.route(request)
        val json = JSONObject(result)
        val summary = json.getJSONObject("trip").getJSONObject("summary")
        val distanceKm = summary.getDouble("length")
        val timeMin = summary.getInt("time") / 60.0

        assertTrue(distanceKm > 0, "Motorcycle route should have distance")
        println("  Distance: %.2f km, Time: %.1f min".format(distanceKm, timeMin))
    }

    @Test
    @Order(9)
    fun `test 09 - Isochrone (Reachability)`() = runTest("Isochrone") {
        println("\nTest 9: Isochrone - 15 minute reachability from Raffles Place")

        val location = SingaporeLocations.RAFFLES_PLACE

        val request = """
        {
          "locations": [{"lat": ${location.lat}, "lon": ${location.lon}}],
          "costing": "auto",
          "contours": [{"time": 15}],
          "polygons": true
        }
        """

        val result = actor.isochrone(request)
        assertNotNull(result)
        assertTrue(result.contains("features") || result.contains("geometry"))
        println("  Isochrone generated successfully")
    }

    @Test
    @Order(10)
    fun `test 10 - Locate API (Snap to Road)`() = runTest("Locate API") {
        println("\nTest 10: Locate API - Snap coordinates to road")

        val location = SingaporeLocations.MARINA_BAY_SANDS

        val request = """
        {
          "locations": [{"lat": ${location.lat}, "lon": ${location.lon}}],
          "costing": "auto",
          "verbose": true
        }
        """

        val result = actor.locate(request)
        // Locate API returns an array of location results
        assertTrue(result.isNotEmpty(), "Should return locate result")

        // Try to parse as either JSONObject or JSONArray
        val hasValidResult = try {
            val json = JSONObject(result)
            json.has("edges") || json.has("locations")
        } catch (e: Exception) {
            // If not an object, try as array
            try {
                val arr = org.json.JSONArray(result)
                arr.length() > 0
            } catch (e2: Exception) {
                false
            }
        }
        assertTrue(hasValidResult, "Should return valid locate result")
        println("  Location snapped to road network")
    }

    @Test
    @Order(11)
    fun `test 11 - Performance Benchmark`() = runTest("Performance Benchmark") {
        println("\nTest 11: Performance Benchmark - 100 route requests")

        val (origin, dest) = SingaporeLocations.TestRoutes.SHORT_ROUTE
        val request = """
        {
          "locations": [
            {"lat": ${origin.lat}, "lon": ${origin.lon}},
            {"lat": ${dest.lat}, "lon": ${dest.lon}}
          ],
          "costing": "auto"
        }
        """

        val iterations = 100
        val times = mutableListOf<Long>()

        for (i in 1..iterations) {
            val start = System.nanoTime()
            actor.route(request)
            val duration = (System.nanoTime() - start) / 1_000_000 // Convert to ms
            times.add(duration)
        }

        val avgTime = times.average()
        val p95Time = times.sorted()[times.size * 95 / 100]
        val minTime = times.minOrNull() ?: 0
        val maxTime = times.maxOrNull() ?: 0

        println("  Iterations: $iterations")
        println("  Average:    %.2f ms".format(avgTime))
        println("  P95:        $p95Time ms")
        println("  Min:        $minTime ms")
        println("  Max:        $maxTime ms")

        assertTrue(avgTime < 50.0, "Average latency should be < 50ms, got $avgTime ms")
    }
}
