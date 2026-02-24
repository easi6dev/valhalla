# External Tile Directory Configuration

Simple guide to using external tile folders with Valhalla JNI bindings.

---

## 🎯 Quick Start

### Option 1: Environment Variable (Recommended)

**Set environment variable:**
```bash
# Linux/Mac
export VALHALLA_TILES_DIR=/mnt/tiles

# Windows (PowerShell)
$env:VALHALLA_TILES_DIR = "D:\valhalla\tiles"

# Windows (CMD)
set VALHALLA_TILES_DIR=D:\valhalla\tiles
```

**Use in code:**
```kotlin
// Automatically uses VALHALLA_TILES_DIR/singapore
val actor = Actor.createWithExternalTiles("singapore")

// Or without region subdirectory
val actor = Actor.createWithExternalTiles()
```

---

### Option 2: System Property

**Run with system property:**
```bash
java -Dvalhalla.tiles.dir=/mnt/tiles -jar your-app.jar
```

**Use in code:**
```kotlin
// Automatically uses valhalla.tiles.dir system property
val actor = Actor.createWithExternalTiles("singapore")
```

---

### Option 3: Direct Path

**Specify path directly in code:**
```kotlin
// Absolute path
val actor = Actor.createWithTilePath("/mnt/tiles/singapore")

// Or with region parameter
val actor = Actor.createWithTilePath("/mnt/tiles/singapore", region = "singapore")

// Windows path
val actor = Actor.createWithTilePath("D:\\valhalla\\tiles\\singapore")
```

---

### Option 4: Custom Configuration

**Use TileConfig helper:**
```kotlin
import global.tada.valhalla.config.TileConfig

// Auto-detect from environment, system property, or defaults
val tileDir = TileConfig.autoDetect("singapore")

// From environment variable
val tileDir = TileConfig.fromEnvironment()

// From system property
val tileDir = TileConfig.fromSystemProperty()

// Direct path
val tileDir = TileConfig.fromPath("/custom/path")

// Create actor
val actor = Actor.createWithTilePath(tileDir)
```

---

## 📁 Tile Directory Structure

Your tile directory should have this structure:

```
/mnt/tiles/
├── singapore/
│   ├── 2/
│   │   ├── 000/
│   │   │   ├── 000.gph
│   │   │   ├── 001.gph
│   │   │   └── ...
│   │   ├── 001/
│   │   └── ...
│   └── ... (other zoom levels if any)
└── thailand/
    └── 2/
        └── ...
```

---

## 🔍 Detection Priority

When using `Actor.createWithExternalTiles()`, the system checks in this order:

1. **System Property:** `-Dvalhalla.tiles.dir=/path`
2. **Environment Variable:** `VALHALLA_TILES_DIR` or `TILES_DIR`
3. **Default Locations:**
   - `data/valhalla_tiles`
   - `/var/lib/valhalla/tiles`
   - `/mnt/valhalla/tiles`
   - `C:/valhalla/tiles` (Windows)

---

## 💡 Usage Examples

### Example 1: Simple Singapore Route

```kotlin
import global.tada.valhalla.Actor

fun main() {
    // Set environment variable before running:
    // export VALHALLA_TILES_DIR=/mnt/tiles

    val actor = Actor.createWithExternalTiles("singapore")

    val result = actor.route("""
    {
      "locations": [
        {"lat": 1.2834, "lon": 103.8607},
        {"lat": 1.3644, "lon": 103.9915}
      ],
      "costing": "auto"
    }
    """)

    println(result)
    actor.close()
}
```

### Example 2: Multiple Regions

```kotlin
fun main() {
    // Singapore actor
    val singaporeActor = Actor.createWithTilePath("/mnt/tiles/singapore", "singapore")

    // Thailand actor
    val thailandActor = Actor.createWithTilePath("/mnt/tiles/thailand", "thailand")

    // Use both actors...

    singaporeActor.close()
    thailandActor.close()
}
```

### Example 3: Docker/Kubernetes

```yaml
# docker-compose.yml
version: '3'
services:
  valhalla-routing:
    image: your-valhalla-app
    environment:
      - VALHALLA_TILES_DIR=/tiles
    volumes:
      - /host/tiles:/tiles:ro
```

