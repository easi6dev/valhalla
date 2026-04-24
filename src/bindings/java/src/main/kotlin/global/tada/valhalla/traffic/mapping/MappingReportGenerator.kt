package global.tada.valhalla.traffic.mapping

import global.tada.valhalla.traffic.models.SpeedBandEntry
import org.json.JSONArray
import org.json.JSONObject
import org.slf4j.LoggerFactory
import java.io.File
import java.time.Instant

/**
 * Coverage statistics for a category or overall mapping.
 */
data class CoverageStats(
    val categoryName: String,
    val total: Int,
    val mapped: Int,
    val highConfidence: Int,
    val mediumConfidence: Int,
    val lowConfidence: Int,
    val unmapped: Int,
    val flagged: Int,
    val highConfidencePercent: Double,
    val meetsTarget: Boolean
)

/**
 * A flagged segment entry for the report.
 */
data class FlaggedEntry(
    val linkId: String,
    val roadName: String,
    val roadCategory: String,
    val bestScore: Double,
    val runnerUpScore: Double,
    val flagReason: String
)

/**
 * An unmapped segment entry for the report.
 */
data class UnmappedEntry(
    val linkId: String,
    val roadName: String,
    val roadCategory: String,
    val startLat: Double,
    val startLon: Double,
    val endLat: Double,
    val endLon: Double
)

/**
 * Per-road coverage summary.
 */
data class RoadCoverage(
    val roadName: String,
    val totalSegments: Int,
    val unmappedCount: Int,
    val unmappedPercent: Double
)

/**
 * Complete mapping report with coverage stats, flagged segments, and acceptance criteria.
 */
data class MappingReport(
    val generatedAt: String,
    val overall: CoverageStats,
    val byCategory: Map<String, CoverageStats>,
    val flaggedSegments: List<FlaggedEntry>,
    val unmappedSegments: List<UnmappedEntry>,
    val topUnmappedRoads: List<RoadCoverage>,
    val acceptanceCriteriaMet: Boolean
)

/**
 * Generates human-readable and machine-parseable reports from a [GeometryMapping].
 *
 * Reports include overall and per-category coverage statistics, flagged (ambiguous)
 * segments, unmapped segments, and acceptance criteria checks.
 */
object MappingReportGenerator {

    private val logger = LoggerFactory.getLogger(MappingReportGenerator::class.java)

    /** High-confidence target percentage for acceptance criteria. */
    private const val HIGH_CONFIDENCE_TARGET = 80.0

    /** Maximum number of flagged segments to include in the text report. */
    private const val MAX_FLAGGED_IN_REPORT = 20

    /** Maximum number of unmapped roads to include in the text report. */
    private const val MAX_UNMAPPED_ROADS_IN_REPORT = 10

    /**
     * Generate a mapping report from a geometry mapping and the original speed band data.
     *
     * @param mapping The geometry mapping result
     * @param speedBands The original speed band entries (used for unmapped segment coordinates)
     * @return A complete mapping report
     */
    @JvmStatic
    fun generateReport(mapping: GeometryMapping, speedBands: List<SpeedBandEntry>): MappingReport {
        val speedBandMap = speedBands.associateBy { it.linkId }

        // Overall stats
        val overall = buildCoverageStats("Overall", mapping.summary)

        // Per-category stats
        val byCategory = mapping.summary.byCategory.map { (cat, catStats) ->
            cat to buildCoverageStatsFromCategory(catStats)
        }.toMap()

        // Flagged segments
        val flaggedSegments = mapping.segments.values
            .filter { it.flagged && it.bestCandidate != null }
            .sortedByDescending { it.bestCandidate?.totalScore ?: 0.0 }
            .map { seg ->
                val runnerUp = if (seg.allCandidates.size >= 2) seg.allCandidates[1].totalScore else 0.0
                FlaggedEntry(
                    linkId = seg.linkId,
                    roadName = seg.roadName,
                    roadCategory = seg.roadCategory,
                    bestScore = seg.bestCandidate?.totalScore ?: 0.0,
                    runnerUpScore = runnerUp,
                    flagReason = seg.flagReason
                )
            }

        // Unmapped segments
        val unmappedSegments = mapping.segments.values
            .filter { it.bestCandidate == null }
            .map { seg ->
                val entry = speedBandMap[seg.linkId]
                UnmappedEntry(
                    linkId = seg.linkId,
                    roadName = seg.roadName,
                    roadCategory = seg.roadCategory,
                    startLat = entry?.startLat ?: 0.0,
                    startLon = entry?.startLon ?: 0.0,
                    endLat = entry?.endLat ?: 0.0,
                    endLon = entry?.endLon ?: 0.0
                )
            }

        // Top unmapped roads (grouped by road name)
        val topUnmappedRoads = buildTopUnmappedRoads(mapping, speedBands)

        // Acceptance criteria: expressways and major arterials must meet target
        val expresswayStats = byCategory["1"]
        val majorArterialStats = byCategory["2"]
        val acceptanceMet = (expresswayStats?.meetsTarget ?: true) &&
                (majorArterialStats?.meetsTarget ?: true)

        return MappingReport(
            generatedAt = Instant.now().toString(),
            overall = overall,
            byCategory = byCategory,
            flaggedSegments = flaggedSegments,
            unmappedSegments = unmappedSegments,
            topUnmappedRoads = topUnmappedRoads,
            acceptanceCriteriaMet = acceptanceMet
        )
    }

