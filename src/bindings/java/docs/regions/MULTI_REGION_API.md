# Multi-Region Usage Guide

This guide shows how to use Valhalla with multiple regions after the refactoring.

## Quick Start

### Creating an Actor for Any Region

```kotlin
import global.tada.valhalla.Actor

// Singapore
val sgActor = Actor.createForRegion("singapore")

// Thailand
val thActor = Actor.createForRegion("thailand")

// With custom tile directory
val actor = Actor.createForRegion("thailand", "/path/to/thailand/tiles")

// With traffic enabled
val trafficActor = Actor.createForRegion("singapore", enableTraffic = true)
```

### Using Country Codes

```kotlin
// Short aliases work too
val sgActor = Actor.createForRegion("sg")
val thActor = Actor.createForRegion("th")
```

### Getting Region Information

```kotlin
import global.tada.valhalla.config.RegionConfigFactory

// List all supported regions
val regions = RegionConfigFactory.getSupportedRegions()
println(regions) // [singapore, thailand]

// Check if a region is supported
if (RegionConfigFactory.isSupported("thailand")) {
    println("Thailand is supported!")
}

// Get detailed region information
val info = RegionConfigFactory.getRegionInfo("singapore")
println(info["name"])      // Singapore
println(info["timezone"])  // Asia/Singapore
println(info["currency"])  // SGD
println(info["bounds"])    // {minLat=1.15, maxLat=1.48, ...}
```

## Advanced Usage

### Working with Region Bounds

```kotlin
import global.tada.valhalla.config.SingaporeConfig
import global.tada.valhalla.config.ThailandConfig

// Check if a location is within Singapore
val isSG = SingaporeConfig.bounds.isValidLocation(1.3, 103.8)
println(isSG) // true

// Check if a location is within Thailand
val isTH = ThailandConfig.bounds.isValidLocation(13.7, 100.5)
println(isTH) // true (Bangkok)

// Get region center
val sgCenter = SingaporeConfig.bounds.center()
println("Singapore center: ${sgCenter.first}, ${sgCenter.second}")

// Calculate region area
val thArea = ThailandConfig.bounds.approximateArea()
println("Thailand area: ${thArea} km²") // ~513,000 km²
```

### Custom Costing Profiles

```kotlin
import global.tada.valhalla.config.RegionConfigFactory

val config = RegionConfigFactory.getConfig("singapore")

// Get auto profile
val autoProfile = config.autoProfile()

// Get motorcycle profile
val motorcycleProfile = config.motorcycleProfile()

// Get taxi profile
val taxiProfile = config.taxiProfile()
```

### Building Custom Configurations

```kotlin
import global.tada.valhalla.config.RegionConfigFactory

// Build configuration for a specific region
val configJson = RegionConfigFactory.buildConfig(
    region = "thailand",
    tileDir = "/data/valhalla_tiles/thailand",
    enableTraffic = false
)

// Create Actor with custom config
val actor = Actor(configJson)
```

## Migration from Singapore-Only Code

### Before (Singapore-specific)

```kotlin
// Old way - hardcoded Singapore
val actor = Actor.createSingapore()
val config = SingaporeConfig.buildConfig("/path/to/tiles")
val isValid = SingaporeConfig.Bounds.isValidLocation(1.3, 103.8)
```

### After (Multi-region)

```kotlin
// New way - supports any region
val actor = Actor.createForRegion("singapore")
val config = RegionConfigFactory.buildConfig("singapore", "/path/to/tiles")
val isValid = SingaporeConfig.bounds.isValidLocation(1.3, 103.8)
```

**Note:** The old way still works but shows deprecation warnings.

## Adding a New Region

### Step 1: Create Region Config

Create a new file: `src/bindings/java/src/main/kotlin/global/tada/valhalla/config/MalaysiaConfig.kt`

