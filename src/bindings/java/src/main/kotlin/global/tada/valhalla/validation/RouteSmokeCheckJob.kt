package global.tada.valhalla.validation

import global.tada.valhalla.Actor
import global.tada.valhalla.ValhallaException
import org.json.JSONObject
import org.slf4j.LoggerFactory

/**
 * Standalone job that issues a real route request against a freshly built tile
 * set, so `phase_validate` in run-tile-pipeline.sh can catch tiles that pass
 * every file-based check (exist, sized, readable) but can't actually route —
 * e.g. a costing model or hierarchy misconfiguration that only shows up when
 * the routing engine loads the tiles.
 *
 * Must run BEFORE the tile set is promoted to 'latest' (unlike
 * traffic/sg/GeometryMappingJob, which intentionally runs after the swap) —
 * called with an explicit --tile-dir pointing at the versioned build output,
 * not the 'latest' symlink.
 *
 * Usage: RouteSmokeCheckJob <region> <tileDir>
 *
 * Exit codes:
 *   - 0: Route found successfully
 *   - 1: Actor/route call failed — tiles cannot serve a route
 *   - 2: Bad arguments (wrong arg count)
 *   - 3: No sample locations configured for this region — not a defect, this
 *        job only covers Valhalla-served regions (today: singapore, new_york);
 *        GraphHopper-only regions have no route to sample here. Mirrors
 *        traffic/sg/GeometryMappingJob's EXIT_NO_SNAPSHOT: a benign "not
 *        applicable" condition the caller should treat as skip, not failure.
 */
object RouteSmokeCheckJob {

    private val logger = LoggerFactory.getLogger(RouteSmokeCheckJob::class.java)

    /** Exit code signalling "region has no sample locations" — benign, not a defect. */
    const val EXIT_NO_SAMPLE_LOCATIONS = 3

    // One short, known-routable pair per region — enough to prove the engine
    // can load these tiles and produce a route, not a full route-quality check.
    // Only Valhalla-served regions belong here (today: singapore, new_york) —
    // the other GraphHopper-only regions never invoke this job in practice
    // (run-tile-pipeline.sh/-us.sh are only wired up for singapore/new_york in
    // argo-cd), but a missing entry must degrade gracefully (see
    // EXIT_NO_SAMPLE_LOCATIONS) rather than fail closed, since nothing else
    // enforces that restriction.
    val SAMPLE_LOCATIONS: Map<String, Pair<Pair<Double, Double>, Pair<Double, Double>>> = mapOf(
        // Raffles Place -> Marina Bay Sands
        "singapore" to ((1.2897 to 103.8501) to (1.2834 to 103.8607)),
        // Times Square -> Wall Street
        "new_york" to ((40.7580 to -73.9855) to (40.7069 to -74.0113)),
    )

    @JvmStatic
    fun main(args: Array<String>) {
        System.exit(run(args))
    }

    @JvmStatic
    fun run(args: Array<String>): Int {
        logger.info("=== Route Smoke Check starting ===")

        if (args.size < 2) {
            logger.error("Usage: RouteSmokeCheckJob <region> <tileDir>")
            return 2
        }
        val region = args[0]
        val tileDir = args[1]

        val sample = SAMPLE_LOCATIONS[region]
        if (sample == null) {
            logger.warn("No sample locations configured for region '{}' (known: {}) — skipping, not a failure", region, SAMPLE_LOCATIONS.keys)
            return EXIT_NO_SAMPLE_LOCATIONS
        }

        val actor = try {
            Actor.createForRegion(region, tileDir)
        } catch (e: Exception) {
            logger.error("Failed to create Actor for region '{}' at tileDir '{}': {}", region, tileDir, e.message)
            return 1
        }

        try {
            val (origin, destination) = sample
            val request = buildRouteRequestJson(origin, destination)
            logger.info("Requesting route: {} -> {}", origin, destination)

            val response = actor.route(request)
            val trip = JSONObject(response).optJSONObject("trip")
            val legs = trip?.optJSONArray("legs")
            if (trip == null || legs == null || legs.length() == 0) {
                logger.error("Route response had no legs: {}", response)
                return 1
            }

            logger.info("Route smoke check passed: {} leg(s), summary={}", legs.length(), trip.optJSONObject("summary"))
            return 0
        } catch (e: ValhallaException) {
            logger.error("Route request failed: {}", e.message)
            return 1
        } catch (e: Exception) {
            logger.error("Route smoke check failed: {}", e.message, e)
            return 1
        } finally {
            try {
                actor.close()
            } catch (e: Exception) {
                logger.warn("Failed to close Actor: {}", e.message)
            }
            logger.info("=== Route Smoke Check finished ===")
        }
    }

    @JvmStatic
    fun buildRouteRequestJson(origin: Pair<Double, Double>, destination: Pair<Double, Double>): String {
        return """
            {"locations":[{"lat":${origin.first},"lon":${origin.second}},{"lat":${destination.first},"lon":${destination.second}}],"costing":"auto"}
        """.trimIndent()
    }
}
