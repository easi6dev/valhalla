# Valhalla JNI Bindings - Quick Start Guide

Get Valhalla routing engine running in minutes on your system (WSL, Linux, or production).

**Date**: February 23, 2026
**Branch**: `master`
**Status**: Production-ready multi-region support

---

## 📋 Prerequisites

### System Requirements
- **OS**: Linux, WSL2 (Windows), or Docker
- **CPU**: 2+ cores recommended
- **RAM**: 4GB minimum (8GB+ for production)
- **Disk**: 2GB for Singapore tiles (varies by region)

### Required Dependencies
```bash
# Ubuntu/Debian
sudo apt-get update
sudo apt-get install -y \
    cmake build-essential \
    libprotobuf-dev libcurl4-openssl-dev \
    openjdk-17-jdk gradle

# Verify Java
java -version  # Should be 17+
```

---

## 🚀 Quick Start (5 Minutes)

### Step 1: Clone and Build

```bash
# Clone repository
git clone <your-repo-url>
cd valhalla

# Checkout JNI bindings branch
git checkout master

# Build JNI bindings
cd src/bindings/java && ./build-jni-bindings.sh

# Expected output:
# ✅ JNI bindings built: build/src/bindings/java/libvalhalla_jni.so
```

### Step 2: Download Tiles

```bash
# Create tiles directory
mkdir -p data/valhalla_tiles/singapore

# Download OSM data then build tiles
./scripts/regions/download-region-osm.sh singapore
./scripts/regions/build-tiles.sh singapore
```

### Step 3: Run Your First Route

**Option A: Using Kotlin/Java**

```kotlin
import global.tada.valhalla.Actor

fun main() {
    // Initialize actor with Singapore region
    val actor = Actor.createForRegion("singapore")

    try {
        // Build route request as JSON (Actor accepts raw Valhalla JSON)
        val request = """
        {
          "locations": [
            {"lat": 1.290270, "lon": 103.851959},
            {"lat": 1.352083, "lon": 103.819836}
          ],
          "costing": "auto",
          "units": "kilometers"
        }
        """.trimIndent()

        // Get route (returns raw Valhalla JSON response)
        val response = actor.route(request)
        println("Route response: $response")
    } finally {
        actor.close()
    }
}
```

**Option B: Using Gradle**

```bash
# Add to your build.gradle.kts
dependencies {
    implementation(files("libs/valhalla-jni.jar"))
}

# Run
gradle run
```

---

## 🌏 Multi-Region Setup

Valhalla JNI bindings support multiple regions with environment-specific configurations.

### Configure Regions

Regions are configured in `config/regions/regions.json` (or environment-specific variants).

**Directory Structure**:
```
config/regions/
└── regions.json          # Single source of truth for all environments
```

### Using Different Regions

```kotlin
// Singapore (default)
val sgActor = Actor.createWithExternalTiles("singapore")

// Thailand
val thActor = Actor.createWithExternalTiles("thailand")

// Or use region aliases
val sgActor2 = Actor.createWithExternalTiles("sg")
val thActor2 = Actor.createWithExternalTiles("th")
```

### Environment-Specific Configuration

Regions are enabled/disabled via `"enabled": true/false` in `config/regions/regions.json`.
Pipeline-level env overrides (tile paths, Docker image, etc.) are managed in `deploy/config/pipeline.<env>.conf`.

---

## 📂 External Tile Directory Configuration

Multiple ways to specify tile locations:

### Method 1: Environment Variable (Recommended)

```bash
# Linux/Mac
export VALHALLA_TILE_DIR=/mnt/tiles

# Windows (PowerShell)
$env:VALHALLA_TILE_DIR = "D:\valhalla\tiles"

# Use in code
val actor = Actor.createWithExternalTiles("singapore")
# Automatically uses: /mnt/tiles/singapore
```

### Method 2: System Property

```bash
# Run with system property
java -Dvalhalla.tiles.dir=/mnt/tiles -jar your-app.jar
```

### Method 3: Direct Path

```kotlin
// Absolute path
val actor = Actor.createWithTilePath("/mnt/tiles/singapore")

// Windows path
val actor = Actor.createWithTilePath("D:\\valhalla\\tiles\\singapore")
```

### Method 4: Configuration Helper

```kotlin
import global.tada.valhalla.config.TileConfig

// Auto-detect from environment/system property
val tileDir = TileConfig.autoDetect("singapore")
val actor = Actor.createWithTilePath(tileDir)

// From environment variable
val tileDir = TileConfig.fromEnvironment("singapore")

// From system property
val tileDir = TileConfig.fromSystemProperty("singapore")
```

---

## 🔍 Validate Configuration

Before running routes, validate your configuration:

