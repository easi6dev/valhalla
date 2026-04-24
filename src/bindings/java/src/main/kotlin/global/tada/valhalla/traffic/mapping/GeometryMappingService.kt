package global.tada.valhalla.traffic.mapping

import global.tada.valhalla.traffic.models.SpeedBandEntry
import org.json.JSONArray
import org.json.JSONObject
import org.slf4j.LoggerFactory
import kotlin.math.*

/**
 * Confidence level for a geometry-based LTA-to-OSM edge mapping.
 */
enum class ConfidenceLevel {
    HIGH, MEDIUM, LOW, NONE
}

/**
 * A single candidate edge with confidence scoring details.
 *
 * @property edge The Valhalla directed edge
 * @property totalScore Weighted composite score (0.0 to 1.0)
 * @property confidence Confidence level derived from totalScore
 * @property distanceM Snap distance in metres from the LTA coordinate to this edge
 * @property bearingDiffDeg Absolute bearing difference in degrees between LTA segment and OSM edge
 * @property roadNameMatch Whether the LTA road name matched the OSM road name
 * @property categoryMatch Whether the LTA road category matched the OSM road class
 * @property osmRoadName Road name from OSM edge metadata
 * @property osmRoadClass Road class from OSM edge metadata (e.g. "motorway", "primary")
 */
data class ScoredCandidate(
    val edge: MappedEdge,
    val totalScore: Double,
    val confidence: ConfidenceLevel,
    val distanceM: Double,
    val bearingDiffDeg: Double,
    val roadNameMatch: Boolean,
    val categoryMatch: Boolean,
    val osmRoadName: String,
    val osmRoadClass: String,
    val osmWayId: Long
)

/**
 * Result of mapping a single LTA speed band segment to Valhalla edges.
 *
 * @property linkId LTA segment identifier
 * @property roadName LTA road name
 * @property roadCategory LTA road category code
 * @property bestCandidate Highest-scoring candidate, or null if unmapped
 * @property allCandidates All scored candidates ordered by score descending
 * @property flagged Whether this mapping is ambiguous or otherwise flagged
 * @property flagReason Human-readable reason for flagging (empty if not flagged)
 */
data class MappedSegment(
    val linkId: String,
    val roadName: String,
    val roadCategory: String,
    val bestCandidate: ScoredCandidate?,
    val allCandidates: List<ScoredCandidate>,
    val flagged: Boolean,
    val flagReason: String
)

/**
 * Complete geometry-based mapping with confidence scores and summary statistics.
 *
 * @property segments Map of LTA linkId to its mapped segment result
 * @property tileToEdges Reverse index: Valhalla tile -> set of edge indices with LTA data
 * @property summary Aggregate statistics for the mapping
 */
data class GeometryMapping(
    val segments: Map<String, MappedSegment>,
    val tileToEdges: Map<TileKey, Set<Int>>,
    val summary: MappingSummary
)

/**
 * Aggregate statistics for a geometry mapping run.
 */
data class MappingSummary(
    val total: Int,
    val mapped: Int,
    val unmapped: Int,
    val highConfidence: Int,
    val mediumConfidence: Int,
    val lowConfidence: Int,
    val flagged: Int,
    val byCategory: Map<String, CategoryStats>
)

/**
 * Per-category mapping statistics.
 */
data class CategoryStats(
    val categoryName: String,
    val total: Int,
    val highConfidence: Int,
    val mediumConfidence: Int,
    val lowConfidence: Int,
    val unmapped: Int,
    val flagged: Int
)

/**
 * Geometry-aware scoring engine that maps LTA road segments to Valhalla/OSM edges
 * with confidence scores based on distance, bearing, road name, and road category.
 *
 * Unlike the old EdgeMappingService which took only the first candidate edge, this service
 * examines ALL candidate edges returned by `locate()` and scores each on four signals
 * with **category-specific weights**:
 * - Distance: How close the snap point is to the LTA coordinate (wider tolerance for expressways)
 * - Bearing: How well the edge direction matches the LTA segment direction (higher weight for expressways)
 * - Name: Whether the road names match (with abbreviation expansion)
 * - Category: Whether the road classifications are compatible
 *
 * @property locateFn Function that executes a Valhalla locate request (typically Actor::locate)
 */
