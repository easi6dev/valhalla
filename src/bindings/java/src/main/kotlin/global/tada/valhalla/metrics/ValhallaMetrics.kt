package global.tada.valhalla.metrics

import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.LongAdder

/**
 * Metrics collection for Valhalla JNI Bindings
 *
 * Phase 5: Testing & Monitoring
 *
 * Metrics collected:
 * - Route request count (total, success, failure)
 * - Route calculation latency (min, max, avg, p50, p95, p99)
 * - Active actor instances
 * - Request rate (per second)
 * - Error rate
 * - Memory usage
 *
 * Prometheus-compatible format for easy integration
 */
public object ValhallaMetrics {

    // Route request counters
    private val totalRequests = LongAdder()
    private val successfulRequests = LongAdder()
    private val failedRequests = LongAdder()

    // Latency tracking
    private val latencySum = LongAdder()
    private val latencyMin = AtomicLong(Long.MAX_VALUE)
    private val latencyMax = AtomicLong(0L)
    private val latencyHistogram = ConcurrentHashMap<Long, LongAdder>()

    // Request counters by region and costing
    private val requestsByRegion = ConcurrentHashMap<String, LongAdder>()
    private val requestsByCosting = ConcurrentHashMap<String, LongAdder>()

    // Active instances
    private val activeActors = LongAdder()

    // Timing
    private val startTime = System.currentTimeMillis()

    /**
     * Record a successful route calculation
     */
    public fun recordRouteSuccess(
        region: String,
        costing: String,
        latencyMs: Long
    ) {
        totalRequests.increment()
        successfulRequests.increment()

        // Update latency statistics
        latencySum.add(latencyMs)
        updateMin(latencyMs)
        updateMax(latencyMs)
        recordLatencyHistogram(latencyMs)

        // Update region/costing counters
        requestsByRegion.computeIfAbsent(region) { LongAdder() }.increment()
        requestsByCosting.computeIfAbsent(costing) { LongAdder() }.increment()
    }

    /**
     * Record a failed route calculation
     */
    public fun recordRouteFailure(
        region: String,
        costing: String,
        error: String
    ) {
        totalRequests.increment()
        failedRequests.increment()

        requestsByRegion.computeIfAbsent(region) { LongAdder() }.increment()
        requestsByCosting.computeIfAbsent(costing) { LongAdder() }.increment()
    }

    /**
     * Increment active actor count
     */
    public fun incrementActiveActors() {
        activeActors.increment()
    }

    /**
     * Decrement active actor count
     */
    public fun decrementActiveActors() {
        activeActors.decrement()
    }

    /**
     * Get current metrics snapshot
     */
    public fun getSnapshot(): MetricsSnapshot {
        val total = totalRequests.sum()
        val success = successfulRequests.sum()
        val failed = failedRequests.sum()
        val avgLatency = if (success > 0) latencySum.sum() / success else 0L

        val uptime = System.currentTimeMillis() - startTime
        val requestRate = if (uptime > 0) (total * 1000.0) / uptime else 0.0

        return MetricsSnapshot(
            totalRequests = total,
            successfulRequests = success,
            failedRequests = failed,
            errorRate = if (total > 0) (failed * 100.0) / total else 0.0,
            averageLatencyMs = avgLatency,
            minLatencyMs = if (latencyMin.get() == Long.MAX_VALUE) 0L else latencyMin.get(),
            maxLatencyMs = latencyMax.get(),
            p50LatencyMs = calculatePercentile(50.0),
            p95LatencyMs = calculatePercentile(95.0),
            p99LatencyMs = calculatePercentile(99.0),
            activeActors = activeActors.sum().toInt(),
            requestRatePerSecond = requestRate,
            uptimeMs = uptime,
            requestsByRegion = requestsByRegion.mapValues { it.value.sum() },
            requestsByCosting = requestsByCosting.mapValues { it.value.sum() }
        )
    }

    /**
     * Export metrics in Prometheus format
     */
    public fun exportPrometheusMetrics(): String {
        val snapshot = getSnapshot()

        return buildString {
            // Route request metrics
            appendLine("# HELP valhalla_route_requests_total Total number of route requests")
            appendLine("# TYPE valhalla_route_requests_total counter")
            appendLine("valhalla_route_requests_total ${snapshot.totalRequests}")
            appendLine()

            appendLine("# HELP valhalla_route_requests_success Successful route requests")
            appendLine("# TYPE valhalla_route_requests_success counter")
            appendLine("valhalla_route_requests_success ${snapshot.successfulRequests}")
            appendLine()

            appendLine("# HELP valhalla_route_requests_failed Failed route requests")
            appendLine("# TYPE valhalla_route_requests_failed counter")
            appendLine("valhalla_route_requests_failed ${snapshot.failedRequests}")
            appendLine()

            // Latency metrics
            appendLine("# HELP valhalla_route_latency_ms Route calculation latency in milliseconds")
            appendLine("# TYPE valhalla_route_latency_ms summary")
            appendLine("valhalla_route_latency_ms{quantile=\"0.5\"} ${snapshot.p50LatencyMs}")
            appendLine("valhalla_route_latency_ms{quantile=\"0.95\"} ${snapshot.p95LatencyMs}")
            appendLine("valhalla_route_latency_ms{quantile=\"0.99\"} ${snapshot.p99LatencyMs}")
            appendLine("valhalla_route_latency_ms_sum ${latencySum.sum()}")
            appendLine("valhalla_route_latency_ms_count ${snapshot.successfulRequests}")
            appendLine()

            // Active actors
            appendLine("# HELP valhalla_active_actors Number of active Actor instances")
            appendLine("# TYPE valhalla_active_actors gauge")
            appendLine("valhalla_active_actors ${snapshot.activeActors}")
            appendLine()

            // Error rate
            appendLine("# HELP valhalla_error_rate_percent Error rate percentage")
            appendLine("# TYPE valhalla_error_rate_percent gauge")
            appendLine("valhalla_error_rate_percent ${snapshot.errorRate}")
            appendLine()

            // Request rate
            appendLine("# HELP valhalla_request_rate_per_second Request rate per second")
            appendLine("# TYPE valhalla_request_rate_per_second gauge")
            appendLine("valhalla_request_rate_per_second ${snapshot.requestRatePerSecond}")
            appendLine()

            // Requests by region
            appendLine("# HELP valhalla_requests_by_region Requests by region")
            appendLine("# TYPE valhalla_requests_by_region counter")
            snapshot.requestsByRegion.forEach { (region, count) ->
                appendLine("valhalla_requests_by_region{region=\"$region\"} $count")
            }
            appendLine()

            // Requests by costing
            appendLine("# HELP valhalla_requests_by_costing Requests by costing type")
            appendLine("# TYPE valhalla_requests_by_costing counter")
            snapshot.requestsByCosting.forEach { (costing, count) ->
                appendLine("valhalla_requests_by_costing{costing=\"$costing\"} $count")
            }
        }
    }

