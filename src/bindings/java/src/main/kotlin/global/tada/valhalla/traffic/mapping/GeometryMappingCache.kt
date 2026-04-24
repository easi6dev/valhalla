package global.tada.valhalla.traffic.mapping

import org.json.JSONArray
import org.json.JSONObject
import org.slf4j.LoggerFactory
import java.io.File
import java.time.Instant

/**
 * Persists geometry-based mapping (v2 format) to disk as JSON.
 *
 * The v2 format includes confidence scores, candidate counts, and per-segment
 * scoring details. It can be converted to the v1 [EdgeMapping] format for
 * backward compatibility with the existing traffic pipeline.
 */
object GeometryMappingCache {

    private val logger = LoggerFactory.getLogger(GeometryMappingCache::class.java)

    private const val CACHE_VERSION = 2

    /**
     * Save a geometry mapping to a JSON file (v2 format).
     *
     * @param mapping The geometry mapping to persist
     * @param path File path to write to
     */
    @JvmStatic
    fun save(mapping: GeometryMapping, path: String) {
        val json = JSONObject().apply {
            put("version", CACHE_VERSION)
            put("generatedAt", Instant.now().toString())
            put("stats", JSONObject().apply {
                put("total", mapping.summary.total)
                put("mapped", mapping.summary.mapped)
                put("unmapped", mapping.summary.unmapped)
                put("highConfidence", mapping.summary.highConfidence)
                put("mediumConfidence", mapping.summary.mediumConfidence)
                put("lowConfidence", mapping.summary.lowConfidence)
                put("flagged", mapping.summary.flagged)
            })
            put("mappings", JSONArray().apply {
                for ((_, seg) in mapping.segments) {
                    put(JSONObject().apply {
                        put("linkId", seg.linkId)
                        put("roadName", seg.roadName)
                        put("roadCategory", seg.roadCategory)
                        put("score", seg.bestCandidate?.totalScore ?: 0.0)
                        put("confidence", seg.bestCandidate?.confidence?.name ?: "NONE")
                        put("flagged", seg.flagged)
                        if (seg.flagged && seg.flagReason.isNotEmpty()) {
                            put("flagReason", seg.flagReason)
                        }
                        put("edges", JSONArray().apply {
                            if (seg.bestCandidate != null) {
                                put(JSONObject().apply {
                                    put("level", seg.bestCandidate.edge.tileLevel)
                                    put("tileId", seg.bestCandidate.edge.tileId)
                                    put("edgeIndex", seg.bestCandidate.edge.edgeIndex)
                                    put("score", seg.bestCandidate.totalScore)
                                    put("distanceM", seg.bestCandidate.distanceM)
                                    put("bearingDiffDeg", seg.bestCandidate.bearingDiffDeg)
                                    put("nameMatch", seg.bestCandidate.roadNameMatch)
                                    put("categoryMatch", seg.bestCandidate.categoryMatch)
                                    put("osmWayId", seg.bestCandidate.osmWayId)
                                })
                            }
                        })
                        put("candidateCount", seg.allCandidates.size)
                    })
                }
            })
        }

        val file = File(path)
        file.parentFile?.mkdirs()
        file.writeText(json.toString(2))

        logger.info(
            "Geometry mapping saved to {} ({} segments, {} high-confidence)",
            path, mapping.summary.total, mapping.summary.highConfidence
        )
    }

