# External Tile Configuration - Quick Reference

**Quick reference guide for using external tile directories with Valhalla JNI bindings.**

> 📚 **For detailed guide with examples:** See [EXTERNAL_TILES_GUIDE.md](./EXTERNAL_TILES_GUIDE.md)

---

## 🎯 Quick Start (3 Steps)

### 1. Set Tile Location
```bash
# Linux/Mac
export VALHALLA_TILES_DIR=/mnt/tiles

# Windows (PowerShell)
$env:VALHALLA_TILES_DIR = "D:\valhalla\tiles"
```

### 2. Use in Code
```kotlin
import global.tada.valhalla.Actor

// Auto-detect from environment variable
val actor = Actor.createWithExternalTiles("singapore")

// Or specify path directly
val actor = Actor.createWithTilePath("/mnt/tiles/singapore")
```

### 3. Route
```kotlin
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
```

---

## 📋 Configuration Methods

| Method | Priority | Example |
|--------|----------|---------|
| **System Property** | 1 (Highest) | `java -Dvalhalla.tiles.dir=/mnt/tiles -jar app.jar` |
| **Environment Variable** | 2 | `export VALHALLA_TILES_DIR=/mnt/tiles` |
| **Direct in Code** | 3 | `Actor.createWithTilePath("/mnt/tiles")` |
| **Auto-Detection** | 4 (Lowest) | Searches default locations |

---

## 🌍 Environment Variables

| Variable | Description |
|----------|-------------|
| `VALHALLA_TILES_DIR` | Primary tile directory (Recommended) |
| `VALHALLA_TILE_DIR` | Alternative name |
| `TILES_DIR` | Short form |

---

## ⚙️ System Properties

| Property | Usage |
|----------|-------|
| `valhalla.tiles.dir` | `java -Dvalhalla.tiles.dir=/path -jar app.jar` |
| `valhalla.tile.dir` | Alternative name |

---

## 📁 Required Tile Structure

```
/mnt/tiles/
├── singapore/
│   └── 2/                  # Required: zoom level 2
│       ├── 000/
│       │   ├── 000.gph
│       │   ├── 001.gph
│       │   └── ...
│       └── 001/
└── thailand/               # Optional: other regions
    └── 2/
        └── ...
```

---

## 💻 API Methods

### Factory Methods

```kotlin
// Auto-detect from environment/system property/defaults
Actor.createWithExternalTiles(region: String? = null): Actor

// Specify path directly
Actor.createWithTilePath(tileDir: String, region: String = "singapore"): Actor

// Original method (still works)
Actor.createSingapore(tileDir: String = "data/valhalla_tiles/singapore"): Actor
```

### Helper Methods

```kotlin
import global.tada.valhalla.config.TileConfig

// Auto-detect tile location
val tileDir = TileConfig.autoDetect("singapore")

// Validate tiles exist
if (TileConfig.validate(tileDir)) {
    val actor = Actor.createWithTilePath(tileDir)
}
```

---

## 🐳 Docker Quick Setup

**Dockerfile:**
```dockerfile
FROM openjdk:17-slim
COPY valhalla-jni.jar /app/
ENV VALHALLA_TILES_DIR=/tiles
CMD ["java", "-jar", "/app/valhalla-jni.jar"]
```

**Run:**
```bash
docker run -v /host/tiles:/tiles:ro -e VALHALLA_TILES_DIR=/tiles your-image
```

**Application code remains unchanged:**
```kotlin
// Automatically uses VALHALLA_TILES_DIR environment variable
val actor = Actor.createWithExternalTiles("singapore")
```

---

## ☸️ Kubernetes Quick Setup

```yaml
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

---

## ✅ Validation

### Check Tile Configuration
```kotlin
import global.tada.valhalla.config.TileConfig

val tileDir = TileConfig.autoDetect("singapore")
println("Using tiles from: $tileDir")

if (TileConfig.validate(tileDir)) {
    println("✅ Tiles are valid")
} else {
    println("❌ Invalid tile directory")
}
```

### Expected Directory Structure
- Must have `2/` subdirectory (zoom level 2)
- Must contain `.gph` files in `2/000/` subdirectories

---

## 🐛 Troubleshooting

### "Tiles not found"
```bash
# Check environment variable
echo $VALHALLA_TILES_DIR

# Check directory structure
ls -la $VALHALLA_TILES_DIR/singapore/2

# Validate in code
if (!TileConfig.validate(path)) {
    println("❌ Invalid: $path")
}
```

### "Wrong tiles loaded"
```kotlin
// Print actual path being used
val tileDir = TileConfig.autoDetect("singapore")
println("Detected tile directory: $tileDir")
```

---

## 📚 Additional Resources

| Document | Purpose |
|----------|---------|
| [EXTERNAL_TILES_GUIDE.md](./EXTERNAL_TILES_GUIDE.md) | Comprehensive configuration guide with detailed examples |
| [examples/README.md](./examples/README.md) | Working code examples |
| [docs/setup/COMPLETE_SETUP_GUIDE.md](./src/bindings/java/docs/setup/COMPLETE_SETUP_GUIDE.md) | Full setup instructions |

---

## ⚡ Performance Tips

1. **Reuse Actors** - Creating actors is expensive (loads tiles into memory)
   ```kotlin
   // ✅ Good: Reuse for multiple requests
   val actor = Actor.createWithExternalTiles("singapore")
   repeat(100) { actor.route(request) }
   actor.close()

   // ❌ Bad: Create per request
   repeat(100) {
       Actor.createWithExternalTiles("singapore").use { it.route(request) }
   }
   ```

2. **Use Local SSD** - Best performance for tile storage

3. **Set Appropriate JVM Heap**
   ```bash
   java -Xmx2g -Xms512m -jar app.jar
   ```

---

**Ready to use!** Simple, zero-dependency tile configuration. 🚀