```kotlin
package global.tada.valhalla.config

import java.io.File

object MalaysiaConfig : RegionConfig {

    override val regionName = "Malaysia"
    override val timezone = "Asia/Kuala_Lumpur"
    override val locale = "ms-MY"
    override val currency = "MYR"

    override val bounds = RegionConfig.Bounds(
        minLat = 1.3,
        maxLat = 6.7,
        minLon = 99.6,
        maxLon = 119.3
    )

    override fun buildConfig(
        tileDir: String,
        enableTraffic: Boolean
    ): String {
        val resolvedTileDir = File(tileDir).canonicalPath.replace("\\", "/")

        return """
        {
          "mjolnir": {
            "tile_dir": "$resolvedTileDir",
            "max_cache_size": 2147483648,
            "concurrency": 4
          },
          // ... rest of configuration
        }
        """.trimIndent()
    }

    override fun autoProfile() = """
        {
          "costing": "auto",
          "costing_options": {
            "auto": {
              "maneuver_penalty": 5,
              "use_highways": 1.0,
              "use_tolls": 0.9,
              "top_speed": 110
            }
          }
        }
        """.trimIndent()

    override fun motorcycleProfile() = """
        {
          "costing": "motorcycle",
          "costing_options": {
            "motorcycle": {
              "maneuver_penalty": 5,
              "use_highways": 1.0,
              "use_tolls": 0.8,
              "top_speed": 110
            }
          }
        }
        """.trimIndent()

    override fun taxiProfile() = """
        {
          "costing": "auto",
          "costing_options": {
            "auto": {
              "maneuver_penalty": 5,
              "use_highways": 1.0,
              "use_tolls": 0.9,
              "top_speed": 110
            }
          }
        }
        """.trimIndent()
}
```

### Step 2: Register in Factory

Edit `RegionConfigFactory.kt`:

```kotlin
fun getConfig(region: String): RegionConfig {
    return when (region.lowercase().trim()) {
        "singapore", "sg" -> SingaporeConfig
        "thailand", "th" -> ThailandConfig
        "malaysia", "my" -> MalaysiaConfig  // Add this line
        else -> throw IllegalArgumentException(
            "Unsupported region: '$region'. Supported regions: ${getSupportedRegions().joinToString(", ")}"
        )
    }
}

fun getSupportedRegions(): List<String> {
    return listOf(
        "singapore",
        "thailand",
        "malaysia"  // Add this line
    )
}

fun getRegionAliases(): Map<String, String> {
    return mapOf(
        "singapore" to "singapore",
        "sg" to "singapore",
        "thailand" to "thailand",
        "th" to "thailand",
        "malaysia" to "malaysia",  // Add this line
        "my" to "malaysia"         // Add this line
    )
}
```

### Step 3: Add to regions.json

Edit `config/regions/regions.json`:

```json
{
  "regions": {
    "singapore": { ... },
    "thailand": { ... },
    "malaysia": {
      "name": "Malaysia",
      "enabled": true,
      "osm_source": "https://download.geofabrik.de/asia/malaysia-singapore-brunei-latest.osm.pbf",
      "bounds": {
        "min_lat": 1.3,
        "max_lat": 6.7,
        "min_lon": 99.6,
        "max_lon": 119.3
      },
      "tile_dir": "data/valhalla_tiles/malaysia",
      "default_costing": "auto",
      "timezone": "Asia/Kuala_Lumpur",
      "locale": "ms-MY",
      "currency": "MYR"
    }
  }
}
```

### Step 4: Use the New Region

```kotlin
// Download OSM data
// ./scripts/regions/download-region-osm.sh malaysia

// Build tiles
// ./scripts/regions/build-tiles.sh malaysia

// Use in code
val actor = Actor.createForRegion("malaysia")
val route = actor.route("""
{
  "locations": [
    {"lat": 3.139, "lon": 101.687},  // Kuala Lumpur
    {"lat": 5.414, "lon": 100.333}   // George Town
  ],
  "costing": "auto"
}
""")
```

## Complete Example: Multi-Region Routing Service

