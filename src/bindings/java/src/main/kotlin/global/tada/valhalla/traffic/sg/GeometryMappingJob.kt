package global.tada.valhalla.traffic.sg

import global.tada.valhalla.Actor
import global.tada.valhalla.traffic.mapping.GeometryMappingCache
import global.tada.valhalla.traffic.mapping.GeometryMappingService
import global.tada.valhalla.traffic.mapping.MappingReportGenerator
import global.tada.valhalla.traffic.models.SpeedBandEntry
import org.json.JSONObject
import org.slf4j.LoggerFactory
import java.io.File
import java.nio.file.Files
import java.nio.file.NoSuchFileException
import java.nio.file.Path
import java.nio.file.Paths
import java.util.zip.GZIPInputStream

/**
 * Standalone job that builds a confidence-scored geometry mapping from LTA road
 * segments to Valhalla/OSM edges.
 *
 * Designed to run as a batch job or K8s Job:
 *   - Loads speed bands from the latest snapshot written by the Python LTA
 *     cron (`tada-valhalla-traffic` repo, DHL-24634) at:
 *       `{tile_dir}/../snapshots/speed_bands/{YYYY-MM-DD}/{HH-MM-SS}.json.gz`
 *   - Runs `Actor.locate()` for every segment (~144k calls, ~15-25 min)
 *   - Scores all candidates on distance/bearing/name/category
 *   - Writes v2 mapping cache with confidence scores
 *   - Generates text and JSON coverage reports
 *   - Exits with status code
 *
 * Configuration via environment variables:
 *   - `VALHALLA_TILE_DIR` (required) — path to Singapore tiles directory
 *   - `VALHALLA_SNAPSHOTS_DIR` (optional) — override snapshots dir; defaults
 *     to `{VALHALLA_TILE_DIR}/../snapshots/speed_bands`
 *   - `GEOMETRY_MAPPING_CACHE_PATH` (default: `data/geometry_mapping.json`)
 *   - `GEOMETRY_MAPPING_REPORT_PATH` (default: `data/geometry_mapping_report.txt`)
 *   - `GEOMETRY_MAPPING_JSON_REPORT_PATH` (default: `data/geometry_mapping_report.json`)
 *
 * Exit codes:
 *   - 0: Success, acceptance criteria met
 *   - 1: Success, but below acceptance threshold
 *   - 2: Failure (config error, no snapshot found, Actor failure, etc.)
 */
object GeometryMappingJob {

    private val logger = LoggerFactory.getLogger(GeometryMappingJob::class.java)

    private const val DEFAULT_CACHE_PATH = "data/geometry_mapping.json"
    private const val DEFAULT_TEXT_REPORT_PATH = "data/geometry_mapping_report.txt"
    private const val DEFAULT_JSON_REPORT_PATH = "data/geometry_mapping_report.json"

    /** Geometry mapping doesn't need fresh speeds — segments don't move minute-to-minute.
     *  But warn loudly if the LTA cron appears stalled. */
    private const val STALE_SNAPSHOT_WARNING_MINUTES = 30L

    @JvmStatic
    fun main(args: Array<String>) {
        System.exit(run())
    }

    /**
     * Execute the geometry mapping job: read env vars, load latest snapshot,
     * delegate to [runWithSpeedBands].
     */
    @JvmStatic
    fun run(): Int {
        logger.info("=== Geometry Mapping Job starting ===")

        val tileDir = System.getenv("VALHALLA_TILE_DIR")
        if (tileDir.isNullOrBlank()) {
            logger.error("VALHALLA_TILE_DIR environment variable is required")
            return 2
        }

        val snapshotsDir = System.getenv("VALHALLA_SNAPSHOTS_DIR")
            ?: defaultSnapshotsDir(tileDir)

        val speedBands = try {
            loadLatestSpeedBandsSnapshot(snapshotsDir)
        } catch (e: NoSuchFileException) {
            logger.error(
                "No LTA speed-bands snapshot found at {}. Has the LTA fetch cron (tada-valhalla-traffic) run yet?",
                snapshotsDir
            )
            return 2
        } catch (e: Exception) {
            logger.error("Failed to load speed-bands snapshot from {}: {}", snapshotsDir, e.message, e)
            return 2
        }

        if (speedBands.isEmpty()) {
            logger.error("Latest snapshot at {} contained no speed-band entries", snapshotsDir)
            return 2
        }

        val cachePath = System.getenv("GEOMETRY_MAPPING_CACHE_PATH") ?: DEFAULT_CACHE_PATH
        val textReportPath = System.getenv("GEOMETRY_MAPPING_REPORT_PATH") ?: DEFAULT_TEXT_REPORT_PATH
        val jsonReportPath = System.getenv("GEOMETRY_MAPPING_JSON_REPORT_PATH") ?: DEFAULT_JSON_REPORT_PATH

        return runWithSpeedBands(speedBands, tileDir, cachePath, textReportPath, jsonReportPath)
    }

