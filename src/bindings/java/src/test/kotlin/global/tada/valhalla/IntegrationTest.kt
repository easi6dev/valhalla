package global.tada.valhalla

import global.tada.valhalla.config.RegionConfigFactory
import global.tada.valhalla.config.RegionConfigValidator
import global.tada.valhalla.helpers.RouteRequest
import org.junit.jupiter.api.*
import org.junit.jupiter.api.Assertions.*
import org.slf4j.LoggerFactory

/**
 * Integration Tests for Valhalla JNI Bindings
 *
 * Phase 5: Testing & Monitoring
 *
 * Tests:
 * - End-to-end routing workflow
 * - Multi-region support
 * - Configuration validation
 * - Error handling
 * - Resource cleanup
 */
@TestInstance(TestInstance.Lifecycle.PER_CLASS)
class IntegrationTest {

    private val logger = LoggerFactory.getLogger(IntegrationTest::class.java)

    @Test
    @Tag("integration")
    fun testEndToEndRoutingWorkflow() {
        logger.info("Testing end-to-end routing workflow")

        // Step 1: Validate configuration
        val validation = RegionConfigValidator.validate(
            regionsFile = "config/regions/regions-dev.json",
            validateTiles = false
        )

        if (validation.hasErrors()) {
            logger.warn("Configuration validation has errors: $validation")
        } else {
            logger.info("Configuration validation passed")
        }

        // Step 2: Initialize actor
        val actor = Actor.createWithExternalTiles("singapore")
        logger.info("Actor initialized successfully")

        try {
            // Step 3: Create route request
            val request = RouteRequest(
                locations = listOf(
                    RouteRequest.Location(1.290270, 103.851959), // Marina Bay
                    RouteRequest.Location(1.352083, 103.819836)  // Woodlands
                ),
                costing = "auto"
            )

            logger.info("Route request created")

            // Step 4: Calculate route
            val response = actor.route(request.toJson())
            logger.info("Route calculated successfully")

            // Step 5: Validate response
            assertNotNull(response, "Response should not be null")
            assertTrue(response.isNotEmpty(), "Response should not be empty")

            // Parse response (assuming JSON format)
            logger.info("Response length: ${response.length} characters")

            // Step 6: Verify route contains expected data
            assertTrue(response.contains("trip"), "Response should contain 'trip' field")

            logger.info("End-to-end workflow test passed")
        } finally {
            // Step 7: Cleanup
            actor.close()
            logger.info("Actor closed successfully")
        }
    }

    @Test
    @Tag("integration")
    fun testMultiRegionSupport() {
        logger.info("Testing multi-region support")

        val regions = listOf("singapore")  // Add more regions when available

        regions.forEach { region ->
            logger.info("Testing region: $region")

            // Check if region is supported
            val isSupported = RegionConfigFactory.isSupported(
                region,
                "config/regions/regions-dev.json"
            )

            assertTrue(isSupported, "Region $region should be supported")

            // Get region info
            val regionInfo = RegionConfigFactory.getRegionInfo(
                region,
                "config/regions/regions-dev.json"
            )

            logger.info("Region info for $region:")
            logger.info("  Name: ${regionInfo["name"]}")
            logger.info("  Timezone: ${regionInfo["timezone"]}")
            logger.info("  Locale: ${regionInfo["locale"]}")
            logger.info("  Currency: ${regionInfo["currency"]}")

            // Initialize actor for this region
            val actor = Actor.createWithExternalTiles(region)

            try {
                // Test route in this region
                val bounds = regionInfo["bounds"] as Map<*, *>
                val minLat = bounds["min_lat"] as Double
                val maxLat = bounds["max_lat"] as Double
                val minLon = bounds["min_lon"] as Double
                val maxLon = bounds["max_lon"] as Double

                // Create a simple route within bounds
                val centerLat = (minLat + maxLat) / 2
                val centerLon = (minLon + maxLon) / 2

                val request = RouteRequest(
                    locations = listOf(
                        RouteRequest.Location(centerLat, centerLon),
                        RouteRequest.Location(centerLat + 0.01, centerLon + 0.01)
                    ),
                    costing = "auto"
                )

                val response = actor.route(request.toJson())
                assertNotNull(response)
                assertTrue(response.isNotEmpty())

                logger.info("Route calculation successful for $region")
            } finally {
                actor.close()
            }
        }

        logger.info("Multi-region support test passed")
    }

    @Test
    @Tag("integration")
    fun testConfigurationValidation() {
        logger.info("Testing configuration validation")

        // Test valid configuration
        val validResult = RegionConfigValidator.validate(
            regionsFile = "config/regions/regions-dev.json",
            validateTiles = false
        )

        logger.info("Valid configuration result:")
        logger.info(validResult.toString())

        assertFalse(validResult.hasErrors(), "Valid configuration should not have errors")

        // Test invalid configuration (file not found)
        assertThrows<IllegalArgumentException> {
            RegionConfigValidator.validate(
                regionsFile = "config/regions/non-existent.json",
                validateTiles = false
            )
        }

        logger.info("Configuration validation test passed")
    }

