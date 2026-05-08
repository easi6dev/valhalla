package global.tada.valhalla.traffic

import global.tada.valhalla.Actor
import org.json.JSONArray
import org.json.JSONObject
import org.slf4j.LoggerFactory

/**
 * Result of a traffic-aware routing request.
 *
 * @property response The raw Valhalla JSON response
 * @property trafficUsed Whether live ("current") traffic was used in this route calculation
 */
data class TrafficAwareRouteResult(
    val response: String,
    val trafficUsed: Boolean
)

/**
 * Wrapper around [Actor] that checks traffic freshness before routing.
 *
 * Freshness is determined by reading `traffic-status.json` written by the
 * Python LTA cron. When the file is absent or the last cron run exceeds
 * [staleThresholdMinutes], the router strips `"current"` from
 * `costing_options.<costing>.speed_types`. This makes the C++ engine fall back
 * to predicted/constrained/freeflow speeds while keeping routing operational.
 *
 * Region-agnostic. Toll calculation is the consumer's concern (e.g.
 * `tada-routing-service` runs post-route gantry detection on the encoded
 * polyline) — this class deliberately does not embed any toll/region logic.
 *
 * @property actor The Valhalla Actor instance (must have traffic.tar loaded)
 * @property trafficStatusPath Path to the `traffic-status.json` written by the cron job
 * @property staleThresholdMinutes Age in minutes after which traffic data is considered stale
 */
class TrafficAwareRouter(
    private val actor: Actor,
    private val trafficStatusPath: String,
    private val staleThresholdMinutes: Int = 15
) {

    private val logger = LoggerFactory.getLogger(TrafficAwareRouter::class.java)

    @Volatile
    private var lastTrafficState: Boolean? = null

    /**
     * Calculate a route with automatic traffic fallback.
     */
    fun route(request: String): TrafficAwareRouteResult {
        val useCurrentTraffic = TrafficStatusFile.isTrafficFresh(trafficStatusPath, staleThresholdMinutes)
        logTransition(useCurrentTraffic)
        val effectiveRequest = prepareRequest(request, useCurrentTraffic)
        val response = actor.route(effectiveRequest)
        return TrafficAwareRouteResult(response, trafficUsed = useCurrentTraffic)
    }

    /**
     * Calculate a time/distance matrix with automatic traffic fallback.
     */
    fun matrix(request: String): TrafficAwareRouteResult {
        val useCurrentTraffic = TrafficStatusFile.isTrafficFresh(trafficStatusPath, staleThresholdMinutes)
        logTransition(useCurrentTraffic)
        val effectiveRequest = prepareRequest(request, useCurrentTraffic)
        val response = actor.matrix(effectiveRequest)
        return TrafficAwareRouteResult(response, trafficUsed = useCurrentTraffic)
    }

    /**
     * Calculate an optimized multi-stop route with automatic traffic fallback.
     */
    fun optimizedRoute(request: String): TrafficAwareRouteResult {
        val useCurrentTraffic = TrafficStatusFile.isTrafficFresh(trafficStatusPath, staleThresholdMinutes)
        logTransition(useCurrentTraffic)
        val effectiveRequest = prepareRequest(request, useCurrentTraffic)
        val response = actor.optimizedRoute(effectiveRequest)
        return TrafficAwareRouteResult(response, trafficUsed = useCurrentTraffic)
    }

    private fun prepareRequest(request: String, useCurrentTraffic: Boolean): String {
        return if (useCurrentTraffic) {
            ensureDateTimeForTraffic(request)
        } else {
            stripCurrentFromSpeedTypes(request)
        }
    }

    private fun logTransition(useCurrentTraffic: Boolean) {
        if (lastTrafficState != useCurrentTraffic) {
            if (useCurrentTraffic) {
                logger.info("Live traffic restored, switching to traffic-aware routing")
            } else {
                logger.warn("Routing without live traffic (traffic-status.json stale or missing)")
            }
            lastTrafficState = useCurrentTraffic
        }
    }

    companion object {

        /**
         * Speed types to use when live traffic is unavailable.
         * Includes all layers except "current" (live traffic).
         */
        private val STATIC_SPEED_TYPES = listOf("freeflow", "constrained", "predicted")

        /**
         * All speed types including live traffic.
         */
        private val LIVE_SPEED_TYPES = listOf("freeflow", "constrained", "predicted", "current")

        /**
         * Prepare a request for live traffic routing.
         *
         * Two things are needed for Valhalla C++ to use live traffic:
         * 1. `date_time: {"type": 0}` — provides a valid `seconds` parameter so
         *    GetSpeed() can use kCurrentFlowMask (without it, seconds defaults to
         *    kInvalidSecondsOfWeek and live traffic is skipped)
         * 2. `costing_options.<costing>.speed_types` must include "current" — the
         *    C++ flow mask is derived from this array; without it, the default mask
         *    may not include kCurrentFlowMask depending on the costing model
         */
        @JvmStatic
        fun ensureDateTimeForTraffic(request: String): String {
            val json = JSONObject(request)
            if (!json.has("date_time")) {
                json.put("date_time", JSONObject().put("type", 0))
            }

            // Ensure speed_types includes "current" so C++ uses live traffic data
            val costing = json.optString("costing", "auto")
            val costingOptions = json.optJSONObject("costing_options")
                ?: JSONObject().also { json.put("costing_options", it) }
            val costingObj = costingOptions.optJSONObject(costing)
                ?: JSONObject().also { costingOptions.put(costing, it) }
            costingObj.put("speed_types", JSONArray(LIVE_SPEED_TYPES))

            return json.toString()
        }

        /**
         * Strip "current" from speed_types in the route request JSON.
         *
         * Navigates to `costing_options.<costing>.speed_types` and replaces it
         * with all speed types except "current". If the field or parent objects
         * don't exist, they are created.
         *
         * @param request Original route request JSON string
         * @return Modified request JSON with "current" removed from speed_types
         */
        @JvmStatic
        fun stripCurrentFromSpeedTypes(request: String): String {
            val json = JSONObject(request)
            val costing = json.optString("costing", "auto")

            val costingOptions = json.optJSONObject("costing_options")
                ?: JSONObject().also { json.put("costing_options", it) }

            val costingObj = costingOptions.optJSONObject(costing)
                ?: JSONObject().also { costingOptions.put(costing, it) }

            costingObj.put("speed_types", JSONArray(STATIC_SPEED_TYPES))

            return json.toString()
        }
    }
}