    /**
     * Testable core: build the mapping from a given speed-band list and write
     * cache + reports. Separated from [run] so unit tests can exercise the
     * mapping/report path without touching disk-resident snapshots.
     */
    @JvmStatic
    fun runWithSpeedBands(
        speedBands: List<SpeedBandEntry>,
        tileDir: String,
        cachePath: String,
        textReportPath: String,
        jsonReportPath: String,
    ): Int {
        val actor: Actor = try {
            Actor.createForRegion("singapore", tileDir).also {
                logger.info("Actor created with tile dir: {}", tileDir)
            }
        } catch (e: Exception) {
            logger.error("Failed to create Actor: {}", e.message)
            return 2
        }

        try {
            logger.info("Building geometry mapping ({} segments, this may take 15-25 minutes)...", speedBands.size)
            val startMs = System.currentTimeMillis()

            val service = GeometryMappingService(actor::locate)
            val mapping = service.buildMapping(speedBands)

            val elapsedSec = (System.currentTimeMillis() - startMs) / 1000.0
            logger.info("Mapping completed in %.1f seconds".format(elapsedSec))

            GeometryMappingCache.save(mapping, cachePath)

            val report = MappingReportGenerator.generateReport(mapping, speedBands)
            MappingReportGenerator.writeTextReport(report, textReportPath)
            MappingReportGenerator.writeJsonReport(report, jsonReportPath)

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

            val legacy = GeometryMappingCache.toLegacyEdgeMapping(mapping)
            logger.info("Legacy EdgeMapping: {} mapped, {} unmapped", legacy.totalMapped, legacy.totalUnmapped)

            return if (report.acceptanceCriteriaMet) 0 else 1

        } catch (e: Exception) {
            logger.error("Geometry mapping job failed: {}", e.message, e)
            return 2
        } finally {
            try {
                actor.close()
                logger.info("Actor closed")
            } catch (e: Exception) {
                logger.warn("Failed to close Actor: {}", e.message)
            }
            logger.info("=== Geometry Mapping Job finished ===")
        }
    }

    /**
     * Default snapshots dir is `{parent_of_tile_dir}/snapshots/speed_bands`.
     * E.g. `tile_dir = /efs/valhalla_tiles/singapore` →
     * `/efs/valhalla_tiles/snapshots/speed_bands` (matches Python cron's layout).
     */
    private fun defaultSnapshotsDir(tileDir: String): String {
        val parent = File(tileDir).parentFile?.absolutePath
            ?: throw IllegalArgumentException("tile dir has no parent: $tileDir")
        return "$parent/snapshots/speed_bands"
    }

    /**
     * Find the latest `*.json.gz` snapshot under [snapshotsDir] and return its
     * parsed speed-band entries.
     *
     * Sort is lexicographic on full path: Python writes
     * `{snapshotsDir}/{YYYY-MM-DD}/{HH-MM-SS}.json.gz`, so ISO dates plus
     * zero-padded times sort correctly without a date-aware comparator.
     *
     * Throws [NoSuchFileException] if the dir is missing or has no `.json.gz`
     * files.
     */
    @JvmStatic
    fun loadLatestSpeedBandsSnapshot(snapshotsDir: String): List<SpeedBandEntry> {
        val dir = Paths.get(snapshotsDir)
        if (!Files.exists(dir)) {
            throw NoSuchFileException(snapshotsDir)
        }

        val latest: Path = Files.walk(dir).use { stream ->
            stream
                .filter { it.fileName.toString().endsWith(".json.gz") }
                .max(compareBy { it.toString() })
                .orElseThrow { NoSuchFileException(snapshotsDir) }
        }

        logger.info("Loading speed bands from snapshot: {}", latest)

        val ageMinutes = (System.currentTimeMillis() - Files.getLastModifiedTime(latest).toMillis()) / 60_000L
        if (ageMinutes >= STALE_SNAPSHOT_WARNING_MINUTES) {
            logger.warn(
                "Snapshot is {} min old (threshold: {} min). Geometry doesn't need fresh speeds, but the LTA cron may have stalled.",
                ageMinutes,
                STALE_SNAPSHOT_WARNING_MINUTES
            )
        }

        val json = GZIPInputStream(Files.newInputStream(latest)).use { stream ->
            stream.readBytes().toString(Charsets.UTF_8)
        }

        return parseSpeedBandsEnvelope(json)
    }

    /**
     * Parse the snapshot envelope written by Python's `tada-valhalla-traffic`:
     *
     * ```
     * {"type":"speed_bands", "timestamp":..., "epochMs":..., "pageCount":N,
     *  "pages":[<raw LTA pages>]}
     * ```
     *
     * Each LTA page has the shape `{"value":[<entry>, ...]}`. We flatten across
     * pages and skip records that fail to deserialize.
     */
    @JvmStatic
    fun parseSpeedBandsEnvelope(json: String): List<SpeedBandEntry> {
        val envelope = JSONObject(json)
        val pages = envelope.optJSONArray("pages") ?: return emptyList()

        val entries = mutableListOf<SpeedBandEntry>()
        var skipped = 0

        for (i in 0 until pages.length()) {
            val page = pages.optJSONObject(i) ?: continue
            val values = page.optJSONArray("value") ?: continue
            for (j in 0 until values.length()) {
                try {
                    entries.add(SpeedBandEntry.fromJson(values.getJSONObject(j)))
                } catch (e: Exception) {
                    skipped++
                }
            }
        }

        if (skipped > 0) {
            logger.debug("Parsed {} speed band entries, skipped {} unparseable", entries.size, skipped)
        }

        return entries
    }
}