class GeometryMappingService(
    private val locateFn: (String) -> String
) {

    private val logger = LoggerFactory.getLogger(GeometryMappingService::class.java)

    /**
     * Build a confidence-scored mapping from all LTA speed band segments to Valhalla edges.
     *
     * @param speedBands List of speed band entries from LTA API
     * @return Complete geometry mapping with confidence scores and summary
     */
    fun buildMapping(speedBands: List<SpeedBandEntry>): GeometryMapping {
        val segments = mutableMapOf<String, MappedSegment>()
        val tileToEdges = mutableMapOf<TileKey, MutableSet<Int>>()

        for ((index, entry) in speedBands.withIndex()) {
            try {
                val mapped = mapSegment(entry)
                segments[entry.linkId] = mapped

                if (mapped.bestCandidate != null) {
                    val edge = mapped.bestCandidate.edge
                    val key = TileKey(edge.tileLevel, edge.tileId)
                    tileToEdges.getOrPut(key) { mutableSetOf() }.add(edge.edgeIndex)
                }
            } catch (e: Exception) {
                segments[entry.linkId] = MappedSegment(
                    linkId = entry.linkId,
                    roadName = entry.roadName,
                    roadCategory = entry.roadCategory,
                    bestCandidate = null,
                    allCandidates = emptyList(),
                    flagged = true,
                    flagReason = "locate() error: ${e.message}"
                )
                logger.debug("Failed to map linkId={}: {}", entry.linkId, e.message)
            }

            if ((index + 1) % 1000 == 0) {
                logger.info("Mapping progress: {}/{} segments processed", index + 1, speedBands.size)
            }
        }

        val summary = buildSummary(segments)

        logger.info(
            "Geometry mapping complete: {} mapped, {} unmapped, {} high-confidence, {} flagged out of {} segments",
            summary.mapped, summary.unmapped, summary.highConfidence, summary.flagged, summary.total
        )

        return GeometryMapping(
            segments = segments,
            tileToEdges = tileToEdges.mapValues { it.value.toSet() },
            summary = summary
        )
    }

    /**
     * Map a single LTA speed band segment to the best Valhalla edge.
     */
    private fun mapSegment(entry: SpeedBandEntry): MappedSegment {
        val request = JSONObject().apply {
            put("locations", JSONArray().apply {
                put(JSONObject().put("lat", entry.startLat).put("lon", entry.startLon))
                put(JSONObject().put("lat", entry.endLat).put("lon", entry.endLon))
            })
            put("costing", "auto")
            put("verbose", true)
        }

        val response = locateFn(request.toString())
        val results = JSONArray(response)

        val ltaBearing = computeLtaBearing(entry.startLat, entry.startLon, entry.endLat, entry.endLon)
        val segmentLengthM = approximateDistanceM(entry.startLat, entry.startLon, entry.endLat, entry.endLon)
        val candidates = mutableListOf<ScoredCandidate>()

        for (i in 0 until results.length()) {
            val location = results.optJSONObject(i) ?: continue
            val edgesArray = location.optJSONArray("edges") ?: continue

            for (j in 0 until edgesArray.length()) {
                val edgeJson = edgesArray.optJSONObject(j) ?: continue
                val edgeId = edgeJson.optJSONObject("edge_id") ?: continue

                val scored = scoreCandidate(entry, edgeJson, edgeId, ltaBearing, segmentLengthM)
                if (scored != null) {
                    candidates.add(scored)
                }
            }
        }

        // Deduplicate by edge identity, keeping highest score
        val deduped = candidates
            .groupBy { Triple(it.edge.tileLevel, it.edge.tileId, it.edge.edgeIndex) }
            .map { (_, group) -> group.maxByOrNull { it.totalScore }!! }
            .sortedByDescending { it.totalScore }

        val best = deduped.firstOrNull()
        val flagged: Boolean
        val flagReason: String

        if (best == null) {
            flagged = true
            flagReason = "no candidates from locate()"
        } else if (best.confidence != ConfidenceLevel.HIGH && deduped.size >= 2) {
            // Only flag ambiguity when the best candidate isn't high-confidence.
            // When the best is HIGH, we trust it even if the runner-up is close.
            val scoreDiff = deduped[0].totalScore - deduped[1].totalScore
            if (scoreDiff < AMBIGUITY_THRESHOLD) {
                flagged = true
                flagReason = "ambiguous: top-2 within %.3f (%.3f vs %.3f)".format(
                    scoreDiff, deduped[0].totalScore, deduped[1].totalScore
                )
            } else {
                flagged = false
                flagReason = ""
            }
        } else {
            flagged = false
            flagReason = ""
        }

        return MappedSegment(
            linkId = entry.linkId,
            roadName = entry.roadName,
            roadCategory = entry.roadCategory,
            bestCandidate = best,
            allCandidates = deduped,
            flagged = flagged,
            flagReason = flagReason
        )
    }

    /**
     * Score a single candidate edge against the LTA segment.
     * Uses category-specific weights and distance tolerances.
     */
    private fun scoreCandidate(
        entry: SpeedBandEntry,
        edgeJson: JSONObject,
        edgeId: JSONObject,
        ltaBearing: Double,
        segmentLengthM: Double
    ): ScoredCandidate? {
        val level = edgeId.optInt("level", -1)
        val tileId = edgeId.optInt("tile_id", -1)
        val edgeIndex = edgeId.optInt("id", -1)
        if (level < 0 || tileId < 0 || edgeIndex < 0) return null

        val distanceM = edgeJson.optDouble("distance", 999.0)
        val edgeBearing = edgeJson.optDouble("heading", Double.NaN)

        // Road names and way ID are in edge_info
        val edgeInfo = edgeJson.optJSONObject("edge_info")
        val namesArray = edgeInfo?.optJSONArray("names")
        val osmName = if (namesArray != null && namesArray.length() > 0) namesArray.optString(0, "") else ""
        val osmWayId = edgeInfo?.optLong("way_id", 0L) ?: 0L

        // Road class is in edge.classification.classification
        val osmRoadClass = edgeJson.optJSONObject("edge")
            ?.optJSONObject("classification")
            ?.optString("classification", "") ?: ""

        val bearingDiff = if (!edgeBearing.isNaN()) {
            val diff = abs(ltaBearing - edgeBearing) % 360.0
            if (diff > 180.0) 360.0 - diff else diff
        } else {
            90.0 // worst case when no bearing available
        }

        // Get category-specific scoring config
        val cfg = CATEGORY_SCORING[entry.roadCategory] ?: DEFAULT_SCORING

        val distScore = computeDistanceScore(distanceM, cfg.distPerfectM, cfg.distMaxM)
        // For very short segments (< 20m), bearing from Haversine is unreliable — use neutral score
        val bearingScore = if (segmentLengthM < SHORT_SEGMENT_THRESHOLD_M) 0.5
            else computeBearingScore(bearingDiff)
        val nameScore = computeNameScore(entry.roadName, osmName)
        val catScore = computeCategoryScore(entry.roadCategory, osmRoadClass)

        val totalScore = cfg.weightDistance * distScore +
                cfg.weightBearing * bearingScore +
                cfg.weightName * nameScore +
                cfg.weightCategory * catScore

        val confidence = when {
            totalScore >= 0.75 -> ConfidenceLevel.HIGH
            totalScore >= 0.50 -> ConfidenceLevel.MEDIUM
            totalScore >= 0.25 -> ConfidenceLevel.LOW
            else -> ConfidenceLevel.NONE
        }

        return ScoredCandidate(
            edge = MappedEdge(level, tileId, edgeIndex),
            totalScore = totalScore,
            confidence = confidence,
            distanceM = distanceM,
            bearingDiffDeg = bearingDiff,
            roadNameMatch = nameScore >= 0.8,
            categoryMatch = catScore >= 0.5,
            osmRoadName = osmName,
            osmRoadClass = osmRoadClass,
            osmWayId = osmWayId
        )
    }

    /**
     * Approximate distance in metres between two coordinates using equirectangular projection.
     * Accurate enough for short distances in Singapore (~1.3° N latitude).
     */
    private fun approximateDistanceM(lat1: Double, lon1: Double, lat2: Double, lon2: Double): Double {
        val dLat = Math.toRadians(lat2 - lat1)
        val dLon = Math.toRadians(lon2 - lon1) * cos(Math.toRadians((lat1 + lat2) / 2.0))
        return sqrt(dLat * dLat + dLon * dLon) * 6_371_000.0 // Earth radius in metres
    }

    /**
     * Compute initial bearing from start to end using the Haversine formula.
     * Returns degrees in [0, 360).
     */
    private fun computeLtaBearing(startLat: Double, startLon: Double, endLat: Double, endLon: Double): Double {
        val lat1 = Math.toRadians(startLat)
        val lat2 = Math.toRadians(endLat)
        val dLon = Math.toRadians(endLon - startLon)

        val x = sin(dLon) * cos(lat2)
        val y = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)

        val bearing = Math.toDegrees(atan2(x, y))
        return (bearing + 360.0) % 360.0
    }

    /**
     * Distance score: 1.0 if <= perfectM, linear decay to 0.0 at maxM.
     * Thresholds vary by road category (expressways have wider tolerance).
     */
    private fun computeDistanceScore(distanceM: Double, perfectM: Double, maxM: Double): Double {
        return when {
            distanceM <= perfectM -> 1.0
            distanceM >= maxM -> 0.0
            else -> 1.0 - (distanceM - perfectM) / (maxM - perfectM)
        }
    }

    /**
     * Bearing score: 1.0 if <=10deg, linear decay to 0.0 at 90deg.
     */
    private fun computeBearingScore(bearingDiffDeg: Double): Double {
        return when {
            bearingDiffDeg <= 10.0 -> 1.0
            bearingDiffDeg >= 90.0 -> 0.0
            else -> 1.0 - (bearingDiffDeg - 10.0) / 80.0
        }
    }

    /**
     * Name score: 1.0 exact/substring, 0.8 abbreviation match, 0.5 first-word match, 0.0 mismatch.
     * Returns 0.5 (neutral) when either name is blank — don't penalize for missing data.
     */
    private fun computeNameScore(ltaName: String, osmName: String): Double {
        if (ltaName.isBlank() || osmName.isBlank()) return 0.5

        val ltaNorm = normalizeRoadName(ltaName)
        val osmNorm = normalizeRoadName(osmName)

        // Exact or substring match
        if (ltaNorm == osmNorm || ltaNorm in osmNorm || osmNorm in ltaNorm) return 1.0

        // Abbreviation expansion match
        val ltaExpanded = expandAbbreviation(ltaNorm)
        val osmExpanded = expandAbbreviation(osmNorm)
        if (ltaExpanded == osmExpanded || ltaExpanded in osmExpanded || osmExpanded in ltaExpanded) return 0.8

        // First-word match
        val ltaFirst = ltaNorm.split(" ").firstOrNull() ?: ""
        val osmFirst = osmNorm.split(" ").firstOrNull() ?: ""
        if (ltaFirst.isNotBlank() && ltaFirst == osmFirst) return 0.5

        return 0.0
    }

    /**
     * Category score: 1.0 exact match, 0.5 adjacent category, 0.0 mismatch.
     *
     * Valhalla classification values include: motorway, trunk, primary, secondary,
     * tertiary, unclassified, residential, service_other. We normalize by stripping
     * suffixes like "_other" and "_link".
     */
    private fun computeCategoryScore(ltaCategory: String, osmRoadClass: String): Double {
        if (osmRoadClass.isBlank()) return 0.0

        // Normalize Valhalla classification: "service_other" -> "service", "motorway_link" -> "motorway"
        val osmNormalized = osmRoadClass.lowercase()
            .replace("_other", "")
            .replace("_link", "")
        val expectedClasses = LTA_TO_OSM_CATEGORIES[ltaCategory] ?: return 0.0

        if (osmNormalized in expectedClasses) return 1.0

        // Adjacent category: check if osmRoadClass matches any neighbouring LTA category
        val ltaCatInt = ltaCategory.toIntOrNull() ?: return 0.0
        for (offset in listOf(-1, 1)) {
            val neighbour = (ltaCatInt + offset).toString()
            val neighbourClasses = LTA_TO_OSM_CATEGORIES[neighbour] ?: continue
            if (osmNormalized in neighbourClasses) return 0.5
        }

        return 0.0
    }

    /**
     * Normalize a road name for comparison: uppercase, trim, collapse whitespace.
     */
    private fun normalizeRoadName(name: String): String {
        return name.uppercase().trim().replace(Regex("\\s+"), " ")
    }

    /**
     * Expand Singapore road abbreviations commonly used by LTA.
     */
    private fun expandAbbreviation(name: String): String {
        return name.split(" ").joinToString(" ") { word -> SG_ABBREVIATIONS[word] ?: word }
    }

    private fun buildSummary(segments: Map<String, MappedSegment>): MappingSummary {
        var mapped = 0
        var unmapped = 0
        var high = 0
        var medium = 0
        var low = 0
        var flagged = 0
        val byCategoryMap = mutableMapOf<String, MutableList<MappedSegment>>()

        for (seg in segments.values) {
            if (seg.bestCandidate != null) {
                mapped++
                when (seg.bestCandidate.confidence) {
                    ConfidenceLevel.HIGH -> high++
                    ConfidenceLevel.MEDIUM -> medium++
                    ConfidenceLevel.LOW -> low++
                    ConfidenceLevel.NONE -> { /* counted as mapped but no confidence bucket */ }
                }
            } else {
                unmapped++
            }
            if (seg.flagged) flagged++
            byCategoryMap.getOrPut(seg.roadCategory) { mutableListOf() }.add(seg)
        }

        val byCategory = byCategoryMap.map { (cat, segs) ->
            val catName = CATEGORY_NAMES[cat] ?: "Unknown ($cat)"
            val catHigh = segs.count { it.bestCandidate?.confidence == ConfidenceLevel.HIGH }
            val catMed = segs.count { it.bestCandidate?.confidence == ConfidenceLevel.MEDIUM }
            val catLow = segs.count { it.bestCandidate?.confidence == ConfidenceLevel.LOW }
            val catUnmapped = segs.count { it.bestCandidate == null }
            val catFlagged = segs.count { it.flagged }
            cat to CategoryStats(catName, segs.size, catHigh, catMed, catLow, catUnmapped, catFlagged)
        }.toMap()

        return MappingSummary(
            total = segments.size,
            mapped = mapped,
            unmapped = unmapped,
            highConfidence = high,
            mediumConfidence = medium,
            lowConfidence = low,
            flagged = flagged,
            byCategory = byCategory
        )
    }

    companion object {
        private const val AMBIGUITY_THRESHOLD = 0.10
        private const val SHORT_SEGMENT_THRESHOLD_M = 20.0

        /**
         * Category-specific scoring weights and distance tolerances.
         *
         * Expressways: wider distance tolerance (80m), high bearing weight (50%)
         * — they're physically wide and direction is very clear.
         *
         * Small roads: tight distance tolerance (30m), high distance weight (40%)
         * — they're close together so distance precision is critical.
         */
        private data class ScoringConfig(
            val weightDistance: Double,
            val weightBearing: Double,
            val weightName: Double,
            val weightCategory: Double,
            val distPerfectM: Double,
            val distMaxM: Double
        )

        private val DEFAULT_SCORING = ScoringConfig(
            weightDistance = 0.35, weightBearing = 0.30, weightName = 0.20, weightCategory = 0.15,
            distPerfectM = 5.0, distMaxM = 35.0
        )

        private val CATEGORY_SCORING = mapOf(
            // Expressway: wide roads, clear direction → bearing-heavy, wide distance tolerance
            "1" to ScoringConfig(0.15, 0.50, 0.20, 0.15, distPerfectM = 10.0, distMaxM = 80.0),
            // Major Arterial: moderate width → balanced
            "2" to ScoringConfig(0.25, 0.35, 0.25, 0.15, distPerfectM = 8.0, distMaxM = 50.0),
            // Arterial: moderate
            "3" to ScoringConfig(0.30, 0.30, 0.25, 0.15, distPerfectM = 6.0, distMaxM = 40.0),
            // Minor Arterial: narrower roads → distance matters more
            "4" to ScoringConfig(0.35, 0.25, 0.25, 0.15, distPerfectM = 5.0, distMaxM = 35.0),
            // Small Road: narrow, close together → distance-heavy, tight tolerance
            "5" to ScoringConfig(0.40, 0.20, 0.25, 0.15, distPerfectM = 5.0, distMaxM = 30.0),
            // Slip Road: curvy ramps on/off expressways → low bearing weight, distance + category matter more
            "6" to ScoringConfig(0.30, 0.20, 0.25, 0.25, distPerfectM = 8.0, distMaxM = 50.0),
            // Short Tunnel: mixed characteristics
            "8" to ScoringConfig(0.25, 0.35, 0.25, 0.15, distPerfectM = 8.0, distMaxM = 50.0)
        )

        /** LTA road category code -> set of compatible OSM road classes (lowercase). */
        private val LTA_TO_OSM_CATEGORIES = mapOf(
            "1" to setOf("motorway"),
            "2" to setOf("trunk", "primary"),
            "3" to setOf("primary", "secondary"),
            "4" to setOf("secondary", "tertiary"),
            "5" to setOf("residential", "unclassified", "service"),
            "6" to setOf("motorway", "trunk", "primary"),
            "8" to setOf("motorway", "trunk", "primary", "secondary", "tertiary", "residential", "unclassified", "service")
        )

        /** LTA category code -> human-readable name. */
        private val CATEGORY_NAMES = mapOf(
            "1" to "Expressway",
            "2" to "Major Arterial",
            "3" to "Arterial",
            "4" to "Minor Arterial",
            "5" to "Small Road",
            "6" to "Slip Road",
            "8" to "Short Tunnel"
        )

        /** Singapore expressway and road abbreviations. */
        private val SG_ABBREVIATIONS = mapOf(
            "PIE" to "PAN ISLAND EXPRESSWAY",
            "CTE" to "CENTRAL EXPRESSWAY",
            "AYE" to "AYER RAJAH EXPRESSWAY",
            "ECP" to "EAST COAST PARKWAY",
            "BKE" to "BUKIT TIMAH EXPRESSWAY",
            "SLE" to "SELETAR EXPRESSWAY",
            "TPE" to "TAMPINES EXPRESSWAY",
            "KPE" to "KALLANG PAYA LEBAR EXPRESSWAY",
            "KJE" to "KRANJI EXPRESSWAY",
            "MCE" to "MARINA COASTAL EXPRESSWAY",
            "NSE" to "NORTH SOUTH EXPRESSWAY",
            "AVE" to "AVENUE",
            "RD" to "ROAD",
            "DR" to "DRIVE",
            "ST" to "STREET",
            "BLVD" to "BOULEVARD",
            "CRES" to "CRESCENT",
            "HWY" to "HIGHWAY",
            "LN" to "LANE",
            "PL" to "PLACE",
            "SQ" to "SQUARE",
            "CTRL" to "CENTRAL"
        )
    }
}

/**
 * A Valhalla directed edge identified by tile coordinates.
 *
 * @property tileLevel Graph hierarchy level (0, 1, or 2)
 * @property tileId Tile identifier within the level
 * @property edgeIndex Directed edge index within the tile
 */
data class MappedEdge(
    val tileLevel: Int,
    val tileId: Int,
    val edgeIndex: Int
)

/**
 * Identifies a Valhalla graph tile by level and tile ID.
 */
data class TileKey(val level: Int, val tileId: Int)

/**
 * Complete bidirectional mapping between LTA segments and Valhalla edges.
 *
 * @property linkToEdges LTA linkId → Valhalla edges
 * @property tileToEdges Valhalla tile → set of edge indices with LTA data
 * @property totalMapped Number of successfully mapped LTA segments
 * @property totalUnmapped Number of LTA segments that could not be mapped
 */
data class EdgeMapping(
    val linkToEdges: Map<String, List<MappedEdge>>,
    val tileToEdges: Map<TileKey, Set<Int>>,
    val totalMapped: Int,
    val totalUnmapped: Int
)
