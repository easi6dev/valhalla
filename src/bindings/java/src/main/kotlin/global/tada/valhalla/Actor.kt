package global.tada.valhalla

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import org.slf4j.LoggerFactory
import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.util.concurrent.CompletableFuture

/**
 * Main Actor class for Valhalla routing engine.
 *
 * This class provides a JNI wrapper for the Valhalla C++ library,
 * supporting various features including routing, matrix calculation, isochrones, and more.
 *
 * @property config Valhalla configuration JSON string
 *
 * ## Usage Example
 * ```kotlin
 * val config = """
 * {
 *   "mjolnir": {
 *     "tile_dir": "/path/to/tiles"
 *   }
 * }
 * """
 *
 * val actor = Actor(config)
 * val result = actor.route("""{"locations": [...]}""")
 * ```
 */
class Actor(config: String) : AutoCloseable {

    enum class OperatingSystem(val identifier: String, val suffix: String, val isPosix: Boolean = true) {
        WINDOWS("win", ".dll", isPosix = false), // only supports amd64
        LINUX("linux", ".so"), // both supports amd64 and arm64
        MAC("mac", ".dylib") // only supports arm64
    }

    companion object {
        private val logger = LoggerFactory.getLogger(Actor::class.java)
        private const val LIBRARY_NAME = "valhalla_jni"

        @Volatile
        private var libraryLoaded = false

        // Temp directory for extracted native libraries
        // Uses process ID to prevent conflicts in multi-process environments
        private val tempLibDir by lazy {
            val processId = ProcessHandle.current().pid()
            val tempDir = Files.createTempDirectory("valhalla-jni-$processId")

            // Register shutdown hook to clean up temp directory
            Runtime.getRuntime().addShutdownHook(Thread {
                try {
                    tempDir.toFile().deleteRecursively()
                    logger.debug("Cleaned up temp library directory: {}", tempDir)
                } catch (e: Exception) {
                    logger.warn("Failed to clean up temp directory: {}", tempDir, e)
                }
            })

            logger.debug("Created temp library directory: {}", tempDir)
            tempDir
        }

        /**
         * Essential native libraries that must be bundled with the JAR.
         * System libraries (libz, libcurl, libssl, etc.) should be provided by the runtime environment.
         *
         * Production Deployment:
         * - Docker: Install system libs in base image (apt install libboost, libprotobuf, etc.)
         * - Kubernetes: Use init container or distroless image with required libraries
         * - Bare Metal: Install system dependencies via package manager
         *
         * Bundled libraries per platform (load order is dependency order — must not be changed):
         * Linux:   libprotobuf-lite.so.* → libvalhalla.so.* → libvalhalla_jni.so
         * Windows: zlib1 → lz4 → libcurl → abseil_dll → libprotobuf-lite → valhalla_jni
         * Mac:     libprotobuf-lite.dylib → libvalhalla.dylib → libvalhalla_jni.dylib
         *
         * Linux/Mac versions are resolved dynamically from JAR contents so the exact
         * soname suffix (e.g. .23 vs .32) does not need to be hardcoded here.
         */
        private fun getRequiredLibraries(os: OperatingSystem, arch: String): List<String> {
            val dir = "lib/${os.identifier}-${arch}"
            return when (os) {
                OperatingSystem.WINDOWS -> listOf(
                    // Load order: lowest-level deps first, JNI wrapper last
                    "$dir/zlib1.dll",
                    "$dir/lz4.dll",
                    "$dir/libcurl.dll",
                    "$dir/abseil_dll.dll",
                    "$dir/libprotobuf-lite.dll",
                    "$dir/valhalla_jni.dll"
                )
                OperatingSystem.LINUX -> {
                    // Resolve versioned sonames dynamically from JAR to avoid hardcoding
                    // e.g. libprotobuf-lite.so.23 on Ubuntu 22, .so.32 on Ubuntu 24
                    val classLoader = Actor::class.java.classLoader
                    listOf(
                        findVersionedLib(classLoader, dir, "libprotobuf-lite.so"),
                        findVersionedLib(classLoader, dir, "libvalhalla.so"),
                        "$dir/libvalhalla_jni.so"
                    )
                }
                OperatingSystem.MAC -> listOf(
                    "$dir/libprotobuf-lite.dylib",
                    "$dir/libvalhalla.dylib",
                    "$dir/libvalhalla_jni.dylib"
                )
            }
        }

        /**
         * Finds a versioned shared library inside the JAR by scanning the resource directory.
         *
         * For a [prefix] like "libprotobuf-lite.so" this will match both
         * "libprotobuf-lite.so.23" (Ubuntu 22) and "libprotobuf-lite.so.32" (Ubuntu 24).
         * Falls back to the exact prefix name if no versioned file is found.
         *
         * @param classLoader ClassLoader to use for resource scanning
         * @param dir Resource directory path (e.g. "lib/linux-amd64")
         * @param prefix Filename prefix to match (e.g. "libprotobuf-lite.so")
         * @return Full resource path of the best match
         */
        private fun findVersionedLib(classLoader: ClassLoader, dir: String, prefix: String): String {
            // The JAR resource listing is not directly enumerable via ClassLoader alone;
            // we probe known versioned names in priority order and fall back to the bare prefix.
            val candidates = when {
                prefix.startsWith("libprotobuf-lite") -> listOf(
                    "$dir/$prefix.32",  // Ubuntu 24.04 (protobuf 3.21+)
                    "$dir/$prefix.23",  // Ubuntu 22.04
                    "$dir/$prefix"
                )
                prefix.startsWith("libvalhalla.so") -> listOf(
                    "$dir/$prefix.3",
                    "$dir/$prefix"
                )
                else -> listOf("$dir/$prefix")
            }
            return candidates.firstOrNull { classLoader.getResource(it) != null }
                ?: "$dir/$prefix"
        }

        /**
         * Loads the native library.
         *
         * @throws UnsatisfiedLinkError if library loading fails
         */
        @JvmStatic
        private fun loadLibrary() {
            if (!libraryLoaded) {
                synchronized(this) {
                    if (!libraryLoaded) {
                        try {
                            val osName = System.getProperty("os.name")
                            val os = when {
                                osName.contains("mac", ignoreCase = true) -> OperatingSystem.MAC
                                osName.contains("win", ignoreCase = true) -> OperatingSystem.WINDOWS
                                else -> OperatingSystem.LINUX
                            }
                            val arch = when (val arch = System.getProperty("os.arch")) {
                                "amd64",
                                "x86_64" -> "amd64"
                                "aarch64" -> "arm64"
                                else -> throw ValhallaException("Unsupported architecture: $arch")
                            }

                            logger.info("Loading native libraries for {} {}", os.identifier, arch)

                            // Get required library paths
                            val requiredLibs = getRequiredLibraries(os, arch)
                            val classLoader = this::class.java.classLoader

                            // Extract and load each library
                            val loadedLibs = mutableListOf<String>()
                            for (libPath in requiredLibs) {
                                val resource = classLoader.getResource(libPath)
                                    ?: throw ValhallaException("Native library not found in JAR: $libPath")

                                val fileName = libPath.substringAfterLast('/')
                                val targetFile = tempLibDir.resolve(fileName).toFile()

                                // Extract library to temp directory
                                resource.openStream().use { input ->
                                    FileOutputStream(targetFile).use { output ->
                                        input.copyTo(output)
                                    }
                                }

                                // Set executable permissions on POSIX systems
                                if (os.isPosix) {
                                    targetFile.setReadable(true, true)
                                    targetFile.setWritable(true, true)
                                    targetFile.setExecutable(true, true)
                                } else {
                                    // Windows
                                    targetFile.setReadable(true, true)
                                    targetFile.setWritable(true, true)
                                    targetFile.setExecutable(true, true)
                                }

                                // Load library using absolute path
                                System.load(targetFile.absolutePath)
                                loadedLibs.add(fileName)
                                logger.debug("Loaded native library: {}", fileName)
                            }

                            libraryLoaded = true
                            logger.info("Successfully loaded {} native libraries: {}", loadedLibs.size, loadedLibs)
                        } catch (e: UnsatisfiedLinkError) {
                            val osName = System.getProperty("os.name", "")
                            val systemDepsHint = when {
                                osName.contains("linux", ignoreCase = true) ->
                                    "   apt-get install libboost-all-dev libcurl4 libssl3 libprotobuf-dev zlib1g liblz4-1"
                                osName.contains("mac", ignoreCase = true) ->
                                    "   brew install boost curl openssl protobuf lz4 zlib"
                                else ->
                                    "   Install: vcredist (MSVC runtime), libcurl, zlib, lz4, protobuf"
                            }
                            val msg = """
                                |Failed to load native library: $LIBRARY_NAME
                                |
                                |Common causes:
                                |1. Missing system dependencies — install:
                                |$systemDepsHint
                                |   Or use the provided Docker image which includes all dependencies.
                                |
                                |2. Architecture mismatch (trying to load x86_64 library on ARM or vice versa)
                                |   Solution: Ensure the JAR was built for this architecture
                                |
                                |3. Missing libvalhalla native library in JAR
                                |   Solution: Rebuild with: ./gradlew clean build
                                |
                                |Error: ${e.message}
                            """.trimMargin()
                            logger.error(msg, e)
                            throw ValhallaException(msg, e)
                        } catch (e: Exception) {
                            logger.error("Failed to load native library: {}", LIBRARY_NAME, e)
                            throw ValhallaException("Failed to load native library: $LIBRARY_NAME", e)
                        }
                    }
                }
            }
        }

        init {
            loadLibrary()
        }

        /**
         * Create Actor with region-specific configuration
         *
         * This is the recommended way to create an Actor instance for any supported region.
         *
         * ## Supported Regions
         * - singapore (or "sg")
         * - thailand (or "th")
         *
         * ## Usage Example
         * ```kotlin
         * // Create Actor for Singapore
         * val sgActor = Actor.createForRegion("singapore")
         *
         * // Create Actor for Thailand with custom tile directory
         * val thActor = Actor.createForRegion("thailand", "/custom/path/to/tiles")
         *
         * // Use country code
         * val actor = Actor.createForRegion("th", "/path/to/tiles")
         * ```
         *
         * @param region Region name (case-insensitive: "singapore", "thailand", etc.)
         * @param tileDir Path to tiles directory (default: "data/valhalla_tiles/{region}")
         * @param enableTraffic Enable traffic-aware routing (default: false)
         * @return Actor instance configured for the specified region
         * @throws IllegalArgumentException if region is not supported
         */
        @JvmStatic
        @JvmOverloads
        fun createForRegion(
            region: String,
            tileDir: String = "data/valhalla_tiles/${region.lowercase()}",
            enableTraffic: Boolean = false
        ): Actor {
            val config = global.tada.valhalla.config.RegionConfigFactory.buildConfig(
                region = region,
                tileDir = tileDir,
                enableTraffic = enableTraffic
            )
            return Actor(config)
        }

        /**
         * Create Actor with Singapore-specific configuration
         *
         * @param tileDir Path to Singapore tiles (default: data/valhalla_tiles/singapore)
         * @return Actor instance configured for Singapore
         * @deprecated Use createForRegion("singapore", tileDir) instead
         */
        @Deprecated(
            message = "Use createForRegion(\"singapore\", tileDir) instead for better multi-region support",
            replaceWith = ReplaceWith("createForRegion(\"singapore\", tileDir)")
        )
        @JvmStatic
        fun createSingapore(tileDir: String = "data/valhalla_tiles/singapore"): Actor {
            return createForRegion("singapore", tileDir)
        }

        /**
         * Create Actor with external tile directory
         *
         * Automatically detects tile location from:
         * 1. Environment variable: VALHALLA_TILES_DIR
         * 2. System property: valhalla.tiles.dir
         * 3. Default locations
         *
         * @param region Region subdirectory (optional, e.g., "singapore")
         * @return Actor instance
         */
        @JvmStatic
        fun createWithExternalTiles(region: String? = null): Actor {
            val tileDir = global.tada.valhalla.config.TileConfig.autoDetect(region)
            val config = global.tada.valhalla.config.createConfigWithTileDir(tileDir, region ?: "singapore")
            return Actor(config)
        }

        /**
         * Create Actor with custom tile directory path
         *
         * @param tileDir Absolute path to tile directory
         * @param region Region name for config optimization (default: "singapore")
         * @return Actor instance
         */
        @JvmStatic
        fun createWithTilePath(tileDir: String, region: String = "singapore"): Actor {
            val config = global.tada.valhalla.config.createConfigWithTileDir(tileDir, region)
            return Actor(config)
        }

        /**
         * Create Actor from configuration file
         *
         * @param configFile Path to Valhalla configuration JSON file
         * @return Actor instance
         */
        @JvmStatic
        fun fromFile(configFile: String): Actor {
            val config = File(configFile).readText()
            return Actor(config)
        }
    }

