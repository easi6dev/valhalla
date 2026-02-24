package global.tada.valhalla.test

import global.tada.valhalla.Actor
import global.tada.valhalla.config.RegionConfigFactory
import org.json.JSONObject
import org.junit.jupiter.api.*
import org.junit.jupiter.api.Assertions.*
import java.io.File

/**
 * Base test class for region-specific ride-hailing scenarios
 *
 * This abstract class provides common test infrastructure for all regions.
 * Each region should extend this class and provide region-specific test data.
 *
 * ## Usage
 * ```kotlin
 * @TestInstance(TestInstance.Lifecycle.PER_CLASS)
 * @TestMethodOrder(MethodOrderer.OrderAnnotation::class)
 * class SingaporeRideHaulingTest : RegionRideHaulingTest(
 *     regionName = "singapore",
 *     tileDir = "../../../data/valhalla_tiles/singapore"
 * ) {
 *     // Region-specific tests here
 * }
 * ```
 */
@TestInstance(TestInstance.Lifecycle.PER_CLASS)
@TestMethodOrder(MethodOrderer.OrderAnnotation::class)
abstract class RegionRideHaulingTest(
    protected val regionName: String,
    protected val tileDir: String
) {

    protected lateinit var actor: Actor
    protected val testResults = mutableListOf<TestResult>()

    data class TestResult(
        val testName: String,
        val passed: Boolean,
        val durationMs: Long,
        val details: String
    )

    @BeforeAll
    fun setup() {
        val regionCapitalized = regionName.replaceFirstChar { it.uppercase() }

        println("=".repeat(80))
        println("$regionCapitalized Ride-Hailing Test Suite - JNI Bindings")
        println("=".repeat(80))

        // Check if tiles exist
        val tileDirFile = File(tileDir)
        if (!tileDirFile.exists() || !tileDirFile.isDirectory) {
            throw IllegalStateException(
                """
                $regionCapitalized tiles not found!
                Please build tiles first:
                  cd ${System.getProperty("user.dir")}
                  ./scripts/regions/download-region-osm.sh $regionName
                  ./scripts/regions/build-tiles.sh $regionName
                """.trimIndent()
            )
        }

        // Check tile count
        val tileCount = tileDirFile.walkTopDown()
            .filter { it.extension == "gph" }
            .count()

        if (tileCount == 0) {
            throw IllegalStateException("No tile files found in $tileDir")
        }

        println("checkmark Found $tileCount tile files")

        // Use absolute path
        val absoluteTileDir = File(tileDir).canonicalPath

        println("checkmark Using tile directory: $absoluteTileDir")

        // Create actor using the helper method
        try {
            actor = Actor.createForRegion(regionName, absoluteTileDir)
            println("checkmark Valhalla Actor created successfully for $regionCapitalized")
        } catch (e: Exception) {
            throw IllegalStateException("Failed to create Actor: ${e.message}", e)
        }

        // Display region information
        val regionInfo = RegionConfigFactory.getRegionInfo(regionName)
        println("checkmark Region: ${regionInfo["name"]}")
        println("checkmark Timezone: ${regionInfo["timezone"]}")
        println("checkmark Currency: ${regionInfo["currency"]}")

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

    /**
     * Helper function to run a test and record results
     */
    protected fun runTest(testName: String, testBlock: () -> Unit) {
        println("-".repeat(80))
        println("TEST: $testName")
        println("-".repeat(80))

        val startTime = System.currentTimeMillis()
        var passed = false
        var details = ""

        try {
            testBlock()
            passed = true
            details = "Success"
        } catch (e: Exception) {
            passed = false
            details = "Failed: ${e.message}"
            throw e
        } finally {
            val duration = System.currentTimeMillis() - startTime
            testResults.add(TestResult(testName, passed, duration, details))

            if (passed) {
                println("checkmark PASSED in ${duration}ms")
            } else {
                println("x FAILED in ${duration}ms")
            }
            println("")
        }
    }

    /**
     * Helper function to validate a route response
     */
    protected fun validateRouteResponse(
        response: String,
        minDistanceKm: Double? = null,
        maxDistanceKm: Double? = null,
        minDurationMin: Double? = null,
        maxDurationMin: Double? = null
    ) {
        val json = JSONObject(response)

        // Check for errors
        assertFalse(json.has("error"), "Response contains error: ${json.optString("error")}")

        // Validate trip structure
        assertTrue(json.has("trip"), "Response missing 'trip' field")
        val trip = json.getJSONObject("trip")

        assertTrue(trip.has("summary"), "Trip missing 'summary' field")
        val summary = trip.getJSONObject("summary")

        // Validate distance
        assertTrue(summary.has("length"), "Summary missing 'length' field")
        val distanceKm = summary.getDouble("length")
        assertTrue(distanceKm > 0, "Distance should be positive")

        minDistanceKm?.let {
            assertTrue(distanceKm >= it, "Distance $distanceKm km is less than minimum $it km")
        }
        maxDistanceKm?.let {
            assertTrue(distanceKm <= it, "Distance $distanceKm km exceeds maximum $it km")
        }

        // Validate time
        assertTrue(summary.has("time"), "Summary missing 'time' field")
        val durationSec = summary.getDouble("time")
        val durationMin = durationSec / 60.0
        assertTrue(durationSec > 0, "Duration should be positive")

        minDurationMin?.let {
            assertTrue(durationMin >= it, "Duration $durationMin min is less than minimum $it min")
        }
        maxDurationMin?.let {
            assertTrue(durationMin <= it, "Duration $durationMin min exceeds maximum $it min")
        }

        // Validate legs
        assertTrue(trip.has("legs"), "Trip missing 'legs' field")
        val legs = trip.getJSONArray("legs")
        assertTrue(legs.length() > 0, "Trip should have at least one leg")

        println("  checkmark Distance: %.2f km".format(distanceKm))
        println("  checkmark Duration: %.2f min (%.0f sec)".format(durationMin, durationSec))
        println("  checkmark Legs: ${legs.length()}")
    }

    /**
     * Helper function to create a route request JSON
     */
    protected fun createRouteRequest(
        locations: List<Pair<Double, Double>>,
        costing: String = "auto",
        costingOptions: Map<String, Any>? = null
    ): String {
        val locationsArray = locations.map { (lat, lon) ->
            "{\"lat\": $lat, \"lon\": $lon}"
        }.joinToString(",")

        val costingOptionsJson = costingOptions?.let { options ->
            val optionsJson = options.entries.joinToString(",") { (key, value) ->
                val valueStr = when (value) {
                    is String -> "\"$value\""
                    else -> value.toString()
                }
                "\"$key\": $valueStr"
            }
            ", \"costing_options\": {\"$costing\": {$optionsJson}}"
        } ?: ""

        return """
        {
          "locations": [$locationsArray],
          "costing": "$costing"
          $costingOptionsJson
        }
        """.trimIndent()
    }

    /**
     * Test 01: Service Status Check (common to all regions)
     */
    @Test
    @Order(1)
    fun `test 01 - Service Status Check`() = runTest("Service Status Check") {
        val statusRequest = "{\"action\": \"status\"}"
        val response = actor.status(statusRequest)

        val json = JSONObject(response)
        assertTrue(json.has("version"), "Status response should include version")

        println("  checkmark Valhalla version: ${json.getString("version")}")
        println("  checkmark Service is operational")
    }
}