    /**
     * Load a geometry mapping from a JSON file (v2 format).
     *
     * @param path File path to read from
     * @return The loaded geometry mapping, or null if file doesn't exist or is invalid
     */
    @JvmStatic
    fun load(path: String): GeometryMapping? {
        val file = File(path)
        if (!file.exists()) {
            logger.debug("No cached geometry mapping at {}", path)
            return null
        }

        return try {
            val json = JSONObject(file.readText())
            val version = json.optInt("version", 0)
            if (version != CACHE_VERSION) {
                logger.warn("Unsupported geometry mapping cache version: {} (expected {})", version, CACHE_VERSION)
                return null
            }

            val segments = mutableMapOf<String, MappedSegment>()
            val tileToEdges = mutableMapOf<TileKey, MutableSet<Int>>()
            val mappings = json.getJSONArray("mappings")

            for (i in 0 until mappings.length()) {
                val entry = mappings.getJSONObject(i)
                val linkId = entry.getString("linkId")
                val roadName = entry.optString("roadName", "")
                val roadCategory = entry.optString("roadCategory", "")
                val score = entry.optDouble("score", 0.0)
                val confidenceStr = entry.optString("confidence", "NONE")
                val flagged = entry.optBoolean("flagged", false)
                val flagReason = entry.optString("flagReason", "")
                val edgesArray = entry.optJSONArray("edges") ?: JSONArray()
                val candidates = mutableListOf<ScoredCandidate>()

                for (j in 0 until edgesArray.length()) {
                    val edgeObj = edgesArray.getJSONObject(j)
                    val edge = MappedEdge(
                        tileLevel = edgeObj.getInt("level"),
                        tileId = edgeObj.getInt("tileId"),
                        edgeIndex = edgeObj.getInt("edgeIndex")
                    )
                    val candidate = ScoredCandidate(
                        edge = edge,
                        totalScore = edgeObj.optDouble("score", score),
                        confidence = try {
                            ConfidenceLevel.valueOf(confidenceStr)
                        } catch (_: Exception) {
                            ConfidenceLevel.NONE
                        },
                        distanceM = edgeObj.optDouble("distanceM", 0.0),
                        bearingDiffDeg = edgeObj.optDouble("bearingDiffDeg", 0.0),
                        roadNameMatch = edgeObj.optBoolean("nameMatch", false),
                        categoryMatch = edgeObj.optBoolean("categoryMatch", false),
                        osmRoadName = "",
                        osmRoadClass = "",
                        osmWayId = edgeObj.optLong("osmWayId", 0L)
                    )
                    candidates.add(candidate)

                    val key = TileKey(edge.tileLevel, edge.tileId)
                    tileToEdges.getOrPut(key) { mutableSetOf() }.add(edge.edgeIndex)
                }

                segments[linkId] = MappedSegment(
                    linkId = linkId,
                    roadName = roadName,
                    roadCategory = roadCategory,
                    bestCandidate = candidates.firstOrNull(),
                    allCandidates = candidates,
                    flagged = flagged,
                    flagReason = flagReason
                )
            }

            val statsJson = json.optJSONObject("stats")
            val summary = if (statsJson != null) {
                MappingSummary(
                    total = statsJson.optInt("total", segments.size),
                    mapped = statsJson.optInt("mapped", 0),
                    unmapped = statsJson.optInt("unmapped", 0),
                    highConfidence = statsJson.optInt("highConfidence", 0),
                    mediumConfidence = statsJson.optInt("mediumConfidence", 0),
                    lowConfidence = statsJson.optInt("lowConfidence", 0),
                    flagged = statsJson.optInt("flagged", 0),
                    byCategory = emptyMap()
                )
            } else {
                val mapped = segments.values.count { it.bestCandidate != null }
                MappingSummary(
                    total = segments.size,
                    mapped = mapped,
                    unmapped = segments.size - mapped,
                    highConfidence = segments.values.count { it.bestCandidate?.confidence == ConfidenceLevel.HIGH },
                    mediumConfidence = segments.values.count { it.bestCandidate?.confidence == ConfidenceLevel.MEDIUM },
                    lowConfidence = segments.values.count { it.bestCandidate?.confidence == ConfidenceLevel.LOW },
                    flagged = segments.values.count { it.flagged },
                    byCategory = emptyMap()
                )
            }

            val mapping = GeometryMapping(
                segments = segments,
                tileToEdges = tileToEdges.mapValues { it.value.toSet() },
                summary = summary
            )

            logger.info("Geometry mapping loaded from {} ({} segments)", path, mapping.summary.total)
            mapping
        } catch (e: Exception) {
            logger.warn("Failed to load geometry mapping from {}: {}", path, e.message)
            null
        }
    }

    /**
     * Build a reverse index from OSM way ID to the list of [MappedEdge]s that share that way ID.
     *
     * Iterates all segments in the mapping, takes the best candidate's edge and osmWayId,
     * and groups edges by way ID. Entries with wayId=0 (unmapped) are skipped.
     *
     * @param mapping The geometry mapping to index
     * @return Map of osmWayId to the list of edges on that way
     */
    @JvmStatic
    fun buildWayIdIndex(mapping: GeometryMapping): Map<Long, List<MappedEdge>> {
        val index = mutableMapOf<Long, MutableList<MappedEdge>>()

        for ((_, seg) in mapping.segments) {
            val candidate = seg.bestCandidate ?: continue
            val wayId = candidate.osmWayId
            if (wayId == 0L) continue

            index.getOrPut(wayId) { mutableListOf() }.add(candidate.edge)
        }

        logger.debug("Built way ID index: {} unique OSM ways across {} segments", index.size, mapping.segments.size)
        return index
    }

    /**
     * Build a reverse index from OSM way ID to the road name (from the LTA segment).
     *
     * @param mapping The geometry mapping to index
     * @return Map of osmWayId to road name
     */
    @JvmStatic
    fun buildWayIdToRoadName(mapping: GeometryMapping): Map<Long, String> {
        val index = mutableMapOf<Long, String>()

        for ((_, seg) in mapping.segments) {
            val candidate = seg.bestCandidate ?: continue
            val wayId = candidate.osmWayId
            if (wayId == 0L) continue
            // Keep first encountered name (don't overwrite)
            index.putIfAbsent(wayId, seg.roadName)
        }

        return index
    }

    /**
     * Convert a v2 [GeometryMapping] to a v1 [EdgeMapping] for traffic pipeline compatibility.
     *
     * Only includes segments with a best candidate (mapped segments).
     *
     * @param mapping The geometry mapping to convert
     * @return A v1 EdgeMapping compatible with the traffic pipeline
     */
    @JvmStatic
    fun toLegacyEdgeMapping(mapping: GeometryMapping): EdgeMapping {
        val linkToEdges = mutableMapOf<String, List<MappedEdge>>()

        for ((linkId, seg) in mapping.segments) {
            if (seg.bestCandidate != null) {
                linkToEdges[linkId] = listOf(seg.bestCandidate.edge)
            }
        }

        return EdgeMapping(
            linkToEdges = linkToEdges,
            tileToEdges = mapping.tileToEdges,
            totalMapped = linkToEdges.size,
            totalUnmapped = mapping.summary.unmapped
        )
    }
}
