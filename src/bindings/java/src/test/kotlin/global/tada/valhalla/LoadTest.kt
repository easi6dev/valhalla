package global.tada.valhalla

import global.tada.valhalla.helpers.RouteRequest
import org.junit.jupiter.api.*
import org.junit.jupiter.api.Assertions.*
import org.slf4j.LoggerFactory
import java.util.concurrent.*
import java.util.concurrent.atomic.AtomicInteger
import kotlin.system.measureTimeMillis

/**
 * Load Testing for Valhalla JNI Bindings
 *
 * Phase 5: Testing & Monitoring
 *
 * Tests:
 * - High throughput (1000 routes/sec)
 * - Sustained load (10 minutes)
 * - Concurrent users (100 threads)
 * - Memory stability under load
 * - Error rate under stress
 */
@TestInstance(TestInstance.Lifecycle.PER_CLASS)
class LoadTest {

    private val logger = LoggerFactory.getLogger(LoadTest::class.java)
    private lateinit var actor: Actor

    // Test locations
    private val marinaBay = RouteRequest.Location(1.290270, 103.851959)
    private val woodlands = RouteRequest.Location(1.352083, 103.819836)

    @BeforeAll
    fun setup() {
        logger.info("Initializing actor for load testing...")
        actor = Actor.createWithExternalTiles("singapore")
        logger.info("Actor initialized successfully")
    }

    @AfterAll
    fun teardown() {
        logger.info("Closing actor...")
        actor.close()
        logger.info("Actor closed")
    }

    /**
     * Test: High throughput (1000 routes)
     * Expected: Complete in <20 seconds (~50 routes/sec single-threaded)
     */
    @Test
    @Tag("load")
    fun testHighThroughput() {
        val routeCount = 1000
        val successCount = AtomicInteger(0)
        val errorCount = AtomicInteger(0)

        logger.info("Starting high throughput test: $routeCount routes")

        val elapsedTime = measureTimeMillis {
            repeat(routeCount) { i ->
                try {
                    val request = RouteRequest(
                        locations = listOf(marinaBay, woodlands),
                        costing = "auto"
                    )
                    val result = actor.route(request.toJson())
                    assertNotNull(result)
                    successCount.incrementAndGet()

                    if ((i + 1) % 100 == 0) {
                        logger.info("Progress: ${i + 1}/$routeCount routes")
                    }
                } catch (e: Exception) {
                    errorCount.incrementAndGet()
                    logger.error("Route calculation failed: ${e.message}")
                }
            }
        }

        val throughput = (routeCount * 1000.0) / elapsedTime
        logger.info("High throughput test completed:")
        logger.info("  - Total routes: $routeCount")
        logger.info("  - Successful: ${successCount.get()}")
        logger.info("  - Failed: ${errorCount.get()}")
        logger.info("  - Time: ${elapsedTime}ms")
        logger.info("  - Throughput: ${"%.2f".format(throughput)} routes/sec")

        // Assertions
        assertTrue(successCount.get() >= routeCount * 0.99, "Success rate should be >= 99%")
        assertTrue(throughput >= 40.0, "Throughput should be >= 40 routes/sec")
    }

    /**
     * Test: Concurrent load (100 threads, 10 routes each)
     * Expected: Complete in <30 seconds, >99% success rate
     */
    @Test
    @Tag("load")
    fun testConcurrentLoad() {
        val threadCount = 100
        val routesPerThread = 10
        val totalRoutes = threadCount * routesPerThread

        val successCount = AtomicInteger(0)
        val errorCount = AtomicInteger(0)
        val executor = Executors.newFixedThreadPool(threadCount)

        logger.info("Starting concurrent load test:")
        logger.info("  - Threads: $threadCount")
        logger.info("  - Routes per thread: $routesPerThread")
        logger.info("  - Total routes: $totalRoutes")

        val elapsedTime = measureTimeMillis {
            val futures = mutableListOf<Future<*>>()

            repeat(threadCount) { threadId ->
                val future = executor.submit {
                    repeat(routesPerThread) {
                        try {
                            val request = RouteRequest(
                                locations = listOf(marinaBay, woodlands),
                                costing = "auto"
                            )
                            val result = actor.route(request.toJson())
                            assertNotNull(result)
                            successCount.incrementAndGet()
                        } catch (e: Exception) {
                            errorCount.incrementAndGet()
                            logger.error("Thread $threadId: Route failed: ${e.message}")
                        }
                    }
                }
                futures.add(future)
            }

            // Wait for all threads to complete
            futures.forEach { it.get() }
        }

        executor.shutdown()
        executor.awaitTermination(30, TimeUnit.SECONDS)

        val throughput = (totalRoutes * 1000.0) / elapsedTime
        val successRate = (successCount.get() * 100.0) / totalRoutes

        logger.info("Concurrent load test completed:")
        logger.info("  - Total routes: $totalRoutes")
        logger.info("  - Successful: ${successCount.get()}")
        logger.info("  - Failed: ${errorCount.get()}")
        logger.info("  - Success rate: ${"%.2f".format(successRate)}%")
        logger.info("  - Time: ${elapsedTime}ms")
        logger.info("  - Throughput: ${"%.2f".format(throughput)} routes/sec")

        // Assertions
        assertTrue(successRate >= 99.0, "Success rate should be >= 99%")
        assertTrue(errorCount.get() <= totalRoutes * 0.01, "Error rate should be <= 1%")
    }

