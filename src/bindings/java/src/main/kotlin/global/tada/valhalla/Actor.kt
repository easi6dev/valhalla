package global.tada.valhalla

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.slf4j.LoggerFactory
import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.nio.file.attribute.PosixFilePermissions
import java.util.concurrent.CompletableFuture
import kotlin.io.path.exists

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
                                else -> throw ValhallaException("Unsupported operating system: $arch")
                            }

                            // copy the library files outside of jar
                            val libraryFiles = this::class.java.classLoader.let {
                                listOfNotNull(
                                    it.getResource("lib/${os.identifier}-${arch}/abseil_dll${os.suffix}"),
                                    it.getResource("lib/${os.identifier}-${arch}/libcurl${os.suffix}"),
                                    it.getResource("lib/${os.identifier}-${arch}/libprotobuf-lite${os.suffix}"),
                                    it.getResource("lib/${os.identifier}-${arch}/lz4${os.suffix}"),
                                    it.getResource("lib/${os.identifier}-${arch}/zlib1${os.suffix}"),
                                    it.getResource("lib/${os.identifier}-${arch}/valhalla_jni${os.suffix}"), // this should be the last entry!
                                )
                            }

                            println("Native libraries found in classpath: $libraryFiles")

                            val targetDir = File(this::class.java.getProtectionDomain().codeSource.location.toURI().getPath())
                                .parentFile.toPath()
                            val files = libraryFiles.map { libraryFile ->
                                println(libraryFile.file)
                                println(libraryFile.file.split("/").last())
                                val fileName = libraryFile.file.split("/").last()
                                libraryFile.openStream().use { stream ->
                                    val newFilePath = targetDir.resolve(fileName)
                                    val newFile = if (newFilePath.exists()) {
                                        File(newFilePath.toAbsolutePath().toString())
                                    } else if (os.isPosix) {
                                        val attr = PosixFilePermissions.asFileAttribute(PosixFilePermissions.fromString("rwx------"))
                                        Files.createFile(newFilePath, attr).toFile()
                                    } else {
                                        val file = Files.createFile(newFilePath).toFile()
                                        file.setReadable(true, true);
                                        file.setWritable(true, true);
                                        file.setExecutable(true, true);
                                        file
                                    }.also { it.deleteOnExit() }
                                    FileOutputStream(newFile).use { newStream ->
                                        newStream.write(stream.readBytes())
                                    }
                                    println("Copied ${libraryFile.file} tp ${newFile.absolutePath}")
                                    newFile.absolutePath
                                }
                            }

                            // load the valhalla_jni with absolute path
                            files.forEach(System::load)
                            libraryLoaded = true
                            logger.info("Successfully loaded native library: {}", LIBRARY_NAME)
                        } catch (e: UnsatisfiedLinkError) {
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
         * Create Actor with Singapore-specific configuration
         *
         * @param tileDir Path to Singapore tiles (default: data/valhalla_tiles/singapore)
         * @return Actor instance configured for Singapore
         */
        @JvmStatic
        fun createSingapore(tileDir: String = "data/valhalla_tiles/singapore"): Actor {
            val config = global.tada.valhalla.config.SingaporeConfig.buildConfig(tileDir)
            return Actor(config)
        }

        /**
         * Create Actor with region-specific configuration
         *
         * @param region Region to configure (Singapore, Thailand)
         * @param regionsConfigFile Path to regions.json (default: config/regions/regions.json)
         * @return Actor instance configured for the specified region
         */
        @JvmStatic
        fun createForRegion(
            region: global.tada.valhalla.config.RegionConfig.Region,
            regionsConfigFile: String = "config/regions/regions.json"
        ): Actor {
            val config = global.tada.valhalla.config.RegionConfig.loadRegionConfig(region, regionsConfigFile)
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
     */
    private var nativeHandle: Long = 0L

    private var closed = false

    init {
        nativeHandle = nativeCreate(config)
        if (nativeHandle == 0L) {
            throw ValhallaException("Failed to create native actor")
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
