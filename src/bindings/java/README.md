# Valhalla Java/Kotlin Bindings

Java/Kotlin JNI bindings for the [Valhalla](https://github.com/valhalla/valhalla) routing engine.

## Features

- **Full Valhalla API Support**: Route, matrix, isochrone, map-matching, and more
- **Modern Kotlin API**: Null-safe, idiomatic Kotlin code with comprehensive KDoc
- **Safe concurrency**: `ActorPool` borrows one Actor per request, with
  bounded wait and backpressure (`ActorPoolExhaustedException` -> HTTP 429)
- **Per-request timeouts**: `(request, timeoutMs)` overloads on the main actions
- **Type Safety**: Strong typing with exception handling
- **Resource Management**: AutoCloseable support for proper resource cleanup
- **Java 17+**: Built with modern Java features

## Requirements

### Runtime Requirements
- Java 17 or higher
- Pre-built Valhalla routing tiles

### Build Requirements
- JDK 17 or higher
- CMake 3.15+
- C++17 compatible compiler
- Valhalla C++ library and its dependencies

## Installation

### Using Maven

```xml
<dependency>
    <groupId>global.tada</groupId>
    <artifactId>valhalla-jni</artifactId>
    <version>1.0.0-SNAPSHOT</version>
</dependency>
```

### Using Gradle

```kotlin
dependencies {
    implementation("global.tada:valhalla-jni:1.0.0-SNAPSHOT")
}
```

## Building from Source

Use the build script — it creates the `libvalhalla.so.3` / `libvalhalla.so`
symlinks, compiles `libvalhalla_jni.so`, and packages the JAR in one step:

```bash
cd src/bindings/java
SKIP_APT_INSTALL=1 ./build-jni-bindings.sh
```

Invoking CMake directly skips the symlink step and produces a JAR that fails at
runtime with `UnsatisfiedLinkError`.

Install to the local Maven repository:

```bash
./gradlew publishToMavenLocal
```

Full prerequisites, the Docker build alternative, and tile generation are in
[docs/setup/BUILD_AND_RUN.md](docs/setup/BUILD_AND_RUN.md).

## Usage

### Basic Example (Kotlin)

```kotlin
import global.tada.valhalla.Actor
import global.tada.valhalla.ValhallaException

fun main() {
    val config = """
    {
      "mjolnir": {
        "tile_dir": "/path/to/valhalla_tiles",
        "concurrency": 4
      },
      "loki": {
        "actions": ["route", "locate", "sources_to_targets"],
        "logging": { "long_request": 100 },
        "service_defaults": {
          "minimum_reachability": 50,
          "radius": 0,
          "search_cutoff": 35000,
          "node_snap_tolerance": 5,
          "street_side_tolerance": 5,
          "heading_tolerance": 60
        }
      },
      "service_limits": {
        "auto": { "max_distance": 5000000.0 },
        "pedestrian": { "max_distance": 250000.0 }
      }
    }
    """.trimIndent()

    // Create actor (use AutoCloseable for automatic resource management)
    Actor(config).use { actor ->
        // Route request
        val routeRequest = """
        {
          "locations": [
            {"lat": 40.748817, "lon": -73.985428},
            {"lat": 40.751455, "lon": -73.989541}
          ],
          "costing": "auto",
          "directions_options": {
            "units": "miles"
          }
        }
        """.trimIndent()

        try {
            val result = actor.route(routeRequest)
            println("Route result: $result")
        } catch (e: ValhallaException) {
            println("Routing failed: ${e.message}")
        }
    }
}
```

### Concurrent Example (ActorPool)

For any service handling concurrent requests, use `ActorPool` rather than
sharing a single `Actor`.

```kotlin
import global.tada.valhalla.pool.ActorPool
import global.tada.valhalla.pool.ActorPoolExhaustedException

val pool = ActorPool.forRegion("singapore", poolSize = 8)

fun handle(request: String): String =
    try {
        pool.withActor { actor -> actor.route(request) }
    } catch (e: ActorPoolExhaustedException) {
        throw ResponseStatusException(HttpStatus.TOO_MANY_REQUESTS, "pool busy")
    }
```

From Java, `supplyAsync` returns a `CompletableFuture` backed by the same pool:

```java
CompletableFuture<String> future =
    pool.supplyAsync(250L, actor -> actor.route(request));
```

Close the pool on shutdown — it closes every Actor it owns:

```kotlin
pool.close()
```

`withActor` blocks up to `borrowTimeoutMs` (default 250 ms) waiting for a free
Actor, then throws `ActorPoolExhaustedException` — map that to HTTP 429 so load
sheds instead of queueing without bound.

Sizing: `JVM_Xmx + poolSize × maxCacheSizeBytes + headroom ≤ container RAM`
(pooled default cache is 256 MiB per Actor).

## API Reference

### Main Methods

All methods accept a JSON request string and return a JSON response string (except `tile` which returns binary data).

#### Routing Methods
- `route(request: String): String` - Calculate a route
- `optimizedRoute(request: String): String` - Optimize waypoint order
- `traceRoute(request: String): String` - Map-match GPS trace

#### Analysis Methods
- `matrix(request: String): String` - Compute time/distance matrix
- `isochrone(request: String): String` - Calculate isochrones
- `expansion(request: String): String` - Get routing graph expansion

#### Utility Methods
- `locate(request: String): String` - Get node/edge information
- `height(request: String): String` - Get elevation data
- `transitAvailable(request: String): String` - Check transit availability
- `status(request: String): String` - Get configuration status
- `tile(request: String): ByteArray` - Get vector tile (MVT)

### Async Variants

> **Deprecated.** The `*Async` (CompletableFuture) and `*Suspend` (coroutine)
> variants are deprecated: they schedule work on a shared pool while the
> underlying Actor is single-threaded, so concurrent calls race the native
> workers. Use `ActorPool.withActor { it.route(request) }` instead — see
> [Thread Safety](#thread-safety).

For a per-request deadline, the synchronous actions take a timeout overload:
`route`, `matrix`, `optimizedRoute`, `isochrone`, `traceRoute` and
`traceAttributes` all accept `(request: String, timeoutMs: Long)`.

## Configuration

The configuration JSON follows the standard Valhalla configuration format. Key sections include:

- `mjolnir.tile_dir`: Path to routing tiles (required)
- `loki`: Service configuration
- `service_limits`: Per-costing-model limits

For detailed configuration options, see the [Valhalla documentation](https://valhalla.github.io/valhalla/api/turn-by-turn/api-reference/).

## Error Handling

All methods throw `ValhallaException` on errors. It's recommended to wrap calls in try-catch blocks:

```kotlin
try {
    val result = actor.route(request)
    // Process result
} catch (e: ValhallaException) {
    // Handle error
    println("Error: ${e.message}")
}
```

## Resource Management

The `Actor` class implements `AutoCloseable`, so it's recommended to use it with try-with-resources (Java) or `use` (Kotlin):

```kotlin
// Kotlin
Actor(config).use { actor ->
    // Use actor
} // Automatically closed

// Java
try (Actor actor = new Actor(config)) {
    // Use actor
} // Automatically closed
```

## Performance Tips

1. **Reuse Actor instances**: Creating an Actor is expensive (it loads tiles). Never create one per request.
2. **Use `ActorPool` for concurrency**: one Actor per in-flight request. Do not share an Actor across threads.
3. **Size the pool against RAM**: `JVM_Xmx + poolSize × maxCacheSizeBytes + headroom ≤ container RAM`.
4. **Set a per-request timeout**: use the `(request, timeoutMs)` overloads so a slow route cannot pin a pooled Actor.
5. **Batch requests**: use the matrix API instead of many individual route requests where appropriate.

## Thread Safety

**A single `Actor` is NOT thread-safe.** It wraps the native
`valhalla::tyr::actor_t`, which is single-threaded; calling into one Actor from
multiple threads races the native workers and can crash the JVM. The deprecated
`*Async` / `*Suspend` methods on `Actor` are unsafe for the same reason.

Use `ActorPool` for concurrent traffic — see
[Concurrent Example](#concurrent-example-actorpool) above, and
[docs/setup/INTEGRATION_GUIDE.md](docs/setup/INTEGRATION_GUIDE.md#concurrency-actorpool-required-for-concurrent-traffic)
for pool sizing, backpressure and timeouts.

## Troubleshooting

### Native Library Loading Issues

If you get `UnsatisfiedLinkError`, ensure:

1. The native library is in your `java.library.path`
2. All Valhalla dependencies (boost, protobuf, etc.) are available
3. On Linux/macOS, check with `ldd` (Linux) or `otool -L` (macOS) to verify dependencies

### Configuration Errors

If `Actor` creation fails:

1. Verify the config JSON is valid
2. Check that `tile_dir` exists and contains valid tiles
3. Review Valhalla logs for detailed error messages

## Examples

Worked examples live in the test sources — `SingaporeRideHaulingTest`,
`NewYorkRideHaulingTest`, `MultiRegionAPITest` and `ActorPoolTest` under
`src/test/kotlin/global/tada/valhalla/`. Runnable samples are in `examples/` at
the repo root.

## Documentation

See [docs/README.md](docs/README.md) for the full index.

## License

This project follows the Valhalla project's license (MIT).

## Links

- [Valhalla Documentation](https://valhalla.github.io/valhalla/)
- [Valhalla GitHub](https://github.com/valhalla/valhalla)
- [API Reference](https://valhalla.github.io/valhalla/api/)