```kotlin
// Your application code (no changes needed)
fun main() {
    // Automatically uses /tiles from environment
    val actor = Actor.createWithExternalTiles("singapore")
    // ...
}
```

### Example 4: Validate Tiles

```kotlin
import global.tada.valhalla.config.TileConfig

fun main() {
    val tileDir = "/mnt/tiles/singapore"

    if (TileConfig.validate(tileDir)) {
        println("✅ Tiles found and valid")
        val actor = Actor.createWithTilePath(tileDir)
        // Use actor...
    } else {
        println("❌ Invalid tile directory: $tileDir")
        println("Expected structure: $tileDir/2/000/...")
    }
}
```

### Example 5: Spring Boot Application

```kotlin
@Configuration
class ValhallaConfig {
    @Value("\${valhalla.tiles.dir:/var/lib/valhalla/tiles}")
    private lateinit var tilesDir: String

    @Bean
    fun singaporeActor(): Actor {
        return Actor.createWithTilePath("$tilesDir/singapore", "singapore")
    }

    @Bean
    fun thailandActor(): Actor {
        return Actor.createWithTilePath("$tilesDir/thailand", "thailand")
    }
}
```

```yaml
# application.yml
valhalla:
  tiles:
    dir: /mnt/tiles
```

### Example 6: Command Line Arguments

```kotlin
fun main(args: Array<String>) {
    val tileDir = args.getOrNull(0) ?: TileConfig.autoDetect("singapore")

    println("Using tiles from: $tileDir")

    val actor = Actor.createWithTilePath(tileDir)
    // Use actor...
    actor.close()
}
```

Run:
```bash
java -jar your-app.jar /custom/tiles/singapore
```

---

## 🐳 Docker Examples

### Mount Host Directory

```dockerfile
FROM openjdk:17-slim

COPY valhalla-jni.jar /app/
WORKDIR /app

# Tiles will be mounted at runtime
ENV VALHALLA_TILES_DIR=/tiles

CMD ["java", "-jar", "valhalla-jni.jar"]
```

```bash
# Run with host tiles
docker run -v /host/tiles:/tiles:ro -e VALHALLA_TILES_DIR=/tiles your-image
```

### Copy Tiles into Image (Small datasets)

```dockerfile
FROM openjdk:17-slim

COPY valhalla-jni.jar /app/
COPY tiles/singapore /tiles/singapore

ENV VALHALLA_TILES_DIR=/tiles

WORKDIR /app
CMD ["java", "-jar", "valhalla-jni.jar"]
```

---

## ☸️ Kubernetes Examples

### ConfigMap for Small Tiles

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: valhalla-tiles
binaryData:
  # Small tile files (not recommended for large datasets)
  tile-data: <base64-encoded-tiles>
```

### PersistentVolume (Recommended)

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: valhalla-tiles-pv
spec:
  capacity:
    storage: 10Gi
  accessModes:
    - ReadOnlyMany
  hostPath:
    path: /mnt/valhalla/tiles
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: valhalla-tiles-pvc
spec:
  accessModes:
    - ReadOnlyMany
  resources:
    requests:
      storage: 10Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: valhalla-routing
spec:
  template:
    spec:
      containers:
      - name: valhalla
        image: your-valhalla-app
        env:
        - name: VALHALLA_TILES_DIR
          value: "/tiles"
        volumeMounts:
        - name: tiles
          mountPath: /tiles
          readOnly: true
      volumes:
      - name: tiles
        persistentVolumeClaim:
          claimName: valhalla-tiles-pvc
```

### NFS Mount

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: valhalla-tiles-nfs
spec:
  capacity:
    storage: 100Gi
  accessModes:
    - ReadOnlyMany
  nfs:
    server: nfs-server.example.com
    path: /exports/valhalla/tiles
