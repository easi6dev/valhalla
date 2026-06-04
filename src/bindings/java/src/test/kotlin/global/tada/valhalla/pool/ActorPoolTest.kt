package global.tada.valhalla.pool

import global.tada.valhalla.Actor
import global.tada.valhalla.helpers.RouteRequest
import global.tada.valhalla.metrics.ValhallaMetrics
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.Assumptions.assumeTrue
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.Timeout
import java.util.Collections
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * Tests for [ActorPool].
 *
 * The pool requires real native [Actor] instances (built JNI lib + tiles), which
 * are not present on every dev host. Tests that need live actors are gated with
 * [assumeTrue] and SKIP gracefully when the engine can't initialise — they run
 * for real in CI / on the Linux builder. This mirrors NewYorkRideHaulingTest.
 *
 * The concurrency guarantees verified here are the load-bearing correctness
 * property of the whole fix: a single-threaded native actor must never be handed
 * to two threads at once.
 */
class ActorPoolTest {

    private val region = "singapore"
    private val a = RouteRequest.Location(1.290270, 103.851959)
    private val b = RouteRequest.Location(1.352083, 103.819836)

    private fun tryBuildPool(poolSize: Int, borrowTimeoutMs: Long = 250L): ActorPool? =
        try {
            ActorPool.forRegion(region, poolSize = poolSize, borrowTimeoutMs = borrowTimeoutMs)
        } catch (e: Throwable) {
            // Native lib or tiles absent on this host → skip the live-actor tests.
            null
        }

    @BeforeEach fun resetMetrics() = ValhallaMetrics.reset()
    @AfterEach fun clearMetrics() = ValhallaMetrics.reset()

    @Test
    @Timeout(60)
    fun `concurrent borrows never hand the same actor to two threads at once`() {
        val poolSize = 4
        val pool = tryBuildPool(poolSize)
        assumeTrue(pool != null, "Valhalla native/tiles not available — skipping live ActorPool test")
        pool!!.use { p ->
            // Track which actors are checked out RIGHT NOW. If withActor ever hands
            // out an actor that's already checked out, we record a violation.
            val checkedOut = Collections.newSetFromMap(ConcurrentHashMap<Actor, Boolean>())
            val violations = AtomicInteger(0)
            val errors = AtomicInteger(0)
            val threads = 32
            val perThread = 25
            val start = CountDownLatch(1)
            val exec = Executors.newFixedThreadPool(threads)
            try {
                val done = CountDownLatch(threads)
                repeat(threads) {
                    exec.submit {
                        start.await()
                        repeat(perThread) {
                            try {
                                p.withActor { actor ->
                                    // On entry the actor must NOT already be checked out.
                                    if (!checkedOut.add(actor)) violations.incrementAndGet()
                                    // Do real work so the hold overlaps with other threads.
                                    val res = actor.route(
                                        RouteRequest(listOf(a, b), costing = "auto").toJson()
                                    )
                                    assertNotNull(res)
                                    checkedOut.remove(actor)
                                }
                            } catch (e: ActorPoolExhaustedException) {
                                // Acceptable under contention; not a correctness failure.
                            } catch (e: Exception) {
                                errors.incrementAndGet()
                            }
                        }
                        done.countDown()
                    }
                }
                start.countDown()
                assertTrue(done.await(55, TimeUnit.SECONDS), "workers did not finish in time")
            } finally {
                exec.shutdownNow()
            }
            assertEquals(0, violations.get(), "an actor was handed to two threads simultaneously")
            assertEquals(0, errors.get(), "unexpected routing errors under concurrency")
            // All actors returned: pool is full again.
            assertEquals(poolSize, p.availableCount(), "not all actors were returned to the pool")
            assertEquals(0, p.inUseCount())
        }
    }

    @Test
    @Timeout(30)
    fun `withActor returns the actor even when the block throws`() {
        val pool = tryBuildPool(poolSize = 1)
        assumeTrue(pool != null, "Valhalla native/tiles not available — skipping")
        pool!!.use { p ->
            assertFailsWith<IllegalStateException> {
                p.withActor<Unit> { throw IllegalStateException("boom") }
            }
            // If the actor was returned, the very next borrow succeeds immediately.
            val res = p.withActor { it.route(RouteRequest(listOf(a, b), costing = "auto").toJson()) }
            assertNotNull(res)
            assertEquals(1, p.availableCount())
        }
    }

    @Test
    @Timeout(30)
    fun `borrow times out with ActorPoolExhaustedException when all actors are busy`() {
        val pool = tryBuildPool(poolSize = 1, borrowTimeoutMs = 100L)
        assumeTrue(pool != null, "Valhalla native/tiles not available — skipping")
        pool!!.use { p ->
            val held = CountDownLatch(1)
            val release = CountDownLatch(1)
            val holder = Thread {
                p.withActor {
                    held.countDown()
                    release.await()
                }
            }
            holder.start()
            assertTrue(held.await(5, TimeUnit.SECONDS), "holder never acquired the actor")
            // Pool now empty; a second borrow must time out fast.
            assertFailsWith<ActorPoolExhaustedException> { p.borrow(timeoutMs = 100L) }
            assertTrue(ValhallaMetrics.getSnapshot().borrowTimeouts >= 1, "timeout metric not recorded")
            release.countDown()
            holder.join(5_000)
        }
    }

    @Test
    @Timeout(30)
    fun `close releases all actors and blocks further borrows`() {
        val pool = tryBuildPool(poolSize = 3)
        assumeTrue(pool != null, "Valhalla native/tiles not available — skipping")
        val p = pool!!
        assertEquals(3, p.availableCount())
        p.close()
        // Idempotent.
        p.close()
        assertFailsWith<IllegalStateException> { p.borrow() }
        assertEquals(0, ValhallaMetrics.getSnapshot().poolSize)
    }

    @Test
    @Timeout(30)
    fun `lease returns the actor on close and is idempotent`() {
        val pool = tryBuildPool(poolSize = 1)
        assumeTrue(pool != null, "Valhalla native/tiles not available — skipping")
        pool!!.use { p ->
            val lease = p.lease()
            assertNotNull(lease.actor())
            assertEquals(0, p.availableCount())
            lease.close()
            assertEquals(1, p.availableCount())
            lease.close() // idempotent — must not double-return
            assertEquals(1, p.availableCount())
        }
    }

    @Test
    fun `forRegion rejects invalid sizing`() {
        // Pure argument validation — no native actor needed.
        assertFailsWith<IllegalArgumentException> { ActorPool.forRegion(region, poolSize = 0) }
        assertFailsWith<IllegalArgumentException> { ActorPool.forRegion(region, borrowTimeoutMs = -1) }
    }
}
