# Valhalla JNI Examples

Complete working examples demonstrating Valhalla routing with external tile configuration.

---

## 📁 Examples Overview

| Example | Description | Complexity |
|---------|-------------|------------|
| [simple-routing](./simple-routing/) | Basic routing with auto-detected tiles | ⭐ Beginner |
| [multiple-regions](./multiple-regions/) | Managing multiple regional actors | ⭐⭐ Intermediate |

---

## 🚀 Quick Start

### Prerequisites

1. **Build and install Valhalla JNI:**
   ```bash
   cd ../src/bindings/java
   ./gradlew clean build publishToMavenLocal -x buildNative -x test
   ```

2. **Prepare tiles** (for Singapore):
   ```bash
   cd ../..
   bash deploy/scripts/run-tile-pipeline.sh singapore --no-elevation
   ```

3. **Set tile location:**
   ```bash
   export VALHALLA_TILE_DIR=data/valhalla_tiles/singapore/latest
   ```

---

## Example 1: Simple Routing ⭐

**What it does:** Basic route calculation with automatic tile detection

**Run:**
```bash
cd simple-routing
./gradlew run
```

**Features:**
- Auto-detects tile location
- Validates tiles before use
- Calculates 3 different routes
- Demonstrates car and motorcycle routing

**Output:**
```
🔍 Detected tile directory: /path/to/tiles/singapore
✅ Tiles validated successfully
🚀 Creating Valhalla Actor...
✅ Actor created successfully

📍 Route 1: Marina Bay → Changi Airport
✅ Route calculated successfully
```

[Full README →](./simple-routing/README.md)

---

## Example 2: Multiple Regions ⭐⭐

**What it does:** Manages routing actors for multiple regions simultaneously

**Run:**
```bash
cd multiple-regions
./gradlew run
```

**Features:**
- Loads multiple regions (Singapore, Thailand)
- Separate actors for each region
- Matrix calculations
- Demonstrates proper resource cleanup

**Output:**
```
🇸🇬 Singapore Routes:
  ✅ Marina Bay → Changi
  ✅ CBD → Sentosa

🇹🇭 Thailand Routes:
  ✅ Bangkok Center

📊 Matrix Calculation
✅ Matrix calculated: 1 source → 3 targets
```

[Full README →](./multiple-regions/README.md)

---

## 🔧 Configuration Methods

All examples support multiple configuration methods:

### Method 1: Environment Variable
```bash
export VALHALLA_TILE_DIR=/mnt/tiles
./gradlew run
```

### Method 2: System Property
```bash
./gradlew run -Dvalhalla.tiles.dir=/mnt/tiles
```

### Method 3: In Code
```kotlin
val actor = Actor.createWithTilePath("/custom/path")
```

### Method 4: Auto-Detection
```kotlin
// Automatically detects from env, system property, or defaults
val actor = Actor.createWithExternalTiles("singapore")
```

---

## 📊 Tile Directory Structure

Required structure for all examples:

```
data/valhalla_tiles/
└── singapore/
    ├── latest -> v20260315-071546/   # symlink to current version
    └── v20260315-071546/             # versioned tile dir (created by pipeline)
        ├── 0/                        # hierarchy level 0
        ├── 1/                        # hierarchy level 1
        └── 2/                        # hierarchy level 2
            ├── 000/
            │   ├── 000.gph
            │   └── ...
            └── ...
```

Point `VALHALLA_TILE_DIR` at the versioned dir or the `latest` symlink:
```bash
export VALHALLA_TILE_DIR=data/valhalla_tiles/singapore/latest
```

---

## 🧪 Testing Examples

### Test Simple Routing
```bash
cd simple-routing
export VALHALLA_TILE_DIR=../../data/valhalla_tiles/singapore/latest
./gradlew run
```

### Test Multiple Regions
```bash
cd multiple-regions
export VALHALLA_TILE_DIR=../../data/valhalla_tiles
./gradlew run
```

---