    /**
     * Pointer to the native actor object.
     * Points to a C++ valhalla::tyr::actor_t instance.
     *
     * Marked volatile to ensure visibility across threads.
     */
    @Volatile
    private var nativeHandle: Long = 0L

    @Volatile
    private var closed = false

    init {
        validateTileDirectory(config)
        nativeHandle = nativeCreate(config)
        if (nativeHandle == 0L) {
            throw ValhallaException("Failed to create native actor")
        }
    }

    /**
     * Validates that the tile directory specified in the config exists before handing
     * the config to the C++ actor. Fails fast with a clear message rather than letting
     * the native layer emit an opaque error.
     */
    private fun validateTileDirectory(config: String) {
        try {
            val tileDir = JSONObject(config)
                .optJSONObject("mjolnir")
                ?.optString("tile_dir")
                ?: return  // no tile_dir key — let native handle it

            if (tileDir.isBlank()) return

            val dir = File(tileDir)
            if (!dir.exists()) {
                throw ValhallaException(
                    "Tile directory not found: $tileDir\n" +
                    "Set VALHALLA_TILE_DIR environment variable to the directory containing region tile folders.\n" +
                    "Expected structure: \$VALHALLA_TILE_DIR/{region}/0/, /1/, /2/"
                )
            }
            if (!dir.isDirectory) {
                throw ValhallaException("Tile path is not a directory: $tileDir")
            }
        } catch (e: ValhallaException) {
            throw e
        } catch (e: Exception) {
            // JSON parse errors or other issues — let native report them
            logger.debug("Could not pre-validate tile directory from config: {}", e.message)
        }
    }

