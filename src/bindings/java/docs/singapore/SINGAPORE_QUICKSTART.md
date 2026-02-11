# Singapore Setup - Quick Start Guide

Quick guide to get started with Valhalla JNI bindings for Singapore ride-hailing use cases.

## Prerequisites

- **JDK 17+** installed
- **Valhalla C++ tools** installed (for tile building)
- **20 GB** free disk space
- **Linux/macOS/Windows** with WSL

## Quick Setup (3 Steps)

### Step 1: Download Singapore OSM Data (5-10 minutes)

```bash
cd valhalla
./scripts/regions/singapore/download-region-osm.sh singapore
```

**Expected output:**
```
✓ Download complete
File: data/osm/singapore-latest.osm.pbf
Size: ~230 MB
```

### Step 2: Build Tiles (10-20 minutes)

```bash
./scripts/regions/singapore/build-tiles.sh singapore
```

**Expected output:**
```
✓ Tile build completed successfully
Tiles created: 147
Total size: 450 MB
```

### Step 3: Test with JNI (< 1 minute)

```bash
cd src/bindings/java
./gradlew test --tests "SingaporeRideHaulingTest"
```

**Expected output:**
```
✓ 11/11 tests passed
Average latency: 3.2ms
```

---

## Usage Examples

### Kotlin

```kotlin
import global.tada.valhalla.Actor

// Option 1: Quick start (Singapore preset)
val actor = Actor.createSingapore()

// Option 2: Custom tile directory
val actor = Actor.createSingapore("path/to/tiles")

// Calculate route
val request = """
{
  "locations": [
    {"lat": 1.2834, "lon": 103.8607},  // Marina Bay
    {"lat": 1.3644, "lon": 103.9915}   // Changi Airport
  ],
  "costing": "auto"
}
"""

val result = actor.route(request)
println("Route: $result")

actor.close()
```

### Java

```java
import global.tada.valhalla.Actor;

// Create actor for Singapore
Actor actor = Actor.createSingapore();

// Calculate route
String request = """
{
  "locations": [
    {"lat": 1.2834, "lon": 103.8607},
    {"lat": 1.3644, "lon": 103.9915}
  ],
  "costing": "auto"
}
""";

String result = actor.route(request);
System.out.println("Route: " + result);

actor.close();
```

---

## Common Use Cases

### 1. Find Closest Driver

```kotlin
val pickup = """{"lat": 1.3048, "lon": 103.8318}"""  // Orchard Road
val drivers = """
[
  {"lat": 1.2897, "lon": 103.8501},  // Driver 1
  {"lat": 1.3005, "lon": 103.8557},  // Driver 2
  {"lat": 1.2834, "lon": 103.8607}   // Driver 3
]
"""

val request = """
{
  "sources": [$pickup],
  "targets": $drivers,
  "costing": "auto"
}
"""

val result = actor.matrix(request)
// Parse result to find closest driver
```

### 2. Multi-Stop Optimization

```kotlin
val waypoints = """
[
  {"lat": 1.3048, "lon": 103.8318},  // Start: Orchard
  {"lat": 1.3005, "lon": 103.8557},  // Stop 1: Bugis
  {"lat": 1.2897, "lon": 103.8501},  // Stop 2: Raffles
  {"lat": 1.2834, "lon": 103.8607}   // End: Marina Bay
]
"""

val request = """
{
  "locations": $waypoints,
  "costing": "auto"
}
"""

val result = actor.optimizedRoute(request)
// Get optimized stop order
```

### 3. Motorcycle Routing

```kotlin
val request = """
{
  "locations": [
    {"lat": 1.2834, "lon": 103.8607},
    {"lat": 1.3644, "lon": 103.9915}
  ],
  "costing": "motorcycle"
}
"""

val result = actor.route(request)
```

---

## Performance

| Operation | Latency | Notes |
|-----------|---------|-------|
| Short route (<5km) | 2-3ms | CBD routes |
| Medium route (5-15km) | 3-5ms | Cross-district |
| Long route (>15km) | 5-8ms | Changi Airport |
| Matrix (1×50) | 5-10ms | Driver dispatch |
| Optimize (5 stops) | 8-12ms | Multi-drop |

**Throughput:** 500-1000 requests/second (single instance)

---

## Configuration

### Singapore Features

Automatically included in `Actor.createSingapore()`:

- ✅ **ERP Zones**: Electronic Road Pricing awareness
- ✅ **CBD Restrictions**: Central Business District rules
- ✅ **Speed Limits**: Expressway 90, Urban 50, Residential 40
- ✅ **Turn Restrictions**: No-turn penalties
- ✅ **Optimized for Ride-Hailing**: Matrix limit 5000 pairs

### Custom Configuration

```kotlin
import global.tada.valhalla.config.SingaporeConfig

// Load from file
val config = SingaporeConfig.loadFromFile("config/regions/singapore/valhalla-singapore.json")
val actor = Actor(config)

// Or build programmatically
val config = SingaporeConfig.buildConfig(
    tileDir = "custom/path/tiles",
    enableTraffic = false
)
val actor = Actor(config)
```

---

## Troubleshooting

### Tiles Not Found

```
Error: Singapore tiles not found!
```

**Solution:**
```bash
./scripts/regions/singapore/download-region-osm.sh singapore
./scripts/regions/singapore/build-tiles.sh singapore
```

### Library Load Error

```
Error: UnsatisfiedLinkError: no valhalla_jni
```

**Solution:** Pre-compiled binaries are embedded. Check platform:
- ✅ Windows x64
- ✅ Linux x64
- ✅ macOS ARM64
- ❌ Other platforms: Build from source

### Route Not Found

```
Error: Location is unreachable
```

**Solution:** Check coordinates are in Singapore bounds:
- Latitude: 1.15 to 1.48
- Longitude: 103.6 to 104.0

---

## Next Steps

1. **Add More Regions:** Enable Thailand in `config/regions/singapore/regions.json`
2. **Traffic Integration:** See LTA DataMall integration guide
3. **Production Deploy:** Docker setup in deployment guide
4. **Performance Tuning:** JVM optimization tips

---

## Support

- **Scripts:** `scripts/regions/singapore/*.sh`
- **Config:** `config/regions/singapore/*.json`
- **Tests:** `src/bindings/java/src/test/kotlin/global/tada/valhalla/singapore/`
- **Detailed Setup:** `../temp/SETUP_GUIDE.md` (archived)
- **Manual Build:** `../temp/BUILD_JNI_MANUAL.md` (archived)

---

**Ready to route!** 🚗🏍️
