# Valhalla Integration Guide

This guide explains how to integrate the Valhalla routing engine into your services.

> **Important:** `valhalla-server` is a **test/reference service only** — a minimal Ktor HTTP wrapper used to verify the JAR locally during development. It is not intended for production use. The production integration pattern is to add `valhalla-jni.jar` as a dependency and call `Actor` directly in-process (Option 1 below).

## Architecture Options

### Option 1: Direct JNI Integration (Embedded) ✅ Recommended

Add `valhalla-jni.jar` as a dependency in your JVM service and call the `Actor` API in-process.

**Pros:**
- Lowest latency (in-process, no network hop)
- No additional infrastructure
- Self-contained deployment (native libs bundled in JAR)

**Cons:**
- Requires JVM service (Kotlin/Java)
- ~500 MB memory per `Actor` instance (tiles loaded on init)

> ⚠️ **Concurrency:** a single `Actor` is **NOT thread-safe** — its native
> workers keep per-request scratch state with no locking, so concurrent calls on
> one `Actor` corrupt that state and can SIGSEGV. For any service handling
> concurrent requests use **`ActorPool`** (see [Concurrency](#concurrency-actorpool-required-for-concurrent-traffic)
> below), which hands each in-flight call its own exclusively-held actor.

**Use Case:** The standard pattern for all production JVM services integrating Valhalla routing.

### Option 2: Standalone Microservice (REST API)

Wrap `valhalla-jni.jar` in a Spring Boot or Ktor service and expose it over HTTP.

**Pros:**
- Language-agnostic client access (any service can call it)
- Horizontal scaling of the routing layer independently
- Non-JVM services can consume routing

**Cons:**
- Network latency on every routing call
- Additional service to deploy and monitor

**Use Case:** When you have non-JVM services (Go, Python, Node.js) that need routing, or when you want to scale the routing layer independently.

### Option 3: Shared Library (Maven/Nexus)

Publish `valhalla-jni.jar` to your internal Nexus/Artifactory and share it across multiple JVM services.

**Pros:**
- Reusable across all Java/Kotlin services in the organisation
- Consistent versioning
- Centralised maintenance

**Cons:**
- Requires shared artifact repository
- Each consuming service carries its own tile memory footprint

**Use Case:** Organisations with multiple JVM services all needing routing (driver dispatch, ETA calculation, service area analysis).

---

## Option 1: Direct JNI Integration

### Step 1: Build and Publish JAR

```bash
# In the Valhalla project root
cd src/bindings/java

# Build the JAR (includes compilation)
./gradlew build

# Publish to local Maven repository
./gradlew publishToMavenLocal

# Or publish to your company's Nexus/Artifactory
./gradlew publish
```

The JAR will be published as:
```
groupId: global.tada.valhalla
artifactId: valhalla-jni
version: 1.0.0-SNAPSHOT
```

### Step 2: Add Dependency to Your Service

**build.gradle.kts (Gradle):**
```kotlin
dependencies {
    implementation("global.tada.valhalla:valhalla-jni:1.0.0-SNAPSHOT")
}
```

**pom.xml (Maven):**
```xml
<dependency>
    <groupId>global.tada.valhalla</groupId>
    <artifactId>valhalla-jni</artifactId>
    <version>1.0.0-SNAPSHOT</version>
</dependency>
```

### Step 3: Deploy Native Libraries

The native libraries need to be accessible at runtime. Options:

#### Option A: Bundle in JAR (Recommended)

Modify `build.gradle.kts` to include native libraries:

```kotlin
tasks.jar {
    from("../../../build/src") {
        include("libvalhalla.so*")
        into("lib/linux-amd64")
    }
    from("../../../build/src/bindings/java/libs/native") {
        include("libvalhalla_jni.so")
        into("lib/linux-amd64")
    }
}
```

Then load from classpath in your Actor class.

#### Option B: Deploy to System Library Path

```bash
# Copy libraries to system path
sudo cp build/src/libvalhalla.so* /usr/local/lib/
sudo cp build/src/bindings/java/libs/native/libvalhalla_jni.so /usr/local/lib/
sudo ldconfig
```

#### Option C: Set LD_LIBRARY_PATH

Add to your service startup:
```bash
export LD_LIBRARY_PATH=/path/to/valhalla/build/src:/path/to/valhalla/build/src/bindings/java/libs/native:$LD_LIBRARY_PATH
java -jar your-service.jar
```

### Step 4: Use in Your Service

**Kotlin Example:**
```kotlin
import global.tada.valhalla.Actor
import global.tada.valhalla.config.SingaporeConfig

class RoutingService {
    private val actor: Actor

    init {
        // Initialize with Singapore configuration
        val tileDir = "/data/valhalla_tiles/singapore"
        actor = Actor.createSingapore(tileDir)
    }

    fun calculateRoute(fromLat: Double, fromLon: Double,
                      toLat: Double, toLon: Double): String {
        val request = """
        {
          "locations": [
            {"lat": $fromLat, "lon": $fromLon},
            {"lat": $toLat, "lon": $toLon}
          ],
          "costing": "auto",
          "units": "kilometers"
        }
        """

        return actor.route(request)
    }

    fun findNearestDrivers(pickupLat: Double, pickupLon: Double,
                          driverLocations: List<Pair<Double, Double>>): String {
        val targetsJson = driverLocations.joinToString(",") {
            """{"lat": ${it.first}, "lon": ${it.second}}"""
        }

        val request = """
        {
          "sources": [{"lat": $pickupLat, "lon": $pickupLon}],
          "targets": [$targetsJson],
          "costing": "auto"
        }
        """

        return actor.matrix(request)
    }

    fun close() {
        actor.close()
    }
}
```

**Java Example:**
```java
import global.tada.valhalla.Actor;

public class RoutingService {
    private final Actor actor;

    public RoutingService(String tileDir) {
        this.actor = Actor.createSingapore(tileDir);
    }

    public String calculateRoute(double fromLat, double fromLon,
                                double toLat, double toLon) {
        String request = String.format("""
        {
          "locations": [
            {"lat": %f, "lon": %f},
            {"lat": %f, "lon": %f}
          ],
          "costing": "auto",
          "units": "kilometers"
        }
        """, fromLat, fromLon, toLat, toLon);

        return actor.route(request);
    }

    public void close() {
        actor.close();
    }
}
```

---

## Option 2: Standalone Microservice (Spring Boot Wrapper)

Create a Spring Boot service that embeds `valhalla-jni.jar` and exposes it over HTTP. This is appropriate when non-JVM services need routing access.

```kotlin
@RestController
@RequestMapping("/api/routing")
class RoutingController(private val routingService: RoutingService) {

    @PostMapping("/route")
    fun calculateRoute(@RequestBody request: RouteRequest): ResponseEntity<String> {
        val result = routingService.calculateRoute(
            request.from.lat, request.from.lon,
            request.to.lat, request.to.lon
        )
        return ResponseEntity.ok(result)
    }

    @PostMapping("/matrix")
    fun calculateMatrix(@RequestBody request: MatrixRequest): ResponseEntity<String> {
        val result = routingService.findNearestDrivers(
            request.source.lat, request.source.lon,
            request.targets.map { it.lat to it.lon }
        )
        return ResponseEntity.ok(result)
    }
}

data class RouteRequest(val from: Location, val to: Location)
data class MatrixRequest(val source: Location, val targets: List<Location>)
data class Location(val lat: Double, val lon: Double)
```

### Dockerfile for this microservice

The JAR bundles all native libraries — no need to copy `.so` files separately:

```dockerfile
FROM eclipse-temurin:17-jre-noble

# Copy application JAR (native libs are bundled inside)
COPY your-routing-service.jar /app/app.jar

# Tile data is mounted at runtime — not copied into the image
WORKDIR /app
EXPOSE 8080

ENV VALHALLA_TILE_DIR=/var/valhalla/tiles
ENTRYPOINT ["sh", "-c", "java $JAVA_OPTS -jar app.jar"]
```

```yaml
# docker-compose for the routing microservice
services:
  routing-service:
    image: your-registry/routing-service:latest
    ports:
      - "8080:8080"
    volumes:
      - /path/to/tiles:/var/valhalla/tiles:ro
    environment:
      - VALHALLA_TILE_DIR=/var/valhalla/tiles
      - VALHALLA_REGION=singapore
      - JAVA_OPTS=-Xmx2g -Xms512m -XX:+UseG1GC
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/actuator/health"]
      interval: 30s
      timeout: 10s
      retries: 3
```

---

## Performance Considerations

### Memory Management

- Each `Actor` instance loads tiles into memory (~500MB for Singapore)
- Reuse `Actor` instances across requests (singleton pattern)
- Don't create new `Actor` per request

**Example (single-threaded / low-concurrency only):**
```kotlin
// OK only if this is never called concurrently. For concurrent traffic, use
// ActorPool (next section) — a shared Actor under concurrency will crash.
@Service
class RoutingService {
    companion object {
        private val actor: Actor by lazy {
            Actor.createForRegion("singapore")
        }
    }

    fun route(request: String) = actor.route(request)
}
```

---

## Concurrency: ActorPool (required for concurrent traffic)

A single `Actor` (and `TrafficAwareRouter`, which wraps one) is **single-threaded**.
To serve concurrent requests safely and with throughput, use
`global.tada.valhalla.pool.ActorPool`: a fixed pool of `Actor`s where each
in-flight request borrows one exclusively and returns it when done. This is the
same model upstream Valhalla's HTTP service uses, and it is the fix for the
concurrent-call SIGSEGV.

### Spring `@Bean` wiring

```kotlin
import global.tada.valhalla.pool.ActorPool

@Configuration
class ValhallaConfig {

    // One pool per region the service serves. Closed on context shutdown.
    @Bean(destroyMethod = "close")
    fun routingPool(
        @Value("\${valhalla.region:singapore}") region: String,
        @Value("\${valhalla.pool-size:0}") configuredSize: Int
    ): ActorPool {
        val poolSize = if (configuredSize > 0) configuredSize
                       else Runtime.getRuntime().availableProcessors()
        return ActorPool.forRegion(
            region = region,
            poolSize = poolSize,
            // 256 MiB/actor + reachability 20 + cutoff 10 km are the pooled
            // defaults; override per your memory budget (see Sizing below).
            enableTraffic = false,
            borrowTimeoutMs = 250L
        )
    }
}

@Service
class RoutingService(private val pool: ActorPool) {

    fun route(request: String): String =
        pool.withActor { actor -> actor.route(request) }
}
```

### Backpressure → HTTP 429

When every actor is busy, `withActor` waits up to `borrowTimeoutMs` then throws
`ActorPoolExhaustedException`. Map it to **429 Too Many Requests** so overload
degrades gracefully instead of piling up latency:

```kotlin
@RestControllerAdvice
class RoutingExceptionHandler {
    @ExceptionHandler(ActorPoolExhaustedException::class)
    fun onExhausted(e: ActorPoolExhaustedException): ResponseEntity<String> =
        ResponseEntity.status(HttpStatus.TOO_MANY_REQUESTS)
            .header(HttpHeaders.RETRY_AFTER, "1")
            .body("Routing capacity reached, retry shortly")
}
```

### Driver dispatch via the matrix helper (biggest throughput win)

Use `DriverSelection` to rank K candidate drivers for a rider in ONE
`sources_to_targets` matrix call — instead of K separate `route()` calls. This
collapses rider→K-drivers from K engine searches to one, and holds a pooled
actor once instead of K times.

```kotlin
import global.tada.valhalla.dispatch.DriverSelection

fun assignDriver(rider: DriverSelection.Point,
                 drivers: List<DriverSelection.Point>): Int? {
    val ranked = pool.withActor { actor ->
        DriverSelection.rank(actor, rider, drivers, costing = "auto")
    }
    return ranked.firstOrNull()?.index   // nearest reachable driver
}

// Traffic-aware variant (falls back to predicted speeds when live traffic stale):
fun assignDriverTrafficAware(router: TrafficAwareRouter,
                             rider: DriverSelection.Point,
                             drivers: List<DriverSelection.Point>): Int? =
    DriverSelection.rankTrafficAware(router, rider, drivers).drivers.firstOrNull()?.index
```

> Replaces the old per-driver `actor.route()` loop (`findClosestDrivers` in the
> snippets below). Keep K within the costing's `max_matrix_location_pairs`.

### Per-request timeout

A pathological request can otherwise hold a pooled actor for a long time. Pass a
wall-clock budget; the native engine aborts at the deadline and frees the actor:

```kotlin
pool.withActor { actor ->
    actor.route(request, /* timeoutMs = */ 2_000)   // throws ValhallaException on deadline
}
```

Available on the long-running actions: `route`, `matrix`, `optimizedRoute`,
`isochrone`, `traceRoute`, `traceAttributes` (the last two are map-matching).

### Map-matching (trace_route / trace_attributes)

Map-matching goes through the same pool — borrow an actor and call
`traceRoute`/`traceAttributes`. Pooled actors use a smaller Meili grid cache
(`meiliGridCacheSize`, default 25000 vs 100240) so concurrent map-matching does
not multiply per-actor memory by pool size. Tune via `ActorPool.forRegion(...,
meiliGridCacheSize = ...)` if your traces are denser.

### Sizing — memory budget

Each actor adds ~`maxCacheSizeBytes` of native graph cache **on top of** the JVM
heap. Keep:

```
JVM_Xmx  +  poolSize × maxCacheSizeBytes  +  headroom  ≤  container RAM
```

Example: container 6 GiB, `Xmx` 2 GiB, cache 256 MiB/actor, headroom ≈ 1 GiB
→ `poolSize ≤ (6 − 2 − 1) GiB / 256 MiB ≈ 12`. Routing is CPU-bound, so a good
starting `poolSize` is `availableProcessors()` capped by this budget. The mmap'd
`tile_extract` is OS-page-cache backed and **shared** across actors, so it is
*not* multiplied by poolSize.

If a larger pool OOMs, lower `maxCacheSizeBytes` (the per-actor cache) rather
than dropping the pool — the shared mmap'd extract still backs tile reads.

### Thread Safety

> ⚠️ **A single `Actor` is NOT thread-safe.** Do not call one `Actor` from
> multiple threads, and do **not** use `Actor.routeAsync`/`routeSuspend` on a
> shared instance — they schedule onto the common `ForkJoinPool` /
> `Dispatchers.IO` and will race the single-threaded native workers, corrupting
> state and crashing with a SIGSEGV in `GraphTile::node()`. These `*Async` /
> `*Suspend` methods are deprecated for this reason.

For concurrent traffic use **`ActorPool`** (next section). It is fully
thread-safe and gives each in-flight call its own exclusively-held actor.

```kotlin
@Service
class RoutingService(private val pool: ActorPool) {
    // Safe under concurrency — each call borrows its own actor.
    fun route(from: Location, to: Location): String =
        pool.withActor { it.route(buildRequest(from, to)) }

    // Safe async (dedicated executor, borrow/return per call):
    fun routeAsync(from: Location, to: Location): CompletableFuture<String> =
        pool.supplyAsync { it.route(buildRequest(from, to)) }
}
```

### Connection Pooling (REST API)

If using REST API approach:

```kotlin
@Configuration
class RestTemplateConfig {
    @Bean
    fun restTemplate(): RestTemplate {
        val factory = SimpleClientHttpRequestFactory()
        factory.setConnectTimeout(5000)
        factory.setReadTimeout(10000)

        val connectionManager = PoolingHttpClientConnectionManager()
        connectionManager.maxTotal = 100
        connectionManager.defaultMaxPerRoute = 20

        // Use with RestTemplate
        return RestTemplate(factory)
    }
}
```

---

## Monitoring and Health Checks

### Health Check Endpoint

```kotlin
@RestController
@RequestMapping("/health")
class HealthController(private val actor: Actor) {

    @GetMapping
    fun health(): ResponseEntity<HealthStatus> {
        return try {
            val status = actor.status("{}")
            ResponseEntity.ok(HealthStatus("UP", status))
        } catch (e: Exception) {
            ResponseEntity.status(503)
                .body(HealthStatus("DOWN", e.message))
        }
    }
}

data class HealthStatus(val status: String, val details: String?)
```

### Metrics

```kotlin
@Service
class RoutingMetricsService(
    private val meterRegistry: MeterRegistry,
    private val actor: Actor
) {
    private val routeTimer = meterRegistry.timer("routing.route.duration")
    private val matrixTimer = meterRegistry.timer("routing.matrix.duration")

    fun timedRoute(request: String): String {
        return routeTimer.recordCallable { actor.route(request) }!!
    }

    fun timedMatrix(request: String): String {
        return matrixTimer.recordCallable { actor.matrix(request) }!!
    }
}
```

---

## Deployment Checklist

- [ ] Native libraries accessible (LD_LIBRARY_PATH or bundled)
- [ ] Tile data volume mounted/copied
- [ ] **`ActorPool` used for concurrent traffic — never a shared `Actor`**
- [ ] **Pool size fits the memory budget: `Xmx + poolSize×cache + headroom ≤ container RAM`**
- [ ] **`ActorPoolExhaustedException` mapped to HTTP 429**
- [ ] **Per-request timeout set on route/matrix/trace calls**
- [ ] Driver dispatch uses `DriverSelection` (matrix), not a per-driver route loop
- [ ] Sufficient memory allocated (see budget formula)
- [ ] Health check endpoint configured
- [ ] Metrics/logging enabled (incl. `valhalla_pool_*` gauges)
- [ ] Error handling and retries implemented
- [ ] Horizontal scaling strategy defined

---

## Troubleshooting

### UnsatisfiedLinkError

**Solution:** Ensure `LD_LIBRARY_PATH` includes both:
- `/path/to/libvalhalla.so`
- `/path/to/libvalhalla_jni.so`

### Out of Memory

**Solution:** Increase JVM heap size:
```bash
java -Xmx4g -jar your-service.jar
```

### Tile Loading Errors

**Solution:** Verify tile directory path and permissions:
```bash
ls -la /data/valhalla_tiles/singapore
# Should contain .gph files
```

---

## Code Snippets for Each Use Case

Below are ready-to-use code snippets based on the test suite, covering all common routing scenarios.

### 1. Service Status Check

```kotlin
// Health check endpoint
@GetMapping("/health")
fun checkValhallaHealth(): HealthStatus {
    return try {
        val status = actor.status("""{"verbose": true}""")
        val json = JSONObject(status)
        HealthStatus(
            healthy = true,
            version = json.optString("version"),
            details = status
        )
    } catch (e: Exception) {
        HealthStatus(healthy = false, error = e.message)
    }
}
```

### 2. Calculate Basic Route

```kotlin
// Simple A to B routing
fun calculateRoute(fromLat: Double, fromLon: Double,
                  toLat: Double, toLon: Double): RouteResult {
    val request = """
    {
      "locations": [
        {"lat": $fromLat, "lon": $fromLon},
        {"lat": $toLat, "lon": $toLon}
      ],
      "costing": "auto",
      "units": "kilometers"
    }
    """

    val result = actor.route(request)
    val json = JSONObject(result)
    val summary = json.getJSONObject("trip").getJSONObject("summary")

    return RouteResult(
        distanceKm = summary.getDouble("length"),
        durationMin = summary.getInt("time") / 60.0
    )
}

// Usage
val route = calculateRoute(1.2820, 103.8509, 1.3521, 103.8198)
println("Distance: ${route.distanceKm} km, Time: ${route.durationMin} min")
```

### 3. Route with Multiple Waypoints

```kotlin
// Route through multiple stops (e.g., pickup multiple passengers)
fun calculateMultiStopRoute(locations: List<Location>): RouteResult {
    val locationsJson = locations.joinToString(",") {
        """{"lat": ${it.lat}, "lon": ${it.lon}}"""
    }

    val request = """
    {
      "locations": [$locationsJson],
      "costing": "auto",
      "units": "kilometers"
    }
    """

    val result = actor.route(request)
    // Parse result same as basic route
    return parseRouteResult(result)
}

// Usage
val stops = listOf(
    Location(1.2820, 103.8509),  // Start
    Location(1.3000, 103.8300),  // Stop 1
    Location(1.3521, 103.8198)   // End
)
val route = calculateMultiStopRoute(stops)
```

### 4. Expressway/Highway Preferred Route

```kotlin
// Route preferring highways (faster for long distances)
fun calculateExpresswayRoute(fromLat: Double, fromLon: Double,
                             toLat: Double, toLon: Double): RouteResult {
    val request = """
    {
      "locations": [
        {"lat": $fromLat, "lon": $fromLon},
        {"lat": $toLat, "lon": $toLon}
      ],
      "costing": "auto",
      "costing_options": {
        "auto": {
          "use_highways": 1.0
        }
      },
      "units": "kilometers"
    }
    """

    return parseRouteResult(actor.route(request))
}

// Usage - for airport trips, cross-island routes
val route = calculateExpresswayRoute(1.3405, 103.6771, 1.3644, 103.9915)
```

### 5. Multi-Waypoint Optimization (TSP Solver)

```kotlin
// Optimize route to visit multiple locations (delivery routing)
fun optimizeDeliveryRoute(stops: List<Location>): OptimizedRoute {
    val locationsJson = stops.joinToString(",") {
        """{"lat": ${it.lat}, "lon": ${it.lon}}"""
    }

    val request = """
    {
      "locations": [$locationsJson],
      "costing": "auto",
      "units": "kilometers"
    }
    """

    val result = actor.optimizedRoute(request)
    val json = JSONObject(result)
    val summary = json.getJSONObject("trip").getJSONObject("summary")

    return OptimizedRoute(
        totalDistanceKm = summary.getDouble("length"),
        totalDurationMin = summary.getInt("time") / 60.0,
        optimizedOrder = extractWaypointOrder(json)
    )
}

// Usage - delivery with 5 stops
val deliveryStops = listOf(
    Location(1.2820, 103.8509),
    Location(1.3000, 103.8300),
    Location(1.3100, 103.8350),
    Location(1.3020, 103.8280),
    Location(1.2900, 103.8400)
)
val optimized = optimizeDeliveryRoute(deliveryStops)
println("Optimized route: ${optimized.totalDistanceKm} km")
```

### 6. Driver Dispatch - Find Closest Drivers

> **Prefer `DriverSelection`** (see [Concurrency](#concurrency-actorpool-required-for-concurrent-traffic)).
> The snippet below is illustrative of the raw matrix call; `DriverSelection.rank`
> wraps it, handles both matrix response shapes (verbose + slim), excludes
> unreachable drivers, and is pool-safe.

```kotlin
// Find nearest N drivers to a pickup location
fun findClosestDrivers(pickupLat: Double, pickupLon: Double,
                      driverLocations: List<Location>,
                      limit: Int = 5): List<DriverETA> {
    val targetsJson = driverLocations.joinToString(",") {
        """{"lat": ${it.lat}, "lon": ${it.lon}}"""
    }

    val request = """
    {
      "sources": [{"lat": $pickupLat, "lon": $pickupLon}],
      "targets": [$targetsJson],
      "costing": "auto"
    }
    """

    val result = actor.matrix(request)
    val json = JSONObject(result)
    val matrix = json.getJSONArray("sources_to_targets")

    val driverETAs = mutableListOf<DriverETA>()
    for (i in 0 until matrix.length()) {
        val row = matrix.getJSONObject(i)
        driverETAs.add(
            DriverETA(
                driverIndex = i,
                location = driverLocations[i],
                etaSeconds = row.getDouble("time").toInt(),
                distanceKm = row.optDouble("distance", 0.0)
            )
        )
    }

    // Return closest N drivers
    return driverETAs.sortedBy { it.etaSeconds }.take(limit)
}

// Usage
val pickupLocation = Location(1.3048, 103.8318)
val availableDrivers = listOf(
    Location(1.3000, 103.8300),
    Location(1.3100, 103.8350),
    Location(1.3020, 103.8280),
    Location(1.3080, 103.8320),
    Location(1.2980, 103.8290)
)
val closest = findClosestDrivers(pickupLocation.lat, pickupLocation.lon,
                                availableDrivers, limit = 3)
closest.forEach {
    println("Driver ${it.driverIndex}: ETA ${it.etaSeconds}s, ${it.distanceKm}km")
}
```

### 7. Motorcycle Routing

```kotlin
// Calculate route for motorcycles (different road restrictions)
fun calculateMotorcycleRoute(fromLat: Double, fromLon: Double,
                            toLat: Double, toLon: Double): RouteResult {
    val request = """
    {
      "locations": [
        {"lat": $fromLat, "lon": $fromLon},
        {"lat": $toLat, "lon": $toLon}
      ],
      "costing": "motorcycle",
      "units": "kilometers"
    }
    """

    return parseRouteResult(actor.route(request))
}

// Usage
val bikeRoute = calculateMotorcycleRoute(1.3048, 103.8318, 1.3644, 103.9915)
```

### 8. Isochrone - Reachability Analysis

```kotlin
// Calculate area reachable within N minutes
fun calculateServiceArea(centerLat: Double, centerLon: Double,
                        minutes: Int): GeoJsonResult {
    val request = """
    {
      "locations": [{"lat": $centerLat, "lon": $centerLon}],
      "costing": "auto",
      "contours": [{"time": $minutes}],
      "polygons": true
    }
    """

    val result = actor.isochrone(request)
    return GeoJsonResult(geoJson = result, minutes = minutes)
}

// Usage - show 15-minute delivery radius
val serviceArea = calculateServiceArea(1.2820, 103.8509, 15)
// Returns GeoJSON polygon you can display on a map

// Multiple time ranges
fun calculateMultipleIsochrones(centerLat: Double, centerLon: Double): GeoJsonResult {
    val request = """
    {
      "locations": [{"lat": $centerLat, "lon": $centerLon}],
      "costing": "auto",
      "contours": [{"time": 5}, {"time": 10}, {"time": 15}],
      "polygons": true
    }
    """

    return GeoJsonResult(geoJson = actor.isochrone(request))
}
```

### 9. Snap to Road / Map Matching

```kotlin
// Snap GPS coordinates to nearest road
fun snapToRoad(lat: Double, lon: Double): SnappedLocation {
    val request = """
    {
      "locations": [{"lat": $lat, "lon": $lon}],
      "costing": "auto",
      "verbose": true
    }
    """

    val result = actor.locate(request)
    val json = JSONObject(result)

    if (json.has("locations")) {
        val locations = json.getJSONArray("locations")
        if (locations.length() > 0) {
            val loc = locations.getJSONObject(0)
            return SnappedLocation(
                originalLat = lat,
                originalLon = lon,
                snappedLat = loc.getDouble("lat"),
                snappedLon = loc.getDouble("lon"),
                success = true
            )
        }
    }

    return SnappedLocation(lat, lon, lat, lon, success = false)
}

// Usage - validate pickup/dropoff locations
val snapped = snapToRoad(1.2820, 103.8509)
if (snapped.success) {
    println("Snapped from ${snapped.originalLat} to ${snapped.snappedLat}")
}
```

### 10. Complete Service Bean Example

```kotlin
@Service
class ValhallaRoutingService(
    @Value("\${valhalla.tile-dir}") private val tileDir: String
) {
    private lateinit var actor: Actor

    @PostConstruct
    fun init() {
        actor = Actor.createSingapore(tileDir)
    }

    @PreDestroy
    fun cleanup() {
        actor.close()
    }

    // Include all methods above here
    fun calculateRoute(...) { ... }
    fun findClosestDrivers(...) { ... }
    fun calculateIsochrone(...) { ... }
    // etc.
}

// Usage in your controller
@RestController
class RideHailingController(
    private val routingService: ValhallaRoutingService
) {

    @PostMapping("/api/rides/estimate")
    fun estimateRide(@RequestBody request: RideRequest): RideEstimate {
        val route = routingService.calculateRoute(
            request.pickup.lat, request.pickup.lon,
            request.dropoff.lat, request.dropoff.lon
        )

        return RideEstimate(
            distanceKm = route.distanceKm,
            durationMin = route.durationMin,
            estimatedFare = calculateFare(route.distanceKm)
        )
    }

    @PostMapping("/api/drivers/dispatch")
    fun dispatchDriver(@RequestBody request: DispatchRequest): DriverAssignment {
        val drivers = routingService.findClosestDrivers(
            request.pickup.lat, request.pickup.lon,
            request.availableDrivers,
            limit = 1
        )

        return DriverAssignment(
            driverId = drivers.first().driverIndex,
            etaSeconds = drivers.first().etaSeconds
        )
    }
}
```

### Data Classes

```kotlin
data class Location(val lat: Double, val lon: Double, val name: String? = null)
data class RouteResult(val distanceKm: Double, val durationMin: Double)
data class DriverETA(
    val driverIndex: Int,
    val location: Location,
    val etaSeconds: Int,
    val distanceKm: Double
)
data class GeoJsonResult(val geoJson: String, val minutes: Int = 0)
data class SnappedLocation(
    val originalLat: Double,
    val originalLon: Double,
    val snappedLat: Double,
    val snappedLon: Double,
    val success: Boolean
)
```

---

## Example Integration

See the test suite for complete examples:
- `src/bindings/java/src/test/kotlin/global/tada/valhalla/singapore/SingaporeRideHaulingTest.kt`
