package global.tada.valhalla.pool

import global.tada.valhalla.Actor
import global.tada.valhalla.config.RegionConfigFactory
import global.tada.valhalla.metrics.ValhallaMetrics
import org.slf4j.LoggerFactory
import java.util.concurrent.CompletableFuture
import java.util.concurrent.Executors
import java.util.concurrent.ThreadFactory
import java.util.concurrent.atomic.AtomicInteger

/**
 * A fixed-size pool of [Actor] instances for concurrent routing.
 *
 * ## Why this exists
 * Valhalla's native `actor_t` (and the workers it owns) is **single-threaded**:
 * the loki/thor workers keep per-request scratch state with no internal locking,
 * so calling one [Actor] from two threads at once corrupts that state and can
 * SIGSEGV in `GraphTile::node()` (observed in `hs_err_pid24873.log`). The correct
 * model — the one upstream Valhalla's HTTP service uses — is N independent actors,
 * each handled by at most one thread at a time. This pool enforces exactly that:
 * an actor borrowed by [withActor] is removed from the queue for the duration of
 * the call, so **no actor is ever handed to two threads simultaneously**.
 *
 * ## Backpressure
 * When all actors are busy, [withActor] waits up to `borrowTimeoutMs` and then
 * throws [ActorPoolExhaustedException] (fast failure → consumer maps to HTTP 429)
 * instead of queuing unboundedly. This converts overload into graceful
 * degradation rather than rising latency, OOM, or a crash.
 *
 * ## Memory
 * Each actor owns its own `GraphReader` + graph-tile cache, so pool memory is
 * `poolSize × maxCacheSizeBytes` of native cache **on top of** the JVM heap. Size
 * the pool with the documented budget formula in [forRegion]; the mmap'd
 * `tile_extract` is OS-page-cache backed and shared across actors, so a small
 * per-actor `maxCacheSizeBytes` is sufficient.
 *
 * ## Thread-safety
 * The pool itself is fully thread-safe. [withActor] is the recommended entry
 * point (borrow/return is automatic, even on exception). [close] is idempotent.
 *
 * @property poolSize number of actors held by this pool
 * @property borrowTimeoutMs default time [withActor] waits for a free actor
 */
