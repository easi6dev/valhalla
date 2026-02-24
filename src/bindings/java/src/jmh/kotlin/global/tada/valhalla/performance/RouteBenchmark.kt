package global.tada.valhalla.performance

import global.tada.valhalla.Actor
import global.tada.valhalla.helpers.RouteRequest
import org.openjdk.jmh.annotations.*
import org.openjdk.jmh.infra.Blackhole
import java.util.concurrent.TimeUnit

/**
 * JMH Performance Benchmarks for Valhalla JNI Bindings
 *
 * Phase 5: Testing & Monitoring
 *
 * Benchmarks:
 * - Simple route calculation (2 points)
 * - Complex route calculation (5 waypoints)
 * - Multi-region routing
 * - Concurrent routing (thread safety)
 *
 * Run: ./gradlew jmh
 * Results: build/reports/jmh/results.json
 */
@State(Scope.Benchmark)
@BenchmarkMode(Mode.AverageTime)
@OutputTimeUnit(TimeUnit.MILLISECONDS)
@Warmup(iterations = 3, time = 1, timeUnit = TimeUnit.SECONDS)
@Measurement(iterations = 5, time = 2, timeUnit = TimeUnit.SECONDS)
@Fork(1)
@Threads(1)
open class RouteBenchmark {

    private lateinit var actor: Actor

    // Test locations in Singapore
    private val marinaBay = RouteRequest.Location(1.290270, 103.851959)
    private val woodlands = RouteRequest.Location(1.352083, 103.819836)
    private val changiAirport = RouteRequest.Location(1.350189, 103.994003)
    private val sentosa = RouteRequest.Location(1.249372, 103.830659)
    private val jurongEast = RouteRequest.Location(1.333039, 103.742188)

    @Setup(Level.Trial)
    fun setup() {
        // Initialize actor once for all benchmarks
        actor = Actor.createWithExternalTiles("singapore")

        // Warmup: ensure tiles are loaded
        val warmupRequest = RouteRequest(
            locations = listOf(marinaBay, woodlands),
            costing = "auto"
        )
        actor.route(warmupRequest)
    }

    @TearDown(Level.Trial)
    fun teardown() {
        actor.close()
    }

    /**
     * Benchmark: Simple route (2 points)
     * Expected: ~15-20ms
     */
    @Benchmark
    fun benchmarkSimpleRoute(blackhole: Blackhole) {
        val request = RouteRequest(
            locations = listOf(marinaBay, woodlands),
            costing = "auto"
        )
        val result = actor.route(request.toJson())
        blackhole.consume(result)
    }

    /**
     * Benchmark: Medium route (3 points)
     * Expected: ~25-35ms
     */
    @Benchmark
    fun benchmarkMediumRoute(blackhole: Blackhole) {
        val request = RouteRequest(
            locations = listOf(marinaBay, changiAirport, woodlands),
            costing = "auto"
        )
        val result = actor.route(request.toJson())
        blackhole.consume(result)
    }

    /**
     * Benchmark: Complex route (5 waypoints)
     * Expected: ~50-80ms
     */
    @Benchmark
    fun benchmarkComplexRoute(blackhole: Blackhole) {
        val request = RouteRequest(
            locations = listOf(
                marinaBay,
                sentosa,
                jurongEast,
                changiAirport,
                woodlands
            ),
            costing = "auto"
        )
        val result = actor.route(request.toJson())
        blackhole.consume(result)
    }

    /**
     * Benchmark: Different costing (taxi)
     * Expected: ~15-20ms (similar to auto)
     */
    @Benchmark
    fun benchmarkTaxiCosting(blackhole: Blackhole) {
        val request = RouteRequest(
            locations = listOf(marinaBay, woodlands),
            costing = "taxi"
        )
        val result = actor.route(request.toJson())
        blackhole.consume(result)
    }

    /**
     * Benchmark: Motorcycle costing
     * Expected: ~15-20ms
     */
    @Benchmark
    fun benchmarkMotorcycleCosting(blackhole: Blackhole) {
        val request = RouteRequest(
            locations = listOf(marinaBay, woodlands),
            costing = "motorcycle"
        )
        val result = actor.route(request.toJson())
        blackhole.consume(result)
    }
}

/**
 * Concurrent routing benchmark (thread safety test)
 */
@State(Scope.Benchmark)
@BenchmarkMode(Mode.Throughput)
@OutputTimeUnit(TimeUnit.SECONDS)
@Warmup(iterations = 3, time = 1, timeUnit = TimeUnit.SECONDS)
@Measurement(iterations = 5, time = 2, timeUnit = TimeUnit.SECONDS)
@Fork(1)
@Threads(8)  // 8 concurrent threads
open class ConcurrentRouteBenchmark {

    @State(Scope.Thread)
    open class ThreadState {
        lateinit var actor: Actor

        @Setup(Level.Trial)
        fun setup() {
            actor = Actor.createWithExternalTiles("singapore")
        }

        @TearDown(Level.Trial)
        fun teardown() {
            actor.close()
        }
    }

    /**
     * Benchmark: Concurrent routing (8 threads)
     * Expected: ~400-800 routes/sec total throughput
     */
    @Benchmark
    fun benchmarkConcurrentRouting(state: ThreadState, blackhole: Blackhole) {
        val request = RouteRequest(
            locations = listOf(
                RouteRequest.Location(1.290270, 103.851959),
                RouteRequest.Location(1.352083, 103.819836)
            ),
            costing = "auto"
        )
        val result = state.actor.route(request.toJson())
        blackhole.consume(result)
    }
}

/**
 * Actor initialization benchmark
 */
@State(Scope.Benchmark)
@BenchmarkMode(Mode.AverageTime)
@OutputTimeUnit(TimeUnit.MILLISECONDS)
@Warmup(iterations = 2, time = 1, timeUnit = TimeUnit.SECONDS)
@Measurement(iterations = 3, time = 1, timeUnit = TimeUnit.SECONDS)
@Fork(1)
open class ActorInitializationBenchmark {

    /**
     * Benchmark: Actor initialization (tile loading)
     * Expected: ~150-250ms (one-time cost)
     */
    @Benchmark
    fun benchmarkActorInitialization(blackhole: Blackhole) {
        val actor = Actor.createWithExternalTiles("singapore")
        blackhole.consume(actor)
        actor.close()
    }
}