    /**
     * Write a human-readable text report to a file.
     */
    @JvmStatic
    fun writeTextReport(report: MappingReport, path: String) {
        val sb = StringBuilder()

        sb.appendLine("=".repeat(60))
        sb.appendLine("LTA -> OSM Geometry Mapping Report")
        sb.appendLine("Generated: ${report.generatedAt}")
        sb.appendLine("=".repeat(60))
        sb.appendLine()

        // Overall
        val o = report.overall
        sb.appendLine("OVERALL: %,d segments, %,d mapped (%.1f%%), %,d high-confidence (%.1f%%)".format(
            o.total, o.mapped,
            if (o.total > 0) o.mapped * 100.0 / o.total else 0.0,
            o.highConfidence, o.highConfidencePercent
        ))
        sb.appendLine()

        // By category
        sb.appendLine("BY CATEGORY:")
        val categoryOrder = listOf("1", "2", "3", "4", "5", "6", "8")
        for (cat in categoryOrder) {
            val stats = report.byCategory[cat] ?: continue
            val passLabel = if (stats.meetsTarget) "PASS >= ${HIGH_CONFIDENCE_TARGET.toInt()}%" else ""
            sb.appendLine("  %s %-16s %,6d total, %5.1f%% high-confidence  %s".format(
                cat, stats.categoryName + ":", stats.total,
                stats.highConfidencePercent, passLabel
            ).trimEnd())
        }
        sb.appendLine()

        // Flagged segments
        sb.appendLine("FLAGGED (ambiguous): %,d segments".format(report.flaggedSegments.size))
        if (report.flaggedSegments.isNotEmpty()) {
            val shown = report.flaggedSegments.take(MAX_FLAGGED_IN_REPORT)
            for (f in shown) {
                sb.appendLine("  linkId=%-12s %-20s cat=%s  best=%.3f runner=%.3f  %s".format(
                    f.linkId, f.roadName.take(20), f.roadCategory,
                    f.bestScore, f.runnerUpScore, f.flagReason
                ))
            }
            if (report.flaggedSegments.size > MAX_FLAGGED_IN_REPORT) {
                sb.appendLine("  ... and %,d more".format(report.flaggedSegments.size - MAX_FLAGGED_IN_REPORT))
            }
        }
        sb.appendLine()

        // Unmapped segments
        sb.appendLine("UNMAPPED: %,d segments".format(report.unmappedSegments.size))
        if (report.topUnmappedRoads.isNotEmpty()) {
            sb.appendLine("Top unmapped roads:")
            for (road in report.topUnmappedRoads.take(MAX_UNMAPPED_ROADS_IN_REPORT)) {
                sb.appendLine("  %-25s %,4d / %,4d segments unmapped (%.1f%%)".format(
                    road.roadName.take(25), road.unmappedCount, road.totalSegments, road.unmappedPercent
                ))
            }
        }
        sb.appendLine()

        // Acceptance
        sb.appendLine("=".repeat(60))
        if (report.acceptanceCriteriaMet) {
            sb.appendLine("ACCEPTANCE CRITERIA: PASSED")
        } else {
            sb.appendLine("ACCEPTANCE CRITERIA: FAILED")
            sb.appendLine("  Expressway and Major Arterial categories must have >= ${HIGH_CONFIDENCE_TARGET.toInt()}% high-confidence.")
        }
        sb.appendLine("=".repeat(60))

        val file = File(path)
        file.parentFile?.mkdirs()
        file.writeText(sb.toString())

        logger.info("Text report written to {}", path)
    }

