package global.tada.valhalla.traffic.sg

import org.json.JSONArray
import org.json.JSONObject
import org.slf4j.LoggerFactory
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.zip.GZIPInputStream
import java.util.zip.GZIPOutputStream

// Stores raw LTA API responses as gzipped JSON — {base}/{type}/{date}/{time}.json.gz
object LtaSnapshotStore {

    private val logger = LoggerFactory.getLogger(LtaSnapshotStore::class.java)

    private val DATE_DIR_FMT = DateTimeFormatter.ofPattern("yyyy-MM-dd").withZone(ZoneOffset.UTC)
    private val TIME_FILE_FMT = DateTimeFormatter.ofPattern("HH-mm-ss").withZone(ZoneOffset.UTC)

    @JvmStatic
    fun store(type: String, rawPages: List<String>, timestampMs: Long, baseDir: String): File? {
        if (rawPages.isEmpty()) return null

        return try {
            val instant = Instant.ofEpochMilli(timestampMs)
            val dateDir = DATE_DIR_FMT.format(instant)
            val timeFile = TIME_FILE_FMT.format(instant)

            val dir = File(baseDir, "$type/$dateDir")
            dir.mkdirs()

            val file = File(dir, "$timeFile.json.gz")

            val envelope = JSONObject().apply {
                put("type", type)
                put("timestamp", instant.toString())
                put("epochMs", timestampMs)
                put("pageCount", rawPages.size)
                put("pages", JSONArray().apply {
                    for (page in rawPages) {
                        put(JSONObject(page))
                    }
                })
            }

            // Atomic write: temp file → rename (same pattern as TrafficTarBuilder)
            // GZIPOutputStream compresses JSON ~10-15x (48 MB → ~4 MB for speed bands)
            val tempFile = File(dir, ".$timeFile.tmp.gz")
            GZIPOutputStream(FileOutputStream(tempFile)).use { gzip ->
                gzip.write(envelope.toString(2).toByteArray(Charsets.UTF_8))
            }
            if (!tempFile.renameTo(file)) {
                tempFile.copyTo(file, overwrite = true)
                tempFile.delete()
            }

            logger.debug("Snapshot stored: {} ({} bytes, {} pages)", file.path, file.length(), rawPages.size)
            file
        } catch (e: Exception) {
            logger.error("Failed to store {} snapshot: {}", type, e.message)
            null
        }
    }

    @JvmStatic
    fun cleanup(baseDir: String, retentionDays: Int): Int {
        val base = File(baseDir)
        if (!base.isDirectory) return 0

        val cutoff = Instant.now().atZone(ZoneOffset.UTC)
            .minusDays(retentionDays.toLong())
            .toLocalDate()
            .toString() // "YYYY-MM-DD"

        var deleted = 0

        val typeDirs = base.listFiles { f -> f.isDirectory } ?: return 0
        for (typeDir in typeDirs) {
            val dateDirs = typeDir.listFiles { f -> f.isDirectory } ?: continue
            for (dateDir in dateDirs) {
                // Directory name is YYYY-MM-DD; lexicographic compare works for ISO dates
                if (dateDir.name < cutoff) {
                    val fileCount = dateDir.listFiles()?.size ?: 0
                    if (dateDir.deleteRecursively()) {
                        deleted++
                        logger.debug("Deleted expired snapshot dir: {} ({} files)", dateDir.path, fileCount)
                    } else {
                        logger.warn("Failed to delete expired snapshot dir: {}", dateDir.path)
                    }
                }
            }

            // Remove empty type directories
            if (typeDir.listFiles()?.isEmpty() == true) {
                typeDir.delete()
            }
        }

        if (deleted > 0) {
            logger.info("Snapshot cleanup: deleted {} expired directories (retention={}d)", deleted, retentionDays)
        }

        return deleted
    }

    @JvmStatic
    fun listSnapshots(type: String, baseDir: String, fromMs: Long? = null, toMs: Long? = null): List<SnapshotMeta> {
        val typeDir = File(baseDir, type)
        if (!typeDir.isDirectory) return emptyList()

        val results = mutableListOf<SnapshotMeta>()

        val dateDirs = typeDir.listFiles { f -> f.isDirectory }?.sortedBy { it.name } ?: return emptyList()
        for (dateDir in dateDirs) {
            // Match both .json (legacy) and .json.gz (compressed) snapshots
            val files = dateDir.listFiles { f -> f.isFile && (f.name.endsWith(".json") || f.name.endsWith(".json.gz")) }
                ?.sortedBy { it.name } ?: continue

            for (file in files) {
                val meta = parseSnapshotMeta(file, type) ?: continue

                if (fromMs != null && meta.epochMs < fromMs) continue
                if (toMs != null && meta.epochMs > toMs) continue

                results.add(meta)
            }
        }

        return results
    }