    // ========================================
    // Native Methods
    // ========================================

    /**
     * Creates a native actor object.
     *
     * @param config Valhalla configuration JSON string
     * @return Native object pointer
     */
    private external fun nativeCreate(config: String): Long

    /**
     * Destroys the native actor object.
     *
     * @param handle Native object pointer
     */
    private external fun nativeDestroy(handle: Long)

    /**
     * Calculates a route.
     *
     * @param handle Native object pointer
     * @param request Request JSON string
     * @return Result JSON string
     */
    private external fun nativeRoute(handle: Long, request: String): String

    /**
     * Provides information about nodes and edges.
     *
     * @param handle Native object pointer
     * @param request Request JSON string
     * @return Result JSON string
     */
    private external fun nativeLocate(handle: Long, request: String): String

    /**
     * Optimizes the order of waypoints by time.
     *
     * @param handle Native object pointer
     * @param request Request JSON string
     * @return Result JSON string
     */
    private external fun nativeOptimizedRoute(handle: Long, request: String): String

    /**
     * Computes time and distance matrix between locations.
     *
     * @param handle Native object pointer
     * @param request Request JSON string
     * @return Result JSON string
     */
    private external fun nativeMatrix(handle: Long, request: String): String

    /**
     * Calculates isochrones and isodistances.
     *
     * @param handle Native object pointer
     * @param request Request JSON string
     * @return Result JSON string
     */
    private external fun nativeIsochrone(handle: Long, request: String): String

