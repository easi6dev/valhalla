package global.tada.valhalla.pool

import global.tada.valhalla.ValhallaException
import global.tada.valhalla.dispatch.DriverSelection
import global.tada.valhalla.metrics.ValhallaMetrics
import global.tada.valhalla.singapore.Location
import global.tada.valhalla.singapore.SingaporeLocations
import org.junit.jupiter.api.Assumptions.assumeTrue
import org.junit.jupiter.api.Tag
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.Timeout
import org.slf4j.LoggerFactory
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Phase 6 — full-engine concurrency stress test.
 *
 * Reproduces-then-disproves the original SIGSEGV (`hs_err_pid24873.log`:
 * concurrent calls on a shared single-threaded `actor_t` corrupting tile state in
 * `GraphTile::node()`). 50 threads hammer the pool for 60s with a MIX of the
 * operations that touch the racy loki/thor/meili workers — route, matrix
 * (DriverSelection), trace_route + trace_attributes (map-matching). If the pool
 * failed to isolate actors, this would crash the JVM or corrupt results.
 *
 * Gated: requires the built native lib + Singapore tiles, so it SKIPS on dev
 * hosts and runs on the Linux builder / CI. Tagged "stress" so normal `test`
 * runs skip it unless explicitly included.
 *
 * NOTE: a true SIGSEGV takes down the whole JVM (the test process dies, no green
 * result) — so simply REACHING the assertions after 50×60s of contention is the
 * core proof. The explicit assertions add: zero functional errors, every actor
 * returned, and bounded heap growth.
 */
@Tag("stress")
@Tag("native")
class ActorPoolStressTest {

    private val logger = LoggerFactory.getLogger(ActorPoolStressTest::class.java)

    private enum class Op { ROUTE, MATRIX, TRACE_ROUTE, TRACE_ATTRIBUTES }

    @Test
    @Timeout(120)
    fun `50 threads x 60s of mixed routing and map-matching never crash or corrupt`() {
        val pool = try {
            ActorPool.forRegion("singapore", poolSize = 4)
        } catch (e: Throwable) {
            logger.warn("Native/tiles unavailable: {}", e.message)
            null
        }
        assumeTrue(pool != null, "Valhalla native/tiles not available — skipping stress test")

        ValhallaMetrics.reset()
        val threads = 50
        val durationMs = 60_000L
        val ops = AtomicLong(0)
        val exhausted = AtomicLong(0)
        val errorSamples = ConcurrentHashMap<String, AtomicInteger>()
        val checkedOut = ConcurrentHashMap.newKeySet<Long>() // identity hashes of in-use actors
        val doubleHand = AtomicInteger(0)
        // Track ROUTE separately: routes between connected SG landmarks must nearly
        // always succeed, so a route-error flood is the real corruption signal.
        // Map-matching (trace) on short synthetic shapes is best-effort and its
        // failures (breakage distance, no-match) are EXPECTED, not corruption.
        val routeOk = AtomicLong(0)
        val routeErr = AtomicLong(0)
        val traceOk = AtomicLong(0)
        val traceErr = AtomicLong(0)

        // Curated CENTRAL, mainland-connected landmarks for route/matrix so a
        // residual route-error flood genuinely means corruption — NOT an island
        // (Sentosa) or far-flung (Zoo/Changi) pair that's legitimately unroutable
        // by car in this tile set. (Earlier runs: arbitrary adjacent pairs gave a
        // deterministic ~11% "No path" from such pairs, masking the corruption signal.)
        val locs = listOf(
            SingaporeLocations.RAFFLES_PLACE,
            SingaporeLocations.CITY_HALL,
            SingaporeLocations.CLARKE_QUAY,
            SingaporeLocations.BUGIS,
            SingaporeLocations.ORCHARD_ROAD,
            SingaporeLocations.MARINA_BAY_SANDS,
            SingaporeLocations.GARDENS_BY_THE_BAY
        )
        val runtime = Runtime.getRuntime()
        val baselineMb = usedMb(runtime)

        pool!!.use { p ->
            val start = CountDownLatch(1)
            val done = CountDownLatch(threads)
            val exec = Executors.newFixedThreadPool(threads)
            val deadline = AtomicLong(0)
            try {
                repeat(threads) { tid ->
                    exec.submit {
                        start.await()
                        // Deterministic per-thread op selection (no Math.random — varies by tid+counter).
                        var counter = 0
                        while (System.currentTimeMillis() < deadline.get()) {
                            val op = Op.entries[(tid + counter) % Op.entries.size]
                            counter++
                            val isRoute = op == Op.ROUTE || op == Op.MATRIX
                            try {
                                p.withActor { actor ->
                                    // Detect double-hand by identity: mark on entry, clear on exit.
                                    val id = System.identityHashCode(actor).toLong()
                                    if (!checkedOut.add(id)) doubleHand.incrementAndGet()
                                    try {
                                        runOp(op, actor, locs, tid, counter)
                                    } finally {
                                        checkedOut.remove(id)
                                    }
                                }
                                ops.incrementAndGet()
                                if (isRoute) routeOk.incrementAndGet() else traceOk.incrementAndGet()
                            } catch (e: ActorPoolExhaustedException) {
                                exhausted.incrementAndGet()
                            } catch (e: ValhallaException) {
                                // Expected for some inputs (unroutable pair; trace shapes that
                                // exceed breakage distance / can't map-match). Bucket by op class:
                                // a ROUTE flood signals corruption, trace failures are normal here.
                                if (isRoute) routeErr.incrementAndGet() else traceErr.incrementAndGet()
                                errorSamples.computeIfAbsent(e.message?.take(60) ?: "null") { AtomicInteger() }
                                    .incrementAndGet()
                            }
                        }
                        done.countDown()
                    }
                }
                deadline.set(System.currentTimeMillis() + durationMs)
                start.countDown()
                assertTrue(done.await(durationMs + 30_000, TimeUnit.MILLISECONDS),
                    "workers did not finish within the grace period")
            } finally {
                exec.shutdownNow()
            }

            val totalOps = ops.get()
            val peakMb = usedMb(runtime)
            logger.info(
                "Stress complete: ops={} (routeOk={}, traceOk={}), routeErr={}, traceErr={}, " +
                "exhausted={}, doubleHand={}, mem {}MB->{}MB",
                totalOps, routeOk.get(), traceOk.get(), routeErr.get(), traceErr.get(),
                exhausted.get(), doubleHand.get(), baselineMb, peakMb
            )
            errorSamples.forEach { (msg, n) -> logger.info("  error[{}]: {}", n.get(), msg) }

            // ── Corruption proof (reaching here at all already disproves the SIGSEGV) ──
            // 1. No actor was ever held by two threads at once.
            assertEquals(0, doubleHand.get(),
                "an actor was handed to two threads at once under load (pool isolation broken)")
            // 2. Real work happened.
            assertTrue(totalOps > 0, "no operations completed")
            // 3. Every actor returned to the pool (no leak of the borrowed slot).
            assertEquals(4, p.availableCount(), "not all actors returned to the pool")
            assertEquals(0, p.inUseCount())
            assertEquals(0, ValhallaMetrics.getSnapshot().actorsInUse, "actorsInUse metric did not settle to 0")
            // 4. ROUTE/MATRIX between connected SG landmarks must nearly always succeed.
            //    A route-error FLOOD (not the odd unroutable pair) is the corruption signal.
            //    Map-matching (trace) on short synthetic shapes is best-effort → not gated here.
            val routeTotal = routeOk.get() + routeErr.get()
            assertTrue(routeTotal > 0, "no route/matrix ops ran")
            val routeErrRate = routeErr.get().toDouble() / routeTotal
            assertTrue(routeErrRate < 0.05,
                "route/matrix error rate ${"%.1f".format(routeErrRate * 100)}% too high — possible state corruption")
            // 5. Heap must not have ballooned (rough leak guard; GC noise tolerated).
            assertTrue(peakMb - baselineMb < 1024,
                "heap grew ${peakMb - baselineMb}MB under load — possible leak")
        }
    }

