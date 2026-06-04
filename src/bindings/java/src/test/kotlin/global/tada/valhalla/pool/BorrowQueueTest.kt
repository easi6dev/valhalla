package global.tada.valhalla.pool

import global.tada.valhalla.metrics.ValhallaMetrics
import org.junit.jupiter.api.AfterEach
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
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Verifies the load-bearing concurrency guarantees of the pool mechanics using
 * lightweight fakes — runs on ANY host (no native engine / tiles needed).
 *
 * [ActorPool] delegates to [BorrowQueue], so proving these invariants here proves
 * them for the real pool's borrow/return/timeout/close behaviour. The live
 * native path is additionally exercised by ActorPoolTest (gated) and the Phase 6
 * stress test (CI/Linux).
 */
class BorrowQueueTest {

    /** A fake pooled item that records whether it was closed. */
    private class Fake(val id: Int) {
        @Volatile var closed = false
        fun close() { closed = true }
    }

    private fun queueOf(n: Int, timeoutMs: Long = 200L): Pair<BorrowQueue<Fake>, List<Fake>> {
        val items = (0 until n).map { Fake(it) }
        return BorrowQueue(items, timeoutMs) { it.close() } to items
    }

    @BeforeEach fun resetMetrics() = ValhallaMetrics.reset()
    @AfterEach fun clearMetrics() = ValhallaMetrics.reset()

    @Test
    @Timeout(60)
    fun `no item is ever borrowed by two threads at once`() {
        val capacity = 4
        val (q, _) = queueOf(capacity)
        val checkedOut = Collections.newSetFromMap(ConcurrentHashMap<Fake, Boolean>())
        val violations = AtomicInteger(0)
        val threads = 32
        val perThread = 200
        val start = CountDownLatch(1)
        val done = CountDownLatch(threads)
        val exec = Executors.newFixedThreadPool(threads)
        try {
            repeat(threads) {
                exec.submit {
                    start.await()
                    repeat(perThread) {
                        try {
                            val item = q.borrow(200L)
                            try {
                                if (!checkedOut.add(item)) violations.incrementAndGet()
                                // tiny busy hold to force overlap
                                Thread.onSpinWait()
                                checkedOut.remove(item)
                            } finally {
                                q.giveBack(item)
                            }
                        } catch (e: ActorPoolExhaustedException) {
                            // acceptable under contention
                        }
                    }
                    done.countDown()
                }
            }
            start.countDown()
            assertTrue(done.await(55, TimeUnit.SECONDS), "workers did not finish")
        } finally {
            exec.shutdownNow()
        }
        assertEquals(0, violations.get(), "an item was handed to two threads simultaneously")
        assertEquals(capacity, q.availableCount(), "not all items returned")
        assertEquals(0, q.inUseCount())
    }

    @Test
    fun `borrow returns distinct items until empty`() {
        val (q, items) = queueOf(3)
        val a = q.borrow(); val b = q.borrow(); val c = q.borrow()
        assertEquals(setOf(items[0], items[1], items[2]), setOf(a, b, c))
        assertEquals(0, q.availableCount())
        // empty → times out
        assertFailsWith<ActorPoolExhaustedException> { q.borrow(50L) }
        q.giveBack(a); q.giveBack(b); q.giveBack(c)
        assertEquals(3, q.availableCount())
    }

    @Test
    fun `giveBack after exception path keeps the item usable`() {
        val (q, _) = queueOf(1)
        val first = q.borrow()
        q.giveBack(first) // simulate finally-block return
        val second = q.borrow(50L) // must succeed immediately
        assertEquals(first, second)
        q.giveBack(second)
    }

    @Test
    fun `timeout throws and records the timeout metric`() {
        val (q, _) = queueOf(1)
        q.borrow() // drain
        assertFailsWith<ActorPoolExhaustedException> { q.borrow(50L) }
        assertTrue(ValhallaMetrics.getSnapshot().borrowTimeouts >= 1)
    }

    @Test
    fun `close releases all items, is idempotent, and blocks borrow`() {
        val (q, items) = queueOf(3)
        q.close()
        q.close() // idempotent
        assertTrue(items.all { it.closed }, "every queued item must be closed")
        assertTrue(q.isClosed())
        assertFailsWith<IllegalStateException> { q.borrow() }
    }

    @Test
    fun `double giveBack does not duplicate the item in the queue`() {
        // The core safety property: returning the same item twice must NOT make it
        // borrowable twice (which would hand one actor to two threads).
        val (q, _) = queueOf(2)
        val item = q.borrow()
        q.giveBack(item)
        q.giveBack(item) // erroneous second return — must be ignored
        // Capacity is still 2, not 3.
        assertEquals(2, q.availableCount())
        val a = q.borrow(); val b = q.borrow()
        assertFailsWith<ActorPoolExhaustedException> { q.borrow(50L) } // only 2 exist
        q.giveBack(a); q.giveBack(b)
    }

    @Test
    fun `giveBack of a never-borrowed item is ignored`() {
        val (q, items) = queueOf(2)
        // items[0] is in the queue, never borrowed — returning it must be a no-op.
        q.giveBack(items[0])
        assertEquals(2, q.availableCount())
    }

    @Test
    fun `actorsInUse metric reflects borrows and returns, not live actor count`() {
        val (q, _) = queueOf(3)
        val a = q.borrow(); val b = q.borrow()
        assertEquals(2, ValhallaMetrics.getSnapshot().actorsInUse)
        q.giveBack(a)
        assertEquals(1, ValhallaMetrics.getSnapshot().actorsInUse)
        q.giveBack(b)
        assertEquals(0, ValhallaMetrics.getSnapshot().actorsInUse)
    }

    @Test
    fun `item checked out at close time is closed on giveBack`() {
        val (q, _) = queueOf(2)
        val held = q.borrow()
        assertFalse(held.closed)
        q.close()                 // held is not in the queue yet
        assertFalse(held.closed)  // still open — caller hasn't returned it
        q.giveBack(held)          // returning into a closed pool → close it
        assertTrue(held.closed, "checked-out item must be closed when returned to a closed pool")
    }
}