    /**
     * Performs map-matching for GPS trace.
     *
     * @param handle Native object pointer
     * @param request Request JSON string
     * @return Result JSON string
     */
    private external fun nativeTraceRoute(handle: Long, request: String): String

    /**
     * Returns detailed attributes along a route from GPS trace.
     *
     * @param handle Native object pointer
     * @param request Request JSON string
     * @return Result JSON string
     */
    private external fun nativeTraceAttributes(handle: Long, request: String): String

    /**
     * Provides elevation data for geometries.
     *
     * @param handle Native object pointer
     * @param request Request JSON string
     * @return Result JSON string
     */
    private external fun nativeHeight(handle: Long, request: String): String

    /**
     * Checks transit stop availability around locations.
     *
     * @param handle Native object pointer
     * @param request Request JSON string
     * @return Result JSON string
     */
    private external fun nativeTransitAvailable(handle: Long, request: String): String

    /**
     * Returns road segments touched during routing.
     *
     * @param handle Native object pointer
     * @param request Request JSON string
     * @return Result JSON string
     */
    private external fun nativeExpansion(handle: Long, request: String): String

    /**
     * Calculates minimum cost meeting point.
     *
     * @param handle Native object pointer
     * @param request Request JSON string
     * @return Result JSON string
     */
    private external fun nativeCentroid(handle: Long, request: String): String

