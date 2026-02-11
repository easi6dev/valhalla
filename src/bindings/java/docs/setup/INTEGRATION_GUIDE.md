# Valhalla Integration Guide

This guide explains how to integrate Valhalla routing engine into your other services.

## Architecture Options

### Option 1: Direct JNI Integration (Embedded)

Use Valhalla JNI bindings directly within your Java/Kotlin service.

**Pros:**
- Lowest latency (in-process)
- No network overhead
- Simplest deployment

**Cons:**
- Requires native library deployment
- Memory overhead in application JVM
- Must be Java/Kotlin service

**Use Case:** Best for monolithic applications or when ultra-low latency is critical.

### Option 2: Standalone Microservice (REST API)

Deploy Valhalla as a separate microservice with REST API.

**Pros:**
- Language-agnostic client access
- Horizontal scaling
- Independent deployment
- Can use existing Valhalla HTTP service

**Cons:**
- Network latency
- Additional infrastructure
- More complex deployment

**Use Case:** Best for microservices architecture with multiple language clients.

### Option 3: Shared Service Library

Package JNI bindings as a shared library across multiple JVM services.

**Pros:**
- Reusable across Java services
- Consistent versioning
- Centralized maintenance

**Cons:**
- Requires shared artifact repository
- Native library distribution complexity

**Use Case:** Best for organizations with multiple Java/Kotlin services.

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

## Option 2: Standalone Microservice

### Approach A: Use Official Valhalla HTTP Service

Build and deploy the official Valhalla HTTP service:

```bash
# Build Valhalla with HTTP services enabled
cmake -B build \
  -DCMAKE_BUILD_TYPE=Release \
  -DENABLE_SERVICES=ON

cmake --build build -j4

# Run the service
./build/valhalla_service /path/to/valhalla-singapore.json
```

### Approach B: Create Spring Boot Wrapper

Create a Spring Boot service that wraps the JNI bindings:

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

### Dockerfile for Microservice

```dockerfile
FROM openjdk:17-slim

# Install native dependencies
RUN apt-get update && apt-get install -y \
    libboost-all-dev \
    libcurl4-openssl-dev \
    libprotobuf-dev \
    libsqlite3-dev \
    liblz4-dev \
    zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

# Copy native libraries
COPY build/src/libvalhalla.so* /usr/local/lib/
COPY build/src/bindings/java/libs/native/libvalhalla_jni.so /usr/local/lib/
RUN ldconfig

# Copy tile data
COPY data/valhalla_tiles/singapore /data/valhalla_tiles/singapore

# Copy application JAR
COPY your-service.jar /app/app.jar

WORKDIR /app
EXPOSE 8080

CMD ["java", "-jar", "app.jar"]
```

---

## Option 3: Docker Compose Integration

If you're using Docker Compose for local development:

```yaml
version: '3.8'

services:
  valhalla-routing:
    build:
      context: ./valhalla
      dockerfile: Dockerfile.routing-service
    ports:
      - "8088:8080"
    volumes:
      - ./data/valhalla_tiles:/data/valhalla_tiles:ro
    environment:
      - JAVA_OPTS=-Xmx2g
      - VALHALLA_TILE_DIR=/data/valhalla_tiles/singapore
    healthcheck:
      test: [ "CMD", "curl", "-f", "http://localhost:8080/health" ]
      interval: 30s
      timeout: 10s
      retries: 3

  your-service:
    build: ../../../../../config
    ports:
      - "8080:8080"
    depends_on:
      - valhalla-routing
    environment:
      - ROUTING_SERVICE_URL=http://valhalla-routing:8080
```

---

## Performance Considerations

### Memory Management

- Each `Actor` instance loads tiles into memory (~500MB for Singapore)
- Reuse `Actor` instances across requests (singleton pattern)
- Don't create new `Actor` per request

**Example Singleton:**
```kotlin
@Service
class RoutingService {
    companion object {
        private val actor: Actor by lazy {
            Actor.createSingapore("/data/valhalla_tiles/singapore")
        }
    }

    fun route(request: String) = actor.route(request)
}
```

### Thread Safety

The JNI `Actor` is thread-safe. You can safely call it from multiple threads:

```kotlin
@Service
class RoutingService(
    private val actor: Actor = Actor.createSingapore(tilePath)
) {
    // Can be called concurrently
    suspend fun routeAsync(from: Location, to: Location): String =
        withContext(Dispatchers.IO) {
            actor.route(buildRequest(from, to))
        }
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
- [ ] Sufficient memory allocated (2GB+ recommended)
- [ ] Health check endpoint configured
- [ ] Metrics/logging enabled
- [ ] Connection pooling configured (if using REST)
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