class ActorPool private constructor(
    val poolSize: Int,
    private val borrowTimeoutMs: Long,
    actors: List<Actor>
) : AutoCloseable {

    // All concurrency mechanics live in BorrowQueue (unit-tested independently of
    // the native engine). ActorPool just supplies real Actors + region wiring.
    private val queue = BorrowQueue(actors, borrowTimeoutMs) { it.close() }

    // Dedicated executor for the async helpers — NOT the common ForkJoinPool
    // (which the deprecated Actor.*Async used and which is shared process-wide).
    // Sized to the pool: more async threads than actors just means more threads
    // blocked on borrow(). Daemon so it never blocks JVM shutdown.
    private val asyncExecutor = Executors.newFixedThreadPool(poolSize, object : ThreadFactory {
        private val n = AtomicInteger(0)
        override fun newThread(r: Runnable): Thread =
            Thread(r, "valhalla-pool-async-${n.incrementAndGet()}").apply { isDaemon = true }
    })

    init {
        require(actors.size == poolSize) {
            "Pool was given ${actors.size} actors but poolSize=$poolSize"
        }
        ValhallaMetrics.setPoolSize(poolSize)
        logger.info("ActorPool initialised: poolSize={}, borrowTimeoutMs={}", poolSize, borrowTimeoutMs)
    }

    /**
     * Borrow an actor, run [block] with it, and return it — even if [block] throws.
     *
     * @param block work to run with the exclusively-held actor
     * @param timeoutMs how long to wait for a free actor (default [borrowTimeoutMs])
     * @return whatever [block] returns
     * @throws ActorPoolExhaustedException if no actor became free within the timeout
     * @throws IllegalStateException if the pool is closed
     */
    @JvmOverloads
    fun <T> withActor(timeoutMs: Long = borrowTimeoutMs, block: (Actor) -> T): T {
        val actor = borrow(timeoutMs)
        try {
            return block(actor)
        } finally {
            giveBack(actor)
        }
    }

    /**
     * Safe async borrow: runs [block] with an exclusively-held actor on the
     * pool's own executor (NOT the common ForkJoinPool) and returns its result
     * as a [CompletableFuture]. Borrow/return is automatic. This is the safe
     * replacement for the deprecated `Actor.*Async` methods.
     *
     * ```kotlin
     * pool.supplyAsync { it.route(req) }.thenAccept { ... }
     * ```
     */
    fun <T> supplyAsync(timeoutMs: Long = borrowTimeoutMs, block: (Actor) -> T): CompletableFuture<T> =
        CompletableFuture.supplyAsync({ withActor(timeoutMs, block) }, asyncExecutor)

    /** Convenience: async route on a pooled actor (safe replacement for Actor.routeAsync). */
    fun routeAsync(request: String): CompletableFuture<String> =
        supplyAsync { it.route(request) }

    /** Convenience: async matrix on a pooled actor. */
    fun matrixAsync(request: String): CompletableFuture<String> =
        supplyAsync { it.matrix(request) }

    /**
     * Borrow an actor without a lambda (for Java callers / non-block flows).
     * The caller **must** call [giveBack] in a `finally`, or the actor leaks from
     * the pool permanently. Prefer [withActor] (Kotlin) or [lease] (Java
     * try-with-resources) which return the actor for you.
     *
     * @throws ActorPoolExhaustedException if no actor became free within the timeout
     */
    @JvmOverloads
    fun borrow(timeoutMs: Long = borrowTimeoutMs): Actor = queue.borrow(timeoutMs)

    /**
     * Leak-safe borrow for Java try-with-resources. The actor is returned to the
     * pool automatically when the [Lease] is closed.
     *
     * ```java
     * try (ActorPool.Lease lease = pool.lease()) {
     *     String r = lease.actor().route(req);
     * } // actor returned here, even on exception
     * ```
     *
     * @throws ActorPoolExhaustedException if no actor became free within the timeout
     */
    @JvmOverloads
    fun lease(timeoutMs: Long = borrowTimeoutMs): Lease = Lease(borrow(timeoutMs))

    /**
     * An exclusive hold on a pooled [Actor]. Returns the actor to the pool on
     * [close]. Idempotent: closing twice returns the actor only once.
     */
    inner class Lease internal constructor(private val held: Actor) : AutoCloseable {
        private var returned = false

        /** The borrowed actor. Do not use after [close]. */
        fun actor(): Actor = held

        override fun close() {
            if (returned) return
            returned = true
            giveBack(held)
        }
    }

    /**
     * Return a previously [borrow]ed actor to the pool. Idempotency is the
     * caller's responsibility — return each borrowed actor exactly once.
     */
    fun giveBack(actor: Actor) = queue.giveBack(actor)

    /** Number of actors currently free (not borrowed). Best-effort snapshot. */
    fun availableCount(): Int = queue.availableCount()

    /** Number of actors currently borrowed. Best-effort snapshot. */
    fun inUseCount(): Int = queue.inUseCount()

    /**
     * Close the pool and every actor it owns. Idempotent. Actors currently
     * checked out are closed when they are [giveBack]. Calling [borrow] after
     * close throws [IllegalStateException].
     */
    override fun close() {
        if (queue.isClosed()) return
        logger.info("Closing ActorPool (poolSize={})", poolSize)
        asyncExecutor.shutdown()
        queue.close()
        ValhallaMetrics.setPoolSize(0)
        logger.info("ActorPool closed")
    }

    companion object {
        private val logger = LoggerFactory.getLogger(ActorPool::class.java)

        // ── Cheaper, memory-bounded defaults for POOLED actors ───────────────
        // These differ from RegionConfigFactory's historical defaults (which a
        // single direct actor keeps). They let the pool grow without OOM.
        /** 256 MiB per-actor graph cache (vs the 1 GiB single-actor default). */
        const val POOLED_MAX_CACHE_SIZE_BYTES: Long = 268435456L
        /** Reachability pre-check for pooled actors (cheaper than the 50 default). */
        const val POOLED_MINIMUM_REACHABILITY: Int = 20
        /** Candidate search cutoff (metres) for pooled actors. */
        const val POOLED_SEARCH_CUTOFF: Int = 10000
        /** Clamp pooled auto/taxi max route distance to 200 km (vs 5000 km). */
        const val POOLED_MAX_DISTANCE_METERS: Double = 200000.0
        /**
         * Map-matching (Meili) grid cache per pooled actor. Lowered from the
         * 100240 default to ~25000 so pool growth doesn't multiply map-matching
         * memory (the grid cache is per-actor). Conservative: HMM accuracy
         * (sigma_z/beta/search_radius) is left unchanged — this is a memory bound,
         * not an accuracy tradeoff.
         */
        const val POOLED_MEILI_GRID_CACHE_SIZE: Int = 25000
        /** Default borrow timeout: fail fast rather than pile up latency. */
        const val DEFAULT_BORROW_TIMEOUT_MS: Long = 250L

        /**
         * Build a pool of actors for [region], each with cheaper, memory-bounded
         * config suited to concurrent serving.
         *
         * ## Sizing — memory budget formula
         * Each actor adds ~`maxCacheSizeBytes` of native graph cache. Keep:
         *
         * ```
         *   JVM_Xmx  +  poolSize × maxCacheSizeBytes  +  headroom  ≤  container RAM
         * ```
         *
         * e.g. container = 6 GiB, Xmx = 2 GiB, cache = 256 MiB, headroom ≈ 1 GiB
         *   → poolSize ≤ (6 − 2 − 1) GiB / 256 MiB ≈ 12.  A good default is
         *   `availableProcessors()` (routing is CPU-bound), capped by this budget.
         *
         * The mmap'd `tile_extract` is OS-page-cache backed and shared across
         * actors, so it is NOT multiplied by poolSize.
         *
         * @param region region name or alias (e.g. "new_york", "nyc", "singapore")
         * @param poolSize number of actors (default = available processors)
         * @param maxCacheSizeBytes per-actor graph cache (default 256 MiB)
         * @param enableTraffic load the traffic extract into each actor
         * @param borrowTimeoutMs default wait before [ActorPoolExhaustedException]
         * @param minimumReachability loki reachability pre-check (default 20)
         * @param searchCutoff loki candidate search cutoff in metres (default 10000)
         * @param maxDistanceMeters auto/taxi max route distance clamp (default 200 km)
         * @param meiliGridCacheSize map-matching grid cache per actor (default 25000;
         *   bounds per-actor map-matching memory so it doesn't multiply by poolSize)
         */
        @JvmStatic
        @JvmOverloads
        fun forRegion(
            region: String,
            poolSize: Int = Runtime.getRuntime().availableProcessors(),
            maxCacheSizeBytes: Long = POOLED_MAX_CACHE_SIZE_BYTES,
            enableTraffic: Boolean = false,
            borrowTimeoutMs: Long = DEFAULT_BORROW_TIMEOUT_MS,
            minimumReachability: Int = POOLED_MINIMUM_REACHABILITY,
            searchCutoff: Int = POOLED_SEARCH_CUTOFF,
            maxDistanceMeters: Double = POOLED_MAX_DISTANCE_METERS,
            meiliGridCacheSize: Int = POOLED_MEILI_GRID_CACHE_SIZE
        ): ActorPool {
            require(poolSize >= 1) { "poolSize must be >= 1, was $poolSize" }
            require(borrowTimeoutMs >= 0) { "borrowTimeoutMs must be >= 0, was $borrowTimeoutMs" }

            val config = RegionConfigFactory.buildConfig(
                region = region,
                enableTraffic = enableTraffic,
                maxCacheSizeBytes = maxCacheSizeBytes,
                readerConcurrency = DEFAULT_POOLED_READER_CONCURRENCY,
                minimumReachability = minimumReachability,
                searchCutoff = searchCutoff,
                maxDistanceMeters = maxDistanceMeters,
                meiliGridCacheSize = meiliGridCacheSize
            )

            // Build actors eagerly. If any fails, close the ones already made so
            // we don't leak native handles, then surface the failure.
            val actors = ArrayList<Actor>(poolSize)
            try {
                repeat(poolSize) { actors.add(Actor(config)) }
            } catch (e: Exception) {
                actors.forEach { runCatching { it.close() } }
                throw e
            }
            logger.info(
                "Built ActorPool for region '{}': poolSize={}, cache={}MiB/actor, reachability={}, cutoff={}m",
                region, poolSize, maxCacheSizeBytes / (1024 * 1024), minimumReachability, searchCutoff
            )
            return ActorPool(poolSize, borrowTimeoutMs, actors)
        }

        /** Reader concurrency per pooled actor (kept modest; pool gives parallelism). */
        private const val DEFAULT_POOLED_READER_CONCURRENCY: Int = 2

        /**
         * Test-only seam: build a pool from already-constructed actors, bypassing
         * native tile loading. Lets the pool's concurrency guarantees (no
         * double-hand, return-on-throw, timeout, close) be verified on hosts
         * without built tiles. Not part of the public API.
         */
        internal fun fromActors(
            actors: List<Actor>,
            borrowTimeoutMs: Long = DEFAULT_BORROW_TIMEOUT_MS
        ): ActorPool = ActorPool(actors.size, borrowTimeoutMs, actors)
    }
}