## 🐛 Troubleshooting

### "Tiles not found"
```bash
# Check tile directory
echo $VALHALLA_TILE_DIR
ls -la $VALHALLA_TILE_DIR/singapore/2

# Validate tiles
cd simple-routing
./gradlew run  # Will show validation error
```

### "UnsatisfiedLinkError"
```bash
# Rebuild and reinstall Valhalla JNI
cd ../src/bindings/java
./gradlew clean build publishToMavenLocal -x buildNative -x test
```

### "Actor creation failed"
```bash
# Check tile structure
# Must have: tiles/singapore/2/000/000.gph
find $VALHALLA_TILE_DIR -name "*.gph" | head -5
```

---

## 📚 API Usage Patterns

### Basic Usage
```kotlin
val actor = Actor.createWithExternalTiles("singapore")
val result = actor.route(request)
actor.close()
```

### With AutoCloseable
```kotlin
Actor.createWithExternalTiles("singapore").use { actor ->
    val result = actor.route(request)
    // Auto-closed
}
```

### Multiple Requests
```kotlin
val actor = Actor.createWithTilePath("/tiles/singapore")

val routes = listOf(request1, request2, request3)
val results = routes.map { actor.route(it) }

actor.close()
```

### Async with Coroutines
```kotlin
import kotlinx.coroutines.*

suspend fun routeAsync() {
    val actor = Actor.createWithExternalTiles("singapore")

    val results = listOf(request1, request2, request3).map { request ->
        async { actor.routeSuspend(request) }
    }.awaitAll()

    actor.close()
}
```

---

## 🎯 Use Cases

| Use Case | Example | Configuration |
|----------|---------|---------------|
| Local Development | simple-routing | Default paths |
| Multi-Region Service | multiple-regions | Env variable |
| Container Deployment | Use `docker/Dockerfile.prod` | Volume mount `-v /host/tiles:/tiles` |
| Lambda/Serverless | simple-routing | EFS mount |

---

## 📝 Next Steps

1. **Try Simple Example:**
   ```bash
   cd simple-routing
   export VALHALLA_TILE_DIR=../../data/valhalla_tiles/singapore/latest
   ./gradlew run
   ```

2. **Modify for Your Region:**
   - Update coordinates in examples
   - Change region name in `regions` list
   - Run pipeline: `bash deploy/scripts/run-tile-pipeline.sh <region>`

3. **Production Deployment:**
   - Build image: `docker build -f docker/Dockerfile.prod -t valhalla:local .`
   - Mount tiles: `docker run -v /host/tiles:/tiles -e VALHALLA_TILE_DIR=/tiles valhalla:local`

---

## 🔗 Documentation

- **Tile Configuration Guide:** [EXTERNAL_TILES_GUIDE.md](../EXTERNAL_TILES_GUIDE.md)
- **API Reference:** [Valhalla JNI README](../src/bindings/java/README.md)
- **Singapore Setup:** [SINGAPORE_QUICKSTART.md](../src/bindings/java/docs/singapore/SINGAPORE_QUICKSTART.md)

---

## ⚡ Performance Tips

1. **Reuse Actors:** Creating an Actor is expensive (loads tiles)
   ```kotlin
   // ✅ Good: Reuse for multiple requests
   val actor = Actor.createWithExternalTiles("singapore")
   requests.forEach { actor.route(it) }
   actor.close()

   // ❌ Bad: Create for each request
   requests.forEach {
       Actor.createWithExternalTiles("singapore").use { it.route(request) }
   }
   ```

2. **Use Async APIs:** For high throughput
   ```kotlin
   val results = requests.map { async { actor.routeSuspend(it) } }.awaitAll()
   ```

3. **Optimize Tile Storage:** Use local SSD for best performance

4. **Configure JVM:** Set appropriate heap size
   ```bash
   java -Xmx2g -Xms512m -jar app.jar
   ```

---

**Ready to start?** Choose an example based on your needs and follow its README! 🚀