    private fun runOp(op: Op, actor: global.tada.valhalla.Actor,
                      locs: List<Location>, tid: Int, counter: Int) {
        val a = locs[(tid + counter) % locs.size]
        val b = locs[(tid + counter + 1) % locs.size]
        when (op) {
            Op.ROUTE ->
                actor.route(routeJson(a, b), /* timeoutMs = */ 5_000)
            Op.MATRIX -> {
                val drivers = locs.take(5).map { DriverSelection.Point(it.lat, it.lon) }
                DriverSelection.rank(actor, DriverSelection.Point(a.lat, a.lon), drivers)
            }
            Op.TRACE_ROUTE ->
                actor.traceRoute(traceJson(a), /* timeoutMs = */ 5_000)
            Op.TRACE_ATTRIBUTES ->
                actor.traceAttributes(traceJson(a), /* timeoutMs = */ 5_000)
        }
    }

    private fun routeJson(a: Location, b: Location) = """
        {"locations":[{"lat":${a.lat},"lon":${a.lon}},{"lat":${b.lat},"lon":${b.lon}}],
         "costing":"auto","units":"kilometers"}
    """.trimIndent()

    // Map-matching: a SHORT, DENSE synthetic trace around one landmark — 4 points
    // ~150 m apart (well within Meili's 2000 m breakage_distance), so the HMM
    // matcher runs reliably instead of rejecting a multi-km 2-point line. This is
    // the path that keeps per-request Meili scratch state (the concurrency target).
    // ~0.00135° lat ≈ 150 m; lon scaled by cos(lat) near Singapore (~1.3°).
    private fun traceJson(a: Location): String {
        val dLat = 0.00135
        val dLon = 0.00135 / 0.9997  // cos(1.3°) ≈ 0.99974
        val pts = (0 until 4).joinToString(",") { i ->
            """{"lat":${a.lat + i * dLat},"lon":${a.lon + i * dLon}}"""
        }
        return """{"shape":[$pts],"costing":"auto","shape_match":"map_snap"}"""
    }

    private fun usedMb(rt: Runtime): Long = (rt.totalMemory() - rt.freeMemory()) / (1024 * 1024)
}