    @Test
    @Tag("integration")
    fun testErrorHandling() {
        logger.info("Testing error handling")

        val actor = Actor.createWithExternalTiles("singapore")

        try {
            // Test 1: Invalid location (out of bounds)
            logger.info("Test 1: Invalid location")
            assertThrows<Exception> {
                val request = RouteRequest(
                    locations = listOf(
                        RouteRequest.Location(999.0, 999.0),
                        RouteRequest.Location(1.352083, 103.819836)
                    ),
                    costing = "auto"
                )
                actor.route(request.toJson())
            }
            logger.info("Test 1 passed: Invalid location throws exception")

            // Test 2: Invalid costing
            logger.info("Test 2: Invalid costing")
            assertThrows<Exception> {
                val request = RouteRequest(
                    locations = listOf(
                        RouteRequest.Location(1.290270, 103.851959),
                        RouteRequest.Location(1.352083, 103.819836)
                    ),
                    costing = "invalid_costing"
                )
                actor.route(request.toJson())
            }
            logger.info("Test 2 passed: Invalid costing throws exception")

            // Test 3: Too few locations
            logger.info("Test 3: Too few locations")
            assertThrows<Exception> {
                val request = RouteRequest(
                    locations = listOf(
                        RouteRequest.Location(1.290270, 103.851959)
                    ),
                    costing = "auto"
                )
                actor.route(request.toJson())
            }
            logger.info("Test 3 passed: Too few locations throws exception")

        } finally {
            actor.close()
        }

        logger.info("Error handling test passed")
    }

    @Test
    @Tag("integration")
    fun testResourceCleanup() {
        logger.info("Testing resource cleanup")

        // Test 1: Multiple actor instances
        logger.info("Test 1: Multiple actor instances")
        val actors = mutableListOf<Actor>()

        repeat(5) { i ->
            val actor = Actor.createWithExternalTiles("singapore")
            actors.add(actor)
            logger.info("Created actor $i")
        }

        actors.forEach { actor ->
            actor.close()
        }
        logger.info("All actors closed successfully")

        // Test 2: Actor reuse after close
        logger.info("Test 2: Actor reuse after close")
        val actor = Actor.createWithExternalTiles("singapore")

        val request = RouteRequest(
            locations = listOf(
                RouteRequest.Location(1.290270, 103.851959),
                RouteRequest.Location(1.352083, 103.819836)
            ),
            costing = "auto"
        )

        // Use actor
        val response1 = actor.route(request.toJson())
        assertNotNull(response1)

        // Close actor
        actor.close()

        // Attempt to use closed actor (should fail)
        assertThrows<IllegalStateException> {
            actor.route(request.toJson())
        }
        logger.info("Closed actor correctly throws exception on reuse")

        logger.info("Resource cleanup test passed")
    }

    @Test
    @Tag("integration")
    fun testDifferentCostingOptions() {
        logger.info("Testing different costing options")

        val actor = Actor.createWithExternalTiles("singapore")

        try {
            val locations = listOf(
                RouteRequest.Location(1.290270, 103.851959),
                RouteRequest.Location(1.352083, 103.819836)
            )

            val costings = listOf("auto", "taxi", "motorcycle")

            costings.forEach { costing ->
                logger.info("Testing costing: $costing")

                val request = RouteRequest(
                    locations = locations,
                    costing = costing
                )

                val response = actor.route(request.toJson())
                assertNotNull(response, "Response for $costing should not be null")
                assertTrue(response.isNotEmpty(), "Response for $costing should not be empty")

                logger.info("Costing $costing: OK")
            }

        } finally {
            actor.close()
        }

        logger.info("Different costing options test passed")
    }

    @Test
    @Tag("integration")
    @Tag("slow")
    fun testLongRunningStability() {
        logger.info("Testing long-running stability (5 minutes)")

        val actor = Actor.createWithExternalTiles("singapore")
        val durationMs = 5 * 60 * 1000L // 5 minutes
        val startTime = System.currentTimeMillis()
        var requestCount = 0

        try {
            while (System.currentTimeMillis() - startTime < durationMs) {
                val request = RouteRequest(
                    locations = listOf(
                        RouteRequest.Location(1.290270, 103.851959),
                        RouteRequest.Location(1.352083, 103.819836)
                    ),
                    costing = "auto"
                )

                val response = actor.route(request.toJson())
                assertNotNull(response)

                requestCount++

                // Log progress every 100 requests
                if (requestCount % 100 == 0) {
                    val elapsed = (System.currentTimeMillis() - startTime) / 1000
                    val rate = requestCount.toDouble() / elapsed
                    logger.info("Progress: $requestCount requests in ${elapsed}s (${"%.2f".format(rate)} req/s)")
                }

                // Small delay to simulate realistic usage
                Thread.sleep(10)
            }

            val totalTime = (System.currentTimeMillis() - startTime) / 1000
            val avgRate = requestCount.toDouble() / totalTime

            logger.info("Long-running stability test completed:")
            logger.info("  Duration: ${totalTime}s")
            logger.info("  Total requests: $requestCount")
            logger.info("  Average rate: ${"%.2f".format(avgRate)} req/s")

        } finally {
            actor.close()
        }

        logger.info("Long-running stability test passed")
    }
}