```kotlin
import global.tada.valhalla.Actor
import global.tada.valhalla.config.RegionConfigFactory

class MultiRegionRoutingService {

    private val actors = mutableMapOf<String, Actor>()

    init {
        // Initialize all supported regions
        RegionConfigFactory.getSupportedRegions().forEach { region ->
            try {
                actors[region] = Actor.createForRegion(region)
                println("✓ Loaded $region")
            } catch (e: Exception) {
                println("✗ Failed to load $region: ${e.message}")
            }
        }
    }

    fun route(region: String, requestJson: String): String {
        val actor = actors[region.lowercase()]
            ?: throw IllegalArgumentException("Region not loaded: $region")

        return actor.route(requestJson)
    }

    fun getSupportedRegions(): List<String> {
        return actors.keys.toList()
    }

    fun getRegionInfo(region: String): Map<String, Any> {
        return RegionConfigFactory.getRegionInfo(region)
    }

    fun close() {
        actors.values.forEach { it.close() }
        actors.clear()
    }
}

// Usage
fun main() {
    val service = MultiRegionRoutingService()

    // Route in Singapore
    val sgRoute = service.route("singapore", """
    {
      "locations": [
        {"lat": 1.290, "lon": 103.851},
        {"lat": 1.357, "lon": 103.987}
      ],
      "costing": "auto"
    }
    """)

    // Route in Thailand
    val thRoute = service.route("thailand", """
    {
      "locations": [
        {"lat": 13.756, "lon": 100.502},
        {"lat": 18.788, "lon": 98.986}
      ],
      "costing": "auto"
    }
    """)

    println("Supported regions: ${service.getSupportedRegions()}")

    service.close()
}
```

## Best Practices

### 1. Always Use createForRegion()

```kotlin
// Good ✓
val actor = Actor.createForRegion("singapore")

// Avoid (deprecated)
val actor = Actor.createSingapore()
```

### 2. Validate Regions Before Use

```kotlin
val region = userInput.lowercase()

if (!RegionConfigFactory.isSupported(region)) {
    val supported = RegionConfigFactory.getSupportedRegions()
    throw IllegalArgumentException(
        "Region '$region' not supported. Available: $supported"
    )
}

val actor = Actor.createForRegion(region)
```

### 3. Check Location Bounds

```kotlin
val config = RegionConfigFactory.getConfig(region)

if (!config.bounds.isValidLocation(lat, lon)) {
    throw IllegalArgumentException(
        "Location ($lat, $lon) is outside ${config.regionName} bounds"
    )
}
```

### 4. Use Try-With-Resources

```kotlin
Actor.createForRegion("singapore").use { actor ->
    val result = actor.route(requestJson)
    // Actor automatically closed
}
```

## Performance Considerations

### Region Size vs. Performance

| Region | Area (km²) | Cache Size | Expected Load Time |
|--------|-----------|------------|-------------------|
| Singapore | ~728 | 1 GB | < 1 second |
| Thailand | ~513,000 | 2 GB | 2-3 seconds |
| Malaysia | ~330,000 | 2 GB | 2-3 seconds |

### Memory Management

```kotlin
// For memory-constrained environments, load regions on-demand
class LazyMultiRegionService {
    private val actors = mutableMapOf<String, Actor>()

    fun getActor(region: String): Actor {
        return actors.getOrPut(region) {
            Actor.createForRegion(region)
        }
    }

    fun unloadRegion(region: String) {
        actors.remove(region)?.close()
    }
}
```

## Troubleshooting

### Region Not Found

```kotlin
try {
    val actor = Actor.createForRegion("invalid")
} catch (e: IllegalArgumentException) {
    println("Error: ${e.message}")
    // Shows: "Unsupported region: 'invalid'. Supported regions: singapore, thailand"
}
```

### Tiles Not Found

```kotlin
try {
    val actor = Actor.createForRegion("thailand", "/wrong/path")
} catch (e: Exception) {
    println("Tiles not found. Please build tiles first:")
    println("  ./scripts/regions/download-region-osm.sh thailand")
    println("  ./scripts/regions/build-tiles.sh thailand")
}
```

### Location Out of Bounds

```kotlin
val config = RegionConfigFactory.getConfig("singapore")

if (!config.bounds.isValidLocation(13.7, 100.5)) {
    println("Location is outside Singapore")
    println("Did you mean to use Thailand?")

    val thConfig = RegionConfigFactory.getConfig("thailand")
    if (thConfig.bounds.isValidLocation(13.7, 100.5)) {
        println("✓ Location is in Thailand")
    }
}
```

## Summary

The multi-region refactoring provides:

- ✅ **Single API** for all regions: `Actor.createForRegion()`
- ✅ **Easy extension**: Add new regions in ~30 minutes
- ✅ **Type safety**: Interface ensures consistency
- ✅ **Backward compatible**: Old code still works
- ✅ **Discoverable**: List regions, check support, get metadata
- ✅ **Flexible**: Custom paths, traffic control, aliases

For more information, see:
- `REFACTORING_SUMMARY.md` - Technical details of the refactoring
- `config/regions/regions.json` - Region configuration file
- `docs/regions/` - Region-specific documentation
