package global.tada.valhalla.dispatch

import global.tada.valhalla.Actor
import global.tada.valhalla.traffic.TrafficAwareRouter
import org.json.JSONArray
import org.json.JSONObject
import org.slf4j.LoggerFactory

/**
 * Ranks candidate drivers for a rider using a SINGLE Valhalla matrix
 * (`sources_to_targets`) call instead of one `route()` per driver.
 *
 * ## Why this is the biggest throughput win
 * The naive dispatch pattern routes the rider to each of K drivers in a loop:
 * K separate `route()` calls, each paying its own loki snap + thor search. With
 * a matrix the engine snaps the locations once and runs a single one-to-many
 * search, so the rider→K-drivers cost collapses from O(K route calls) to one
 * matrix call. On a busy pod this is the difference between holding a pooled
 * actor for K× as long vs once.
 *
 * ## Concurrency
 * This class is **stateless** — it operates on whatever [Actor] you hand it. Use
 * it INSIDE a pool borrow so the actor is exclusively held for the matrix call:
 *
 * ```kotlin
 * val ranked = pool.withActor { actor ->
 *     DriverSelection.rank(actor, rider, drivers, costing = "auto")
 * }
 * val best = ranked.firstOrNull()
 * ```
 *
 * ## Unreachable drivers
 * Valhalla returns `time`/`distance` = null for a target it cannot reach from the
 * source (disconnected, beyond `max_matrix_distance`, etc.). Those drivers are
 * excluded from the ranked result by default (see [rank]'s `includeUnreachable`).
 */
object DriverSelection {

    private val logger = LoggerFactory.getLogger(DriverSelection::class.java)

    /** A geographic point (rider or driver). */
    data class Point(val lat: Double, val lon: Double)

    /** How to order candidate drivers. */
    enum class RankBy { TIME, DISTANCE }

    /**
     * One ranked driver.
     *
     * @property index index into the original `drivers` list passed to [rank]
     * @property timeSeconds estimated travel time rider→driver (null if unreachable)
     * @property distanceMeters estimated distance rider→driver (null if unreachable)
     * @property reachable whether Valhalla could route to this driver
     */
    data class RankedDriver(
        val index: Int,
        val timeSeconds: Double?,
        val distanceMeters: Double?,
        val reachable: Boolean
    )

    /**
     * Rank [drivers] by proximity to [rider] using one matrix call on [actor].
     *
     * @param actor an exclusively-held actor (e.g. from `pool.withActor { ... }`)
     * @param rider the rider / pickup location (the single matrix source)
     * @param drivers candidate driver locations (the matrix targets)
     * @param costing Valhalla costing model (default "auto")
     * @param rankBy order by travel TIME (default) or DISTANCE
     * @param includeUnreachable if true, unreachable drivers are appended (ranked
     *   last); if false (default) they are dropped
     * @param costingOptionsJson optional raw `costing_options` JSON object string
     *   merged into the request (e.g. taxi tuning); null to omit
     * @return drivers ordered best-first; empty if [drivers] is empty
     * @throws IllegalArgumentException if drivers is empty-after-validation or the
     *   count exceeds what a single matrix can take
     */
    @JvmStatic
    @JvmOverloads
    fun rank(
        actor: Actor,
        rider: Point,
        drivers: List<Point>,
        costing: String = "auto",
        rankBy: RankBy = RankBy.TIME,
        includeUnreachable: Boolean = false,
        costingOptionsJson: String? = null
    ): List<RankedDriver> {
        if (drivers.isEmpty()) return emptyList()
        val request = buildMatrixRequest(rider, drivers, costing, costingOptionsJson)
        val response = actor.matrix(request)
        return parseAndRank(response, drivers.size, rankBy, includeUnreachable)
    }

    /**
     * Traffic-aware variant: ranks via [TrafficAwareRouter.matrix] so the request
     * automatically falls back to predicted/freeflow speeds when live traffic is
     * stale, and includes `date_time` for live-traffic correctness when fresh.
     *
     * @return the ranked drivers plus whether live traffic was used
     */
    @JvmStatic
    @JvmOverloads
    fun rankTrafficAware(
        router: TrafficAwareRouter,
        rider: Point,
        drivers: List<Point>,
        costing: String = "auto",
        rankBy: RankBy = RankBy.TIME,
        includeUnreachable: Boolean = false,
        costingOptionsJson: String? = null
    ): TrafficAwareRanking {
        if (drivers.isEmpty()) return TrafficAwareRanking(emptyList(), trafficUsed = false)
        val request = buildMatrixRequest(rider, drivers, costing, costingOptionsJson)
        val result = router.matrix(request)
        val ranked = parseAndRank(result.response, drivers.size, rankBy, includeUnreachable)
        return TrafficAwareRanking(ranked, trafficUsed = result.trafficUsed)
    }

