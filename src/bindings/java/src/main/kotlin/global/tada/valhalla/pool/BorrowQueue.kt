package global.tada.valhalla.pool

import global.tada.valhalla.metrics.ValhallaMetrics
import org.slf4j.LoggerFactory
import java.util.Collections
import java.util.IdentityHashMap
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Generic, thread-safe borrow/return queue with timeout-based backpressure.
 *
 * This holds the load-bearing concurrency mechanics of [ActorPool], extracted so
 * they can be unit-tested on ANY host with lightweight fake items (no native
 * engine / tiles required). [ActorPool] is a thin wrapper that puts real
 * [global.tada.valhalla.Actor] instances into one of these.
 *
 * Invariants guaranteed:
 * - an item that has been [borrow]ed is not in the queue, so it cannot be
 *   borrowed again until [giveBack] — i.e. it is never handed to two callers at
 *   once (the property that makes a single-threaded native actor safe);
 * - [borrow] waits at most `borrowTimeoutMs` then throws
 *   [ActorPoolExhaustedException] (fast failure, not unbounded queueing);
 * - [close] is idempotent, drains+closes queued items, and closes checked-out
 *   items when they are returned; [borrow] after close throws.
 *
 * @param items the items to manage (becomes the full capacity)
 * @param borrowTimeoutMs default wait before throwing on an empty queue
 * @param onClose invoked once per item to release it (e.g. Actor::close)
 */
internal class BorrowQueue<T : Any>(
    items: List<T>,
    private val borrowTimeoutMs: Long,
    private val onClose: (T) -> Unit
) : AutoCloseable {

    val capacity: Int = items.size
    private val queue = ArrayBlockingQueue<T>(maxOf(1, capacity), /* fair = */ true)
    private val closed = AtomicBoolean(false)

    // Identity set of items currently checked out. Guards against a double
    // giveBack(), which would otherwise duplicate an item in the queue and let
    // two threads hold the same single-threaded actor at once — the exact crash
    // this pool prevents. Identity (not equals) so distinct actors never collide.
    private val checkedOut: MutableSet<T> =
        Collections.newSetFromMap(Collections.synchronizedMap(IdentityHashMap()))

    init {
        require(capacity >= 1) { "BorrowQueue needs at least 1 item" }
        queue.addAll(items)
    }

    fun borrow(timeoutMs: Long = borrowTimeoutMs): T {
        check(!closed.get()) { "Pool is closed" }
        val start = System.nanoTime()
        val item = try {
            queue.poll(timeoutMs, TimeUnit.MILLISECONDS)
        } catch (e: InterruptedException) {
            Thread.currentThread().interrupt()
            throw ActorPoolExhaustedException("Interrupted while waiting for a pooled item", e)
        }
        ValhallaMetrics.recordBorrowWait((System.nanoTime() - start) / 1_000_000)
        if (item == null) {
            ValhallaMetrics.recordBorrowTimeout()
            throw ActorPoolExhaustedException(
                "No pooled item available within ${timeoutMs}ms (capacity=$capacity, all busy)"
            )
        }
        checkedOut.add(item)
        ValhallaMetrics.incrementActorsInUse()
        return item
    }

    fun giveBack(item: T) {
        // Reject a return for an item that isn't currently checked out (double
        // giveBack, or returning a foreign object). Re-queuing it would duplicate
        // a slot and break the one-holder-per-actor invariant.
        if (!checkedOut.remove(item)) {
            logger.warn(
                "giveBack() called for an item that was not checked out (double return?) — ignoring"
            )
            return
        }
        // The item is no longer in use regardless of which branch we take next.
        ValhallaMetrics.decrementActorsInUse()
        if (closed.get()) {
            runCatching { onClose(item) }
            return
        }
        queue.offer(item) // never blocks: capacity == items handed out
    }

    fun availableCount(): Int = queue.size
    fun inUseCount(): Int = capacity - queue.size
    fun isClosed(): Boolean = closed.get()

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        val drained = ArrayList<T>(capacity)
        queue.drainTo(drained)
        var errors = 0
        for (item in drained) {
            try {
                onClose(item)
            } catch (e: Exception) {
                errors++
                logger.warn("Error closing pooled item: {}", e.message)
            }
        }
        logger.debug("BorrowQueue closed: {} items released, {} errors", drained.size, errors)
    }

    companion object {
        private val logger = LoggerFactory.getLogger(BorrowQueue::class.java)
    }
}