    /**
     * Returns Valhalla configuration details.
     *
     * @param handle Native object pointer
     * @param request Request JSON string
     * @return Result JSON string
     */
    private external fun nativeStatus(handle: Long, request: String): String

    /**
     * Returns vector tile (MVT binary data).
     *
     * @param handle Native object pointer
     * @param request Request JSON string
     * @return Result byte array
     */
    private external fun nativeTile(handle: Long, request: String): ByteArray

    // ========================================
    // Public Synchronous API
    // ========================================

    /**
     * Checks if actor is closed.
     */
    private fun checkClosed() {
        if (closed) {
            throw IllegalStateException("Actor is already closed")
        }
    }

    /**
     * Calculates a route.
     *
     * @param request Request JSON string
     * @return Result JSON string
     * @throws ValhallaException if calculation fails
     */
    fun route(request: String): String {
        checkClosed()
        return nativeRoute(nativeHandle, request)
    }

    /**
     * Provides information about nodes and edges.
     *
     * @param request Request JSON string
     * @return Result JSON string
     * @throws ValhallaException if lookup fails
     */
    fun locate(request: String): String {
        checkClosed()
        return nativeLocate(nativeHandle, request)
    }

    /**
     * Optimizes the order of waypoints by time.
     *
     * @param request Request JSON string
     * @return Result JSON string
     * @throws ValhallaException if optimization fails
     */
    fun optimizedRoute(request: String): String {
        checkClosed()
        return nativeOptimizedRoute(nativeHandle, request)
    }

    /**
     * Computes time and distance matrix between locations.
     *
     * @param request Request JSON string
     * @return Result JSON string
     * @throws ValhallaException if calculation fails
     */
    fun matrix(request: String): String {
        checkClosed()
        return nativeMatrix(nativeHandle, request)
    }

    /**
     * Calculates isochrones and isodistances.
     *
     * @param request Request JSON string
     * @return Result JSON string
     * @throws ValhallaException if calculation fails
     */
    fun isochrone(request: String): String {
        checkClosed()
        return nativeIsochrone(nativeHandle, request)
    }

    /**
     * Performs map-matching for GPS trace.
     *
     * @param request Request JSON string
     * @return Result JSON string
     * @throws ValhallaException if map-matching fails
     */
    fun traceRoute(request: String): String {
        checkClosed()
        return nativeTraceRoute(nativeHandle, request)
    }

    /**
     * Returns detailed attributes along a route from GPS trace.
     *
     * @param request Request JSON string
     * @return Result JSON string
     * @throws ValhallaException if calculation fails
     */
    fun traceAttributes(request: String): String {
        checkClosed()
        return nativeTraceAttributes(nativeHandle, request)
    }

    /**
     * Provides elevation data for geometries.
     *
     * @param request Request JSON string
     * @return Result JSON string
     * @throws ValhallaException if lookup fails
     */
    fun height(request: String): String {
        checkClosed()
        return nativeHeight(nativeHandle, request)
    }

    /**
     * Checks transit stop availability around locations.
     *
     * @param request Request JSON string
     * @return Result JSON string
     * @throws ValhallaException if lookup fails
     */
    fun transitAvailable(request: String): String {
        checkClosed()
        return nativeTransitAvailable(nativeHandle, request)
    }

    /**
     * Returns road segments touched during routing.
     *
     * @param request Request JSON string
     * @return Result JSON string
     * @throws ValhallaException if lookup fails
     */
    fun expansion(request: String): String {
        checkClosed()
        return nativeExpansion(nativeHandle, request)
    }

