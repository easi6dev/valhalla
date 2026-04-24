package global.tada.valhalla.traffic.sg

import global.tada.valhalla.Actor
import global.tada.valhalla.traffic.mapping.GeometryMappingCache
import global.tada.valhalla.traffic.mapping.GeometryMappingService
import global.tada.valhalla.traffic.mapping.MappingReportGenerator
import org.slf4j.LoggerFactory

/**
 * Standalone job that builds a confidence-scored geometry mapping from LTA road
 * segments to Valhalla/OSM edges.
 *
 * Designed to run as a batch job or K8s Job:
 *   - Fetches speed bands from LTA API
 *   - Runs locate() for every segment (~144k calls, ~15-25 min)
 *   - Scores all candidates on distance/bearing/name/category
 *   - Writes v2 mapping cache with confidence scores
 *   - Generates text and JSON coverage reports
 *   - Exits with status code
 *
 * Configuration via environment variables:
 *   - LTA_ACCOUNT_KEY (required) — LTA DataMall API key
 *   - VALHALLA_TILE_DIR (required) — path to Singapore tiles directory
 *   - GEOMETRY_MAPPING_CACHE_PATH (default: data/geometry_mapping.json)
 *   - GEOMETRY_MAPPING_REPORT_PATH (default: data/geometry_mapping_report.txt)
 *   - GEOMETRY_MAPPING_JSON_REPORT_PATH (default: data/geometry_mapping_report.json)
 *
 * Exit codes:
 *   - 0: Success, acceptance criteria met
 *   - 1: Success, but below acceptance threshold
 *   - 2: Failure (config error, API error, etc.)
 */
object GeometryMappingJob {

    private val logger = LoggerFactory.getLogger(GeometryMappingJob::class.java)

    private const val DEFAULT_CACHE_PATH = "data/geometry_mapping.json"
    private const val DEFAULT_TEXT_REPORT_PATH = "data/geometry_mapping_report.txt"
    private const val DEFAULT_JSON_REPORT_PATH = "data/geometry_mapping_report.json"

    @JvmStatic
    fun main(args: Array<String>) {
        System.exit(run())
    }

    /**
     * Execute the geometry mapping job.
     *
     * @return 0 on success (acceptance met), 1 on success (below threshold), 2 on failure
     */
    @JvmStatic
    fun run(): Int {
        logger.info("=== Geometry Mapping Job starting ===")

        // 1. Load config
        val config: LtaConfig
        try {
            config = LtaConfig.fromEnvironment()
        } catch (e: Exception) {
            logger.error("Failed to load LTA config: {}", e.message)
            return 2
        }

        val tileDir = System.getenv("VALHALLA_TILE_DIR")
        if (tileDir.isNullOrBlank()) {
            logger.error("VALHALLA_TILE_DIR environment variable is required")
            return 2
        }

        val cachePath = System.getenv("GEOMETRY_MAPPING_CACHE_PATH") ?: DEFAULT_CACHE_PATH
        val textReportPath = System.getenv("GEOMETRY_MAPPING_REPORT_PATH") ?: DEFAULT_TEXT_REPORT_PATH
        val jsonReportPath = System.getenv("GEOMETRY_MAPPING_JSON_REPORT_PATH") ?: DEFAULT_JSON_REPORT_PATH

        // 2. Create Actor for Singapore
        val actor: Actor
        try {
            actor = Actor.createForRegion("singapore", tileDir)
            logger.info("Actor created with tile dir: {}", tileDir)
        } catch (e: Exception) {
            logger.error("Failed to create Actor: {}", e.message)
            return 2
        }

        try {
            // 3. Fetch speed bands
            logger.info("Fetching speed bands from LTA API...")
            val apiClient = LtaApiClient(config)
            val speedBands = apiClient.fetchSpeedBands()
            logger.info("Fetched {} speed band segments", speedBands.size)

            if (speedBands.isEmpty()) {
                logger.error("No speed band data returned from LTA API")
                return 2
            }

            // 4. Build geometry mapping
            logger.info("Building geometry mapping ({} segments, this may take 15-25 minutes)...", speedBands.size)
            val startMs = System.currentTimeMillis()

            val service = GeometryMappingService(actor::locate)
            val mapping = service.buildMapping(speedBands)

            val elapsedSec = (System.currentTimeMillis() - startMs) / 1000.0
            logger.info("Mapping completed in %.1f seconds".format(elapsedSec))

            // 5. Save v2 cache
            GeometryMappingCache.save(mapping, cachePath)

            // 6. Generate reports
            val report = MappingReportGenerator.generateReport(mapping, speedBands)
            MappingReportGenerator.writeTextReport(report, textReportPath)
            MappingReportGenerator.writeJsonReport(report, jsonReportPath)

            // 7. Log summary
            val s = mapping.summary
            val mappedPct = if (s.total > 0) "%.1f".format(s.mapped * 100.0 / s.total) else "0.0"
            val highPct = if (s.total > 0) "%.1f".format(s.highConfidence * 100.0 / s.total) else "0.0"
            logger.info("=== Geometry Mapping Job Summary ===")
            logger.info("Total segments:     {}", s.total)
            logger.info("Mapped:             {} ({}%)", s.mapped, mappedPct)
            logger.info("High confidence:    {} ({}%)", s.highConfidence, highPct)
            logger.info("Medium confidence:  {}", s.mediumConfidence)
            logger.info("Low confidence:     {}", s.lowConfidence)
            logger.info("Unmapped:           {}", s.unmapped)
            logger.info("Flagged:            {}", s.flagged)
            logger.info("Acceptance met:     {}", report.acceptanceCriteriaMet)
            logger.info("Cache:              {}", cachePath)
            logger.info("Text report:        {}", textReportPath)
            logger.info("JSON report:        {}", jsonReportPath)

            // 8. Verify legacy conversion
            val legacy = GeometryMappingCache.toLegacyEdgeMapping(mapping)
            logger.info("Legacy EdgeMapping: {} mapped, {} unmapped", legacy.totalMapped, legacy.totalUnmapped)

            return if (report.acceptanceCriteriaMet) 0 else 1

        } catch (e: Exception) {
            logger.error("Geometry mapping job failed: {}", e.message, e)
            return 2
        } finally {
            // 9. Close Actor
            try {
                actor.close()
                logger.info("Actor closed")
            } catch (e: Exception) {
                logger.warn("Failed to close Actor: {}", e.message)
            }
            logger.info("=== Geometry Mapping Job finished ===")
        }
    }
}