    /**
     * Reset all metrics (useful for testing)
     */
    public fun reset() {
        totalRequests.reset()
        successfulRequests.reset()
        failedRequests.reset()
        latencySum.reset()
        latencyMin.set(Long.MAX_VALUE)
        latencyMax.set(0L)
        latencyHistogram.clear()
        requestsByRegion.clear()
        requestsByCosting.clear()
        activeActors.reset()
    }

    // Private helper methods

    private fun updateMin(value: Long) {
        var current: Long
        do {
            current = latencyMin.get()
            if (value >= current) return
        } while (!latencyMin.compareAndSet(current, value))
    }

    private fun updateMax(value: Long) {
        var current: Long
        do {
            current = latencyMax.get()
            if (value <= current) return
        } while (!latencyMax.compareAndSet(current, value))
    }

    private fun recordLatencyHistogram(latencyMs: Long) {
        // Bucket: 0-10ms, 10-25ms, 25-50ms, 50-100ms, 100-250ms, 250-500ms, 500-1000ms, 1000+ms
        val bucket = when {
            latencyMs < 10 -> 10L
            latencyMs < 25 -> 25L
            latencyMs < 50 -> 50L
            latencyMs < 100 -> 100L
            latencyMs < 250 -> 250L
            latencyMs < 500 -> 500L
            latencyMs < 1000 -> 1000L
            else -> Long.MAX_VALUE
        }

        latencyHistogram.computeIfAbsent(bucket) { LongAdder() }.increment()
    }

    private fun calculatePercentile(percentile: Double): Long {
        val total = successfulRequests.sum()
        if (total == 0L) return 0L

        val targetCount = (total * percentile / 100.0).toLong()
        var count = 0L

        val sortedBuckets = latencyHistogram.keys.sorted()
        for (bucket in sortedBuckets) {
            count += latencyHistogram[bucket]?.sum() ?: 0L
            if (count >= targetCount) {
                return bucket
            }
        }

        return latencyMax.get()
    }
}

/**
 * Metrics snapshot (immutable)
 */
public data class MetricsSnapshot(
    val totalRequests: Long,
    val successfulRequests: Long,
    val failedRequests: Long,
    val errorRate: Double,
    val averageLatencyMs: Long,
    val minLatencyMs: Long,
    val maxLatencyMs: Long,
    val p50LatencyMs: Long,
    val p95LatencyMs: Long,
    val p99LatencyMs: Long,
    val activeActors: Int,
    val requestRatePerSecond: Double,
    val uptimeMs: Long,
    val requestsByRegion: Map<String, Long>,
    val requestsByCosting: Map<String, Long>
) {
    override fun toString(): String {
        return buildString {
            appendLine("=".repeat(60))
            appendLine("Valhalla JNI Metrics")
            appendLine("=".repeat(60))
            appendLine("Requests:")
            appendLine("  Total: $totalRequests")
            appendLine("  Success: $successfulRequests")
            appendLine("  Failed: $failedRequests")
            appendLine("  Error Rate: ${"%.2f".format(errorRate)}%")
            appendLine()
            appendLine("Latency (ms):")
            appendLine("  Min: $minLatencyMs")
            appendLine("  Avg: $averageLatencyMs")
            appendLine("  Max: $maxLatencyMs")
            appendLine("  p50: $p50LatencyMs")
            appendLine("  p95: $p95LatencyMs")
            appendLine("  p99: $p99LatencyMs")
            appendLine()
            appendLine("System:")
            appendLine("  Active Actors: $activeActors")
            appendLine("  Request Rate: ${"%.2f".format(requestRatePerSecond)} req/s")
            appendLine("  Uptime: ${uptimeMs / 1000}s")
            appendLine()
            appendLine("By Region:")
            requestsByRegion.forEach { (region, count) ->
                appendLine("  $region: $count")
            }
            appendLine()
            appendLine("By Costing:")
            requestsByCosting.forEach { (costing, count) ->
                appendLine("  $costing: $count")
            }
            appendLine("=".repeat(60))
        }
    }
}