    @JvmStatic
    fun readSnapshot(filePath: String): String? {
        val file = File(filePath)
        if (!file.isFile) return null
        return try {
            // Decompress .gz files; read plain .json as-is (backward compat with old snapshots)
            if (file.name.endsWith(".gz")) {
                GZIPInputStream(FileInputStream(file)).use { it.readBytes().toString(Charsets.UTF_8) }
            } else {
                file.readText()
            }
        } catch (e: Exception) {
            logger.warn("Failed to read snapshot {}: {}", filePath, e.message)
            null
        }
    }

    @JvmStatic
    fun getStats(baseDir: String): SnapshotStorageStats {
        val base = File(baseDir)
        if (!base.isDirectory) {
            return SnapshotStorageStats(totalFiles = 0, totalBytes = 0, types = emptyMap())
        }

        val typeStats = mutableMapOf<String, TypeStats>()
        var totalFiles = 0L
        var totalBytes = 0L

        val typeDirs = base.listFiles { f -> f.isDirectory } ?: return SnapshotStorageStats(0, 0, emptyMap())
        for (typeDir in typeDirs) {
            var typeFileCount = 0L
            var typeByteCount = 0L
            var oldestMs = Long.MAX_VALUE
            var newestMs = 0L

            val dateDirs = typeDir.listFiles { f -> f.isDirectory } ?: continue
            for (dateDir in dateDirs) {
                val files = dateDir.listFiles { f -> f.isFile && (f.name.endsWith(".json") || f.name.endsWith(".json.gz")) } ?: continue
                for (file in files) {
                    typeFileCount++
                    typeByteCount += file.length()

                    val meta = parseSnapshotMeta(file, typeDir.name)
                    if (meta != null) {
                        if (meta.epochMs < oldestMs) oldestMs = meta.epochMs
                        if (meta.epochMs > newestMs) newestMs = meta.epochMs
                    }
                }
            }

            if (typeFileCount > 0) {
                typeStats[typeDir.name] = TypeStats(
                    fileCount = typeFileCount,
                    totalBytes = typeByteCount,
                    oldestEpochMs = if (oldestMs == Long.MAX_VALUE) 0 else oldestMs,
                    newestEpochMs = newestMs
                )
                totalFiles += typeFileCount
                totalBytes += typeByteCount
            }
        }

        return SnapshotStorageStats(
            totalFiles = totalFiles,
            totalBytes = totalBytes,
            types = typeStats
        )
    }

    private fun parseSnapshotMeta(file: File, type: String): SnapshotMeta? {
        return try {
            // Path: .../{type}/{YYYY-MM-DD}/{HH-mm-ss}.json or {HH-mm-ss}.json.gz
            val datePart = file.parentFile?.name ?: return null
            // Strip .json.gz (two extensions) or .json (one extension) to get "HH-mm-ss"
            val timePart = file.name.removeSuffix(".gz").removeSuffix(".json")

            val isoDateTime = "${datePart}T${timePart.replace('-', ':')}Z"
            val instant = Instant.parse(isoDateTime)

            SnapshotMeta(
                type = type,
                timestamp = instant.toString(),
                epochMs = instant.toEpochMilli(),
                filePath = file.absolutePath,
                fileSize = file.length()
            )
        } catch (e: Exception) {
            logger.debug("Could not parse snapshot meta from {}: {}", file.path, e.message)
            null
        }
    }
}

data class SnapshotMeta(
    val type: String,
    val timestamp: String,
    val epochMs: Long,
    val filePath: String,
    val fileSize: Long
)

data class TypeStats(
    val fileCount: Long,
    val totalBytes: Long,
    val oldestEpochMs: Long,
    val newestEpochMs: Long
)

data class SnapshotStorageStats(
    val totalFiles: Long,
    val totalBytes: Long,
    val types: Map<String, TypeStats>
)