    /**
     * Calculates minimum cost meeting point.
     *
     * @param request Request JSON string
     * @return Result JSON string
     * @throws ValhallaException if calculation fails
     */
    fun centroid(request: String): String {
        checkClosed()
        return nativeCentroid(nativeHandle, request)
    }

    /**
     * Returns Valhalla configuration details.
     *
     * @param request Request JSON string
     * @return Result JSON string
     * @throws ValhallaException if lookup fails
     */
    fun status(request: String): String {
        checkClosed()
        return nativeStatus(nativeHandle, request)
    }

    /**
     * Returns vector tile (MVT binary data).
     *
     * @param request Request JSON string
     * @return Result byte array
     * @throws ValhallaException if lookup fails
     */
    fun tile(request: String): ByteArray {
        checkClosed()
        return nativeTile(nativeHandle, request)
    }

    // ========================================
    // Public Asynchronous API (CompletableFuture)
    // ========================================

    /**
     * Asynchronously calculates a route.
     *
     * @param request Request JSON string
     * @return CompletableFuture with result JSON string
     */
    fun routeAsync(request: String): CompletableFuture<String> =
        CompletableFuture.supplyAsync { route(request) }

    /**
     * Asynchronously provides location information.
     *
     * @param request Request JSON string
     * @return CompletableFuture with result JSON string
     */
    fun locateAsync(request: String): CompletableFuture<String> =
        CompletableFuture.supplyAsync { locate(request) }

    /**
     * Asynchronously optimizes route waypoints.
     *
     * @param request Request JSON string
     * @return CompletableFuture with result JSON string
     */
    fun optimizedRouteAsync(request: String): CompletableFuture<String> =
        CompletableFuture.supplyAsync { optimizedRoute(request) }

    /**
     * Asynchronously computes matrix.
     *
     * @param request Request JSON string
     * @return CompletableFuture with result JSON string
     */
    fun matrixAsync(request: String): CompletableFuture<String> =
        CompletableFuture.supplyAsync { matrix(request) }

    /**
     * Asynchronously calculates isochrones.
     *
     * @param request Request JSON string
     * @return CompletableFuture with result JSON string
     */
    fun isochroneAsync(request: String): CompletableFuture<String> =
        CompletableFuture.supplyAsync { isochrone(request) }

    /**
     * Asynchronously performs trace routing.
     *
     * @param request Request JSON string
     * @return CompletableFuture with result JSON string
     */
    fun traceRouteAsync(request: String): CompletableFuture<String> =
        CompletableFuture.supplyAsync { traceRoute(request) }

    /**
     * Asynchronously calculates trace attributes.
     *
     * @param request Request JSON string
     * @return CompletableFuture with result JSON string
     */
    fun traceAttributesAsync(request: String): CompletableFuture<String> =
        CompletableFuture.supplyAsync { traceAttributes(request) }

    /**
     * Asynchronously provides height information.
     *
     * @param request Request JSON string
     * @return CompletableFuture with result JSON string
     */
    fun heightAsync(request: String): CompletableFuture<String> =
        CompletableFuture.supplyAsync { height(request) }

    /**
     * Asynchronously checks transit availability.
     *
     * @param request Request JSON string
     * @return CompletableFuture with result JSON string
     */
    fun transitAvailableAsync(request: String): CompletableFuture<String> =
        CompletableFuture.supplyAsync { transitAvailable(request) }

    /**
     * Asynchronously provides expansion information.
     *
     * @param request Request JSON string
     * @return CompletableFuture with result JSON string
     */
    fun expansionAsync(request: String): CompletableFuture<String> =
        CompletableFuture.supplyAsync { expansion(request) }

    /**
     * Asynchronously calculates centroid.
     *
     * @param request Request JSON string
     * @return CompletableFuture with result JSON string
     */
    fun centroidAsync(request: String): CompletableFuture<String> =
        CompletableFuture.supplyAsync { centroid(request) }

    /**
     * Asynchronously provides status information.
     *
     * @param request Request JSON string
     * @return CompletableFuture with result JSON string
     */
    fun statusAsync(request: String): CompletableFuture<String> =
        CompletableFuture.supplyAsync { status(request) }

