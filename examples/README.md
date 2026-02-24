# Valhalla JNI Examples

Complete working examples demonstrating Valhalla routing with external tile configuration.

---

## 📁 Examples Overview

| Example | Description | Complexity |
|---------|-------------|------------|
| [simple-routing](./simple-routing/) | Basic routing with auto-detected tiles | ⭐ Beginner |
| [multiple-regions](./multiple-regions/) | Managing multiple regional actors | ⭐⭐ Intermediate |
| [docker-example](./docker-example/) | Dockerized routing service | ⭐⭐⭐ Advanced |

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
   ./scripts/regions/download-region-osm.sh singapore
   ./scripts/regions/build-tiles.sh singapore
   ```

3. **Set tile location:**
   ```bash
   export VALHALLA_TILES_DIR=/path/to/valhalla_tiles
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

## Example 3: Docker Deployment ⭐⭐⭐

**What it does:** Containerized routing service with tile mounting

**Build:**
```bash
cd docker-example
docker build -t valhalla-routing:latest -f Dockerfile ../..
```

**Run:**
```bash
docker run -d \
  --name valhalla-routing \
  -e VALHALLA_TILES_DIR=/tiles \
  -v /host/tiles/singapore:/tiles:ro \
  -p 8080:8080 \
  valhalla-routing:latest
```

**Features:**
- Multi-stage Docker build
- External tile mounting
- Health checks
- Docker Compose configuration
- Kubernetes deployment example

[Full README →](./docker-example/README.md)

---

## 🔧 Configuration Methods

All examples support multiple configuration methods:

### Method 1: Environment Variable
```bash
export VALHALLA_TILES_DIR=/mnt/tiles
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
valhalla_tiles/
├── singapore/
│   └── 2/                  # Zoom level 2 (required)
│       ├── 000/
│       │   ├── 000.gph
│       │   ├── 001.gph
│       │   └── ...
│       ├── 001/
│       └── ...
└── thailand/               # Optional: additional regions
    └── 2/
        └── ...
```

---

## 🧪 Testing Examples

### Test Simple Routing
```bash
cd simple-routing
export VALHALLA_TILES_DIR=../../data/valhalla_tiles
./gradlew run
```

### Test Multiple Regions
```bash
cd multiple-regions
export VALHALLA_TILES_DIR=../../data/valhalla_tiles
./gradlew run
```

### Test Docker
```bash
cd docker-example
docker build -t valhalla-test .
docker run --rm \
  -v $(pwd)/../../data/valhalla_tiles/singapore:/tiles:ro \
  valhalla-test
```

---

## 🐛 Troubleshooting

### "Tiles not found"
```bash
# Check tile directory
echo $VALHALLA_TILES_DIR
ls -la $VALHALLA_TILES_DIR/singapore/2

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
find $VALHALLA_TILES_DIR -name "*.gph" | head -5
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
| Container Deployment | docker-example | Volume mount |
| Kubernetes | docker-example | PVC mount |
| Lambda/Serverless | simple-routing | EFS mount |

---

## 📝 Next Steps

1. **Try Simple Example:**
   ```bash
   cd simple-routing
   export VALHALLA_TILES_DIR=../../data/valhalla_tiles
   gradle run
   ```

2. **Modify for Your Region:**
   - Update coordinates in examples
   - Change region name
   - Test with your tiles

3. **Production Deployment:**
   - Use Docker example as template
   - Add proper HTTP framework (Ktor, Spring Boot)
   - Implement authentication
   - Set up monitoring

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