```

---

## 🔧 Configuration Priority

All configuration methods can be combined. Priority order:

1. **Direct path in code** (highest priority)
   ```kotlin
   Actor.createWithTilePath("/explicit/path")
   ```

2. **System property**
   ```bash
   -Dvalhalla.tiles.dir=/path
   ```

3. **Environment variable**
   ```bash
   export VALHALLA_TILES_DIR=/path
   ```

4. **Auto-detection** (lowest priority)
   - Searches default locations
   - Uses first existing directory

---

## ✅ Best Practices

### 1. Use Read-Only Mounts
```bash
# Docker
docker run -v /tiles:/tiles:ro ...

# Kubernetes
readOnly: true
```

### 2. Validate on Startup
```kotlin
fun main() {
    val tileDir = TileConfig.autoDetect("singapore")

    if (!TileConfig.validate(tileDir)) {
        logger.error("Invalid tile directory: $tileDir")
        exitProcess(1)
    }

    val actor = Actor.createWithTilePath(tileDir)
}
```

### 3. Use Environment Variables for Deployment
```kotlin
// Don't hardcode paths
// ❌ Bad
val actor = Actor.createWithTilePath("/mnt/tiles/singapore")

// ✅ Good
val actor = Actor.createWithExternalTiles("singapore")
```

### 4. Log Tile Location
```kotlin
val tileDir = TileConfig.autoDetect("singapore")
logger.info("Using Valhalla tiles from: $tileDir")
val actor = Actor.createWithTilePath(tileDir)
```

---

## 🐛 Troubleshooting

### Problem: "Tiles not found"
```kotlin
// Check detection
val tileDir = TileConfig.autoDetect("singapore")
println("Detected: $tileDir")
println("Exists: ${File(tileDir).exists()}")
println("Valid: ${TileConfig.validate(tileDir)}")
```

### Problem: Wrong tiles loaded
```kotlin
// Print actual tile directory being used
val config = SingaporeConfig.buildConfig("/your/path")
println(config)  // Check "tile_dir" value
```

### Problem: Permission denied
```bash
# Check permissions
ls -la /mnt/tiles/singapore

# Fix permissions
chmod -R 755 /mnt/tiles
```

---

## 📝 Environment Variables Reference

| Variable | Description | Example |
|----------|-------------|---------|
| `VALHALLA_TILES_DIR` | Main tile directory | `/mnt/tiles` |
| `VALHALLA_TILE_DIR` | Alternative name | `/mnt/tiles` |
| `TILES_DIR` | Short form | `/mnt/tiles` |

---

## 🎓 Advanced Configuration

### Custom Config with External Tiles

```kotlin
import global.tada.valhalla.config.createConfigWithTileDir

val customConfig = createConfigWithTileDir(
    tileDir = "/mnt/tiles/singapore",
    region = "singapore"
)

val actor = Actor(customConfig)
```

### Multiple Tile Directories

```kotlin
// Create actors for different regions
val regions = mapOf(
    "singapore" to "/mnt/tiles/singapore",
    "thailand" to "/mnt/tiles/thailand",
    "malaysia" to "/mnt/tiles/malaysia"
)

val actors = regions.mapValues { (region, path) ->
    Actor.createWithTilePath(path, region)
}

// Use
val singaporeActor = actors["singapore"]!!
val result = singaporeActor.route(request)

// Cleanup
actors.values.forEach { it.close() }
```

---

## 🚀 Production Deployment

### Option 1: NFS Mount
- Centralized tile storage
- Easy updates
- Shared across multiple instances

### Option 2: Local SSD
- Fastest performance
- Copy tiles during deployment
- Higher storage cost per instance

### Option 3: Network Storage (EFS, Azure Files)
- Managed service
- Automatic scaling
- Regional replication

### Recommended: Local SSD with Copy

```dockerfile
# Multi-stage build
FROM builder AS tile-builder
COPY scripts/download-tiles.sh /
RUN /download-tiles.sh singapore

FROM openjdk:17-slim
COPY --from=tile-builder /tiles /tiles
COPY valhalla-jni.jar /app/

ENV VALHALLA_TILES_DIR=/tiles
CMD ["java", "-jar", "/app/valhalla-jni.jar"]
```

---

**Summary:** Use environment variables for flexibility, validate tiles on startup, and use read-only mounts in production!