    /**
     * Asynchronously provides tile data.
     *
     * @param request Request JSON string
     * @return CompletableFuture with result byte array
     */
    fun tileAsync(request: String): CompletableFuture<ByteArray> =
        CompletableFuture.supplyAsync { tile(request) }

    // ========================================
    // Kotlin Coroutine Suspending API
    // ========================================

    /**
     * Calculates a route using Kotlin coroutines.
     *
     * @param request Request JSON string
     * @return Result JSON string
     */
    suspend fun routeSuspend(request: String): String = withContext(Dispatchers.IO) {
        route(request)
    }

    /**
     * Provides location information using Kotlin coroutines.
     *
     * @param request Request JSON string
     * @return Result JSON string
     */
    suspend fun locateSuspend(request: String): String = withContext(Dispatchers.IO) {
        locate(request)
    }

    /**
     * Optimizes route using Kotlin coroutines.
     *
     * @param request Request JSON string
     * @return Result JSON string
     */
    suspend fun optimizedRouteSuspend(request: String): String = withContext(Dispatchers.IO) {
        optimizedRoute(request)
    }

    /**
     * Computes matrix using Kotlin coroutines.
     *
     * @param request Request JSON string
     * @return Result JSON string
     */
    suspend fun matrixSuspend(request: String): String = withContext(Dispatchers.IO) {
        matrix(request)
    }

    /**
     * Calculates isochrones using Kotlin coroutines.
     *
     * @param request Request JSON string
     * @return Result JSON string
     */
    suspend fun isochroneSuspend(request: String): String = withContext(Dispatchers.IO) {
        isochrone(request)
    }

    /**
     * Performs trace routing using Kotlin coroutines.
     *
     * @param request Request JSON string
     * @return Result JSON string
     */
    suspend fun traceRouteSuspend(request: String): String = withContext(Dispatchers.IO) {
        traceRoute(request)
    }

    /**
     * Calculates trace attributes using Kotlin coroutines.
     *
     * @param request Request JSON string
     * @return Result JSON string
     */
    suspend fun traceAttributesSuspend(request: String): String = withContext(Dispatchers.IO) {
        traceAttributes(request)
    }

    /**
     * Provides height information using Kotlin coroutines.
     *
     * @param request Request JSON string
     * @return Result JSON string
     */
    suspend fun heightSuspend(request: String): String = withContext(Dispatchers.IO) {
        height(request)
    }

    /**
     * Checks transit availability using Kotlin coroutines.
     *
     * @param request Request JSON string
     * @return Result JSON string
     */
    suspend fun transitAvailableSuspend(request: String): String = withContext(Dispatchers.IO) {
        transitAvailable(request)
    }

    /**
     * Provides expansion information using Kotlin coroutines.
     *
     * @param request Request JSON string
     * @return Result JSON string
     */
    suspend fun expansionSuspend(request: String): String = withContext(Dispatchers.IO) {
        expansion(request)
    }

    /**
     * Calculates centroid using Kotlin coroutines.
     *
     * @param request Request JSON string
     * @return Result JSON string
     */
    suspend fun centroidSuspend(request: String): String = withContext(Dispatchers.IO) {
        centroid(request)
    }

    /**
     * Provides status information using Kotlin coroutines.
     *
     * @param request Request JSON string
     * @return Result JSON string
     */
    suspend fun statusSuspend(request: String): String = withContext(Dispatchers.IO) {
        status(request)
    }

    /**
     * Provides tile data using Kotlin coroutines.
     *
     * @param request Request JSON string
     * @return Result byte array
     */
    suspend fun tileSuspend(request: String): ByteArray = withContext(Dispatchers.IO) {
        tile(request)
    }

    // ========================================
    // Resource Management
    // ========================================

    /**
     * Releases native resources.
     */
    override fun close() {
        if (!closed) {
            synchronized(this) {
                if (!closed) {
                    if (nativeHandle != 0L) {
                        nativeDestroy(nativeHandle)
                        nativeHandle = 0L
                    }
                    closed = true
                    logger.debug("Actor closed successfully")
                }
            }
        }
    }

    /**
     * Cleanup resources when garbage collected.
     */
    @Suppress("deprecation")
    protected fun finalize() {
        if (!closed) {
            logger.warn("Actor was not properly closed, cleaning up in finalizer")
            close()
        }
    }
}