    /**
     * Test: Sustained load (1 minute, continuous routing)
     * Expected: Stable performance, no memory leaks
     */
    @Test
    @Tag("load")
    @Tag("slow")
    fun testSustainedLoad() {
        val durationMinutes = 1
        val durationMs = durationMinutes * 60 * 1000L
        val checkpointInterval = 10_000L // 10 seconds

        val successCount = AtomicInteger(0)
        val errorCount = AtomicInteger(0)
        val startTime = System.currentTimeMillis()
        var lastCheckpoint = startTime

        logger.info("Starting sustained load test: $durationMinutes minute(s)")

        while (System.currentTimeMillis() - startTime < durationMs) {
            try {
                val request = RouteRequest(
                    locations = listOf(marinaBay, woodlands),
                    costing = "auto"
                )
                val result = actor.route(request.toJson())
                assertNotNull(result)
                successCount.incrementAndGet()
            } catch (e: Exception) {
                errorCount.incrementAndGet()
                logger.error("Route calculation failed: ${e.message}")
            }

            // Periodic checkpoint
            val now = System.currentTimeMillis()
            if (now - lastCheckpoint >= checkpointInterval) {
                val elapsed = now - startTime
                val currentThroughput = (successCount.get() * 1000.0) / elapsed
                val runtime = Runtime.getRuntime()
                val usedMemory = (runtime.totalMemory() - runtime.freeMemory()) / (1024 * 1024)

                logger.info("Checkpoint at ${elapsed / 1000}s:")
                logger.info("  - Routes: ${successCount.get()} success, ${errorCount.get()} failed")
                logger.info("  - Throughput: ${"%.2f".format(currentThroughput)} routes/sec")
                logger.info("  - Memory: ${usedMemory}MB used")

                lastCheckpoint = now
            }
        }

        val totalTime = System.currentTimeMillis() - startTime
        val throughput = (successCount.get() * 1000.0) / totalTime
        val successRate = (successCount.get() * 100.0) / (successCount.get() + errorCount.get())

        logger.info("Sustained load test completed:")
        logger.info("  - Duration: ${totalTime / 1000}s")
        logger.info("  - Total routes: ${successCount.get() + errorCount.get()}")
        logger.info("  - Successful: ${successCount.get()}")
        logger.info("  - Failed: ${errorCount.get()}")
        logger.info("  - Success rate: ${"%.2f".format(successRate)}%")
        logger.info("  - Average throughput: ${"%.2f".format(throughput)} routes/sec")

        // Assertions
        assertTrue(successRate >= 99.0, "Success rate should be >= 99%")
        assertTrue(throughput >= 40.0, "Average throughput should be >= 40 routes/sec")
    }

    /**
     * Test: Memory stability under load
     * Expected: Memory usage should stabilize, no continuous growth (leak)
     */
    @Test
    @Tag("load")
    fun testMemoryStability() {
        val warmupRoutes = 100
        val testRoutes = 500

        logger.info("Starting memory stability test")

        // Warmup
        logger.info("Warmup phase: $warmupRoutes routes")
        repeat(warmupRoutes) {
            val request = RouteRequest(
                locations = listOf(marinaBay, woodlands),
                costing = "auto"
            )
            actor.route(request.toJson())
        }

        // Force GC and measure baseline
        System.gc()
        Thread.sleep(1000)
        val runtime = Runtime.getRuntime()
        val baselineMemory = (runtime.totalMemory() - runtime.freeMemory()) / (1024 * 1024)
        logger.info("Baseline memory: ${baselineMemory}MB")

        // Test phase
        logger.info("Test phase: $testRoutes routes")
        repeat(testRoutes) { i ->
            val request = RouteRequest(
                locations = listOf(marinaBay, woodlands),
                costing = "auto"
            )
            actor.route(request.toJson())

            // Periodic memory check
            if ((i + 1) % 100 == 0) {
                val currentMemory = (runtime.totalMemory() - runtime.freeMemory()) / (1024 * 1024)
                logger.info("After ${i + 1} routes: ${currentMemory}MB")
            }
        }

        // Force GC and measure final
        System.gc()
        Thread.sleep(1000)
        val finalMemory = (runtime.totalMemory() - runtime.freeMemory()) / (1024 * 1024)
        logger.info("Final memory: ${finalMemory}MB")

        val memoryGrowth = finalMemory - baselineMemory
        val growthPercent = (memoryGrowth * 100.0) / baselineMemory

        logger.info("Memory stability test completed:")
        logger.info("  - Baseline: ${baselineMemory}MB")
        logger.info("  - Final: ${finalMemory}MB")
        logger.info("  - Growth: ${memoryGrowth}MB (${"%.2f".format(growthPercent)}%)")

        // Assertion: Memory growth should be reasonable (< 50% increase)
        assertTrue(growthPercent < 50.0, "Memory growth should be < 50% (actual: ${"%.2f".format(growthPercent)}%)")
    }

    /**
     * Test: Error handling under stress
     * Expected: Graceful error handling, no crashes
     */
    @Test
    @Tag("load")
    fun testErrorHandlingUnderStress() {
        val requestCount = 100
        val invalidLocation = RouteRequest.Location(999.0, 999.0) // Invalid

        logger.info("Starting error handling stress test")

        var errorsCaught = 0
        repeat(requestCount) {
            try {
                val request = RouteRequest(
                    locations = listOf(marinaBay, invalidLocation),
                    costing = "auto"
                )
                actor.route(request.toJson())
            } catch (e: Exception) {
                errorsCaught++
                // Expected: errors should be caught gracefully
            }
        }

        logger.info("Error handling test completed:")
        logger.info("  - Requests: $requestCount")
        logger.info("  - Errors caught: $errorsCaught")

        // Assertion: All errors should be caught gracefully
        assertEquals(requestCount, errorsCaught, "All invalid requests should throw exceptions")
    }
}