```kotlin
import global.tada.valhalla.config.RegionConfigValidator

// Validate configuration file
val result = RegionConfigValidator.validate(
    regionsFile = "config/regions/regions.json",
    validateTiles = true  // Check if tile directories exist
)

if (result.hasErrors()) {
    println("❌ Configuration errors:")
    result.errors.forEach { println("  - $it") }
} else {
    println("✅ Configuration valid")
}

// Validate specific region
val regionResult = RegionConfigValidator.validateRegion("singapore")
println(regionResult)  // Pretty-printed validation result
```

---

## 🧪 Testing Your Setup

### Test 1: Basic Route

```bash
# Run test route script
./scripts/test-route.sh singapore

# Expected output:
# ✅ Route calculated successfully
# Distance: 15.2 km
# Duration: 18 minutes
```

### Test 2: Multiple Regions

```kotlin
fun testMultiRegion() {
    val regions = listOf("singapore", "thailand")

    regions.forEach { region ->
        val actor = Actor.createWithExternalTiles(region)
        try {
            val result = actor.status()
            println("✅ $region: ${result.available}")
        } catch (e: Exception) {
            println("❌ $region: ${e.message}")
        } finally {
            actor.close()
        }
    }
}
```

---

## 📊 Performance Benchmarks

### Singapore Region (v3.6.2)

| Metric | Value | Notes |
|--------|-------|-------|
| Configuration Load | ~50ms | First load (with caching) |
| Configuration Load (cached) | ~5ms | Subsequent loads |
| Actor Initialization | ~200ms | Tile loading |
| Simple Route (10km) | ~15ms | Auto costing |
| Complex Route (50km) | ~80ms | Multiple waypoints |
| Memory Footprint | ~150MB | Singapore tiles loaded |

### JNI Performance

| Metric | Before Phase 1 | After Phase 1 |
|--------|----------------|---------------|
| JAR Size | 14MB | 3MB (78% reduction) |
| LocalRef Leaks | Present | Fixed (RAII) |
| High Load (>10K req/s) | Crashes | Stable |
| Temp Dir Cleanup | Manual | Automatic |

---

## 🐛 Troubleshooting

### Issue: "Region not found"

```
Error: Unsupported region: thailand
```

**Solution**: Check if region is enabled in the regions config:

```bash
# Verify region is enabled
jq '.regions.thailand.enabled' config/regions/regions.json
# Should show: true
```

### Issue: "Tile directory not found"

```
Error: Tile directory does not exist: data/valhalla_tiles/singapore
```

**Solution**: Ensure tiles are downloaded:

```bash
# Check if tiles exist
ls -lh data/valhalla_tiles/singapore/

# Should contain .gph files
# If missing, download or build tiles
```

### Issue: "UnsatisfiedLinkError"

```
java.lang.UnsatisfiedLinkError: libvalhalla_jni.so: cannot open shared object file
```

**Solution**: Ensure system dependencies are installed:

```bash
# Ubuntu/Debian
sudo apt-get install libcurl4 libprotobuf23

# Check missing dependencies
ldd build/src/bindings/java/libvalhalla_jni.so
```

### Issue: "Out of Memory"

```
Exception: Failed to allocate memory for tiles
```

**Solution**: Increase JVM heap size:

```bash
# Set Java options
export JAVA_OPTS="-Xmx4g -Xms2g"

# Or pass directly
java -Xmx4g -jar your-app.jar
```

---

## 📚 Next Steps

- **Development Setup**: See [DEVELOPMENT.md](DEVELOPMENT.md) for build details, testing strategies, and contribution guidelines
- **Production Deployment**: See [PRODUCTION.md](PRODUCTION.md) for Docker/Kubernetes deployment, monitoring, and scaling
- **API Reference**: See Kotlin docs for detailed API documentation
- **Advanced Configuration**: See `config/regions/README.md` for region configuration options

---

## 🆘 Getting Help

- **Documentation**: Check [DEVELOPMENT.md](DEVELOPMENT.md) and [PRODUCTION.md](PRODUCTION.md)
- **Issues**: Report issues on GitHub
- **Community**: Join Valhalla community discussions

---

## ✅ Checklist

Before proceeding to development or production:

- [ ] System dependencies installed
- [ ] JNI bindings built successfully
- [ ] Tiles downloaded for at least one region
- [ ] Configuration validated (no errors)
- [ ] Test route successful
- [ ] Documentation reviewed (DEVELOPMENT.md or PRODUCTION.md)

**Ready to proceed?**
- Development: Continue with [DEVELOPMENT.md](DEVELOPMENT.md)
- Production: Continue with [PRODUCTION.md](PRODUCTION.md)