    /**
     * Write a machine-parseable JSON report to a file.
     */
    @JvmStatic
    fun writeJsonReport(report: MappingReport, path: String) {
        val json = JSONObject().apply {
            put("generatedAt", report.generatedAt)
            put("acceptanceCriteriaMet", report.acceptanceCriteriaMet)
            put("overall", coverageStatsToJson(report.overall))
            put("byCategory", JSONObject().apply {
                for ((cat, stats) in report.byCategory) {
                    put(cat, coverageStatsToJson(stats))
                }
            })
            put("flaggedCount", report.flaggedSegments.size)
            put("flaggedSegments", JSONArray().apply {
                for (f in report.flaggedSegments) {
                    put(JSONObject().apply {
                        put("linkId", f.linkId)
                        put("roadName", f.roadName)
                        put("roadCategory", f.roadCategory)
                        put("bestScore", f.bestScore)
                        put("runnerUpScore", f.runnerUpScore)
                        put("flagReason", f.flagReason)
                    })
                }
            })
            put("unmappedCount", report.unmappedSegments.size)
            put("unmappedSegments", JSONArray().apply {
                for (u in report.unmappedSegments) {
                    put(JSONObject().apply {
                        put("linkId", u.linkId)
                        put("roadName", u.roadName)
                        put("roadCategory", u.roadCategory)
                        put("startLat", u.startLat)
                        put("startLon", u.startLon)
                        put("endLat", u.endLat)
                        put("endLon", u.endLon)
                    })
                }
            })
            put("topUnmappedRoads", JSONArray().apply {
                for (r in report.topUnmappedRoads) {
                    put(JSONObject().apply {
                        put("roadName", r.roadName)
                        put("totalSegments", r.totalSegments)
                        put("unmappedCount", r.unmappedCount)
                        put("unmappedPercent", r.unmappedPercent)
                    })
                }
            })
        }

        val file = File(path)
        file.parentFile?.mkdirs()
        file.writeText(json.toString(2))

        logger.info("JSON report written to {}", path)
    }

    private fun buildCoverageStats(name: String, summary: MappingSummary): CoverageStats {
        val highPct = if (summary.total > 0) summary.highConfidence * 100.0 / summary.total else 0.0
        return CoverageStats(
            categoryName = name,
            total = summary.total,
            mapped = summary.mapped,
            highConfidence = summary.highConfidence,
            mediumConfidence = summary.mediumConfidence,
            lowConfidence = summary.lowConfidence,
            unmapped = summary.unmapped,
            flagged = summary.flagged,
            highConfidencePercent = highPct,
            meetsTarget = highPct >= HIGH_CONFIDENCE_TARGET
        )
    }

    private fun buildCoverageStatsFromCategory(catStats: CategoryStats): CoverageStats {
        val highPct = if (catStats.total > 0) catStats.highConfidence * 100.0 / catStats.total else 0.0
        return CoverageStats(
            categoryName = catStats.categoryName,
            total = catStats.total,
            mapped = catStats.total - catStats.unmapped,
            highConfidence = catStats.highConfidence,
            mediumConfidence = catStats.mediumConfidence,
            lowConfidence = catStats.lowConfidence,
            unmapped = catStats.unmapped,
            flagged = catStats.flagged,
            highConfidencePercent = highPct,
            meetsTarget = highPct >= HIGH_CONFIDENCE_TARGET
        )
    }

    private fun buildTopUnmappedRoads(
        mapping: GeometryMapping,
        speedBands: List<SpeedBandEntry>
    ): List<RoadCoverage> {
        // Group all segments by road name
        val byRoad = mutableMapOf<String, MutableList<String>>()
        for (entry in speedBands) {
            if (entry.roadName.isNotBlank()) {
                byRoad.getOrPut(entry.roadName) { mutableListOf() }.add(entry.linkId)
            }
        }

        return byRoad.map { (roadName, linkIds) ->
            val unmappedCount = linkIds.count { linkId ->
                val seg = mapping.segments[linkId]
                seg == null || seg.bestCandidate == null
            }
            RoadCoverage(
                roadName = roadName,
                totalSegments = linkIds.size,
                unmappedCount = unmappedCount,
                unmappedPercent = if (linkIds.isNotEmpty()) unmappedCount * 100.0 / linkIds.size else 0.0
            )
        }
            .filter { it.unmappedCount > 0 }
            .sortedByDescending { it.unmappedCount }
    }

    private fun coverageStatsToJson(stats: CoverageStats): JSONObject {
        return JSONObject().apply {
            put("categoryName", stats.categoryName)
            put("total", stats.total)
            put("mapped", stats.mapped)
            put("highConfidence", stats.highConfidence)
            put("mediumConfidence", stats.mediumConfidence)
            put("lowConfidence", stats.lowConfidence)
            put("unmapped", stats.unmapped)
            put("flagged", stats.flagged)
            put("highConfidencePercent", stats.highConfidencePercent)
            put("meetsTarget", stats.meetsTarget)
        }
    }
}