    /** Result of [rankTrafficAware]. */
    data class TrafficAwareRanking(
        val drivers: List<RankedDriver>,
        val trafficUsed: Boolean
    )

    /**
     * Build a `sources_to_targets` request: one source (rider), K targets (drivers).
     */
    internal fun buildMatrixRequest(
        rider: Point,
        drivers: List<Point>,
        costing: String,
        costingOptionsJson: String?
    ): String {
        val json = JSONObject()
        json.put("sources", JSONArray().put(pointJson(rider)))
        val targets = JSONArray()
        for (d in drivers) targets.put(pointJson(d))
        json.put("targets", targets)
        json.put("costing", costing)
        // Force the verbose response shape (array-of-arrays of
        // {from_index,to_index,time,distance}). Without this Valhalla emits the
        // slim {durations:[[...]], distances:[[...]]} form; parseAndRank handles
        // both, but pinning verbose keeps the response deterministic + carries the
        // explicit to_index used for ranking.
        json.put("verbose", true)
        if (costingOptionsJson != null) {
            json.put("costing_options", JSONObject(costingOptionsJson))
        }
        return json.toString()
    }

    private fun pointJson(p: Point): JSONObject =
        JSONObject().put("lat", p.lat).put("lon", p.lon)

    /**
     * Parse a `sources_to_targets` matrix response (1 source → K targets) and
     * return drivers ordered by the chosen metric, best-first.
     */
    internal fun parseAndRank(
        response: String,
        expectedTargets: Int,
        rankBy: RankBy,
        includeUnreachable: Boolean
    ): List<RankedDriver> {
        val root = JSONObject(response)
        val parsed = when (val s2t = root.opt("sources_to_targets")) {
            // Verbose form: [[ {from_index,to_index,time,distance}, ... ]]
            is JSONArray -> parseVerbose(s2t)
            // Slim form:  { durations:[[..]], distances:[[..]] }
            is JSONObject -> parseSlim(s2t)
            else -> throw IllegalStateException(
                "Matrix response has no 'sources_to_targets': ${response.take(200)}"
            )
        }

        if (parsed.size != expectedTargets) {
            logger.warn(
                "Matrix returned {} cells for {} drivers — proceeding with what was returned",
                parsed.size, expectedTargets
            )
        }

        val (reachable, unreachable) = parsed.partition { it.reachable }
        val sorted = reachable.sortedBy {
            when (rankBy) {
                RankBy.TIME -> it.timeSeconds ?: Double.MAX_VALUE
                RankBy.DISTANCE -> it.distanceMeters ?: Double.MAX_VALUE
            }
        }
        return if (includeUnreachable) sorted + unreachable else sorted
    }

    /** Verbose matrix: outer array (one row per source); we use source row 0. */
    private fun parseVerbose(s2t: JSONArray): List<RankedDriver> {
        val row = s2t.optJSONArray(0)
            ?: throw IllegalStateException("Verbose matrix response has no source row")
        val out = ArrayList<RankedDriver>(row.length())
        for (i in 0 until row.length()) {
            val cell = row.optJSONObject(i) ?: continue
            val idx = if (cell.has("to_index")) cell.getInt("to_index") else i
            val time = cell.optDoubleOrNull("time")
            val dist = cell.optDoubleOrNull("distance")
            out.add(RankedDriver(idx, time, dist, reachable = time != null && dist != null))
        }
        return out
    }

    /** Slim matrix: { durations:[[..]], distances:[[..]] }; we use source row 0. */
    private fun parseSlim(s2t: JSONObject): List<RankedDriver> {
        val durations = s2t.optJSONArray("durations")?.optJSONArray(0)
        val distances = s2t.optJSONArray("distances")?.optJSONArray(0)
        if (durations == null && distances == null) {
            throw IllegalStateException("Slim matrix response has neither durations nor distances")
        }
        val k = maxOf(durations?.length() ?: 0, distances?.length() ?: 0)
        val out = ArrayList<RankedDriver>(k)
        for (i in 0 until k) {
            val time = durations?.optDoubleOrNullAt(i)
            val dist = distances?.optDoubleOrNullAt(i)
            out.add(RankedDriver(i, time, dist, reachable = time != null && dist != null))
        }
        return out
    }

    /** Null-safe double read: treats JSON null / missing as null (unreachable). */
    private fun JSONObject.optDoubleOrNull(key: String): Double? {
        if (!has(key) || isNull(key)) return null
        return optDouble(key).takeUnless { it.isNaN() }
    }

    /** Null-safe double read from a JSON array index (null entry = unreachable). */
    private fun JSONArray.optDoubleOrNullAt(i: Int): Double? {
        if (i >= length() || isNull(i)) return null
        return optDouble(i).takeUnless { it.isNaN() }
    }
}
