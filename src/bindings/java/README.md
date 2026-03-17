# Valhalla Java/Kotlin Bindings

Java/Kotlin JNI bindings for the [Valhalla](https://github.com/valhalla/valhalla) routing engine.

## Features

- **Full Valhalla API Support**: Route, matrix, isochrone, map-matching, and more
- **Modern Kotlin API**: Null-safe, idiomatic Kotlin code with comprehensive KDoc
- **Multiple Programming Styles**:
  - Synchronous API for simple use cases
  - CompletableFuture-based async API for Java compatibility
  - Kotlin Coroutines support for modern async programming
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
    <groupId>global.tada.valhalla</groupId>
    <artifactId>valhalla-jni</artifactId>
    <version>1.0.0-SNAPSHOT</version>
</dependency>
```

### Using Gradle

```kotlin
dependencies {
    implementation("global.tada.valhalla:valhalla-jni:1.0.0-SNAPSHOT")
}
```

## Building from Source

### 1. Build Native Library

First, build the JNI native library using CMake:

```bash
cd valhalla/src/bindings/java
cmake -B build -S .
cmake --build build --config Release
```

This will generate the native library (`libvalhalla_jni.so`, `libvalhalla_jni.dylib`, or `valhalla_jni.dll` depending on your platform).

### 2. Build Java/Kotlin Library

Build the Java/Kotlin library using Gradle:

```bash
./gradlew build
```

Or use the Gradle wrapper on Windows:

```cmd
gradlew.bat build
```

The built JAR will be located in `build/libs/`.

### 3. Install to Local Maven Repository

```bash
./gradlew publishToMavenLocal
```

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

### Async Example with CompletableFuture (Java)

```java
import global.tada.valhalla.Actor;
import global.tada.valhalla.ValhallaException;

public class RouteExample {
    public static void main(String[] args) {
        String config = "{ ... }"; // Your config here

        try (Actor actor = new Actor(config)) {
            String request = "{ ... }"; // Your request here

            actor.routeAsync(request)
                .thenAccept(result -> System.out.println("Route: " + result))
                .exceptionally(ex -> {
                    System.err.println("Error: " + ex.getMessage());
                    return null;
                })
                .join();
        } catch (ValhallaException e) {
            System.err.println("Failed to create actor: " + e.getMessage());
        }
    }
}
```

### Async Example with Kotlin Coroutines

```kotlin
import global.tada.valhalla.Actor
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll

fun main() = runBlocking {
    val config = "{ ... }" // Your config here

    Actor(config).use { actor ->
        val requests = listOf(
            """{"locations": [...], "costing": "auto"}""",
            """{"locations": [...], "costing": "pedestrian"}"""
        )

        // Process multiple requests concurrently
        val results = requests.map { request ->
            async {
                try {
                    actor.routeSuspend(request)
                } catch (e: ValhallaException) {
                    "Error: ${e.message}"
                }
            }
        }.awaitAll()

        results.forEach { println(it) }
    }
}
```

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

All methods have async variants:
- **CompletableFuture**: `methodAsync(request: String): CompletableFuture<String>`
- **Kotlin Coroutines**: `methodSuspend(request: String): String` (suspend function)

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

1. **Reuse Actor instances**: Creating an Actor is expensive. Reuse it for multiple requests.
2. **Use async APIs**: For high throughput, use `routeAsync` or `routeSuspend` with concurrent requests.
3. **Configure thread pools**: CompletableFuture uses the common ForkJoinPool by default. Consider custom executors for better control.
4. **Batch requests**: Use matrix API instead of multiple individual route requests when appropriate.

## Thread Safety

- Each `Actor` instance is thread-safe and can be used from multiple threads concurrently.
- The underlying C++ actor uses thread-local storage to ensure thread safety.

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

See the `src/test/kotlin` directory for more examples.

## License

This project follows the Valhalla project's license (MIT).

## Contributing

Contributions are welcome! Please submit issues and pull requests to the main Valhalla repository.

## Links

- [Valhalla Documentation](https://valhalla.github.io/valhalla/)
- [Valhalla GitHub](https://github.com/valhalla/valhalla)
- [API Reference](https://valhalla.github.io/valhalla/api/)
