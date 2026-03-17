# Simple Routing Example

Basic example demonstrating Valhalla routing with external tile configuration.

## Prerequisites

1. **Valhalla JNI library installed:**
   ```bash
   cd ../../src/bindings/java
   ./gradlew publishToMavenLocal
   ```

2. **Singapore tiles built:**
   ```bash
   cd ../..
   ./scripts/regions/download-region-osm.sh singapore
   ./scripts/regions/build-tiles.sh singapore
   ```

## Run

### Option 1: With Environment Variable (Recommended)

```bash
# Set tile location
export VALHALLA_TILES_DIR=/path/to/tiles

# Run
./gradlew run
```

### Option 2: With System Property

```bash
./gradlew run -Dvalhalla.tiles.dir=/path/to/tiles
```

### Option 3: Using Default Location

If tiles are in `data/valhalla_tiles/singapore`, just run:

```bash
./gradlew run
```

## What It Does

The example:
1. Auto-detects tile location from environment/system property
2. Validates tiles exist
3. Creates Valhalla Actor
4. Calculates 3 different routes:
   - Marina Bay → Changi Airport (car)
   - Raffles Place → Marina Bay Sands (car)
   - Orchard Road → Bugis (motorcycle)
5. Displays results and cleans up

## Output

```
═══════════════════════════════════════════════════════════
  Valhalla Simple Routing Example
═══════════════════════════════════════════════════════════

🔍 Detected tile directory: /path/to/tiles/singapore
✅ Tiles validated successfully

🚀 Creating Valhalla Actor...
✅ Actor created successfully

📍 Route 1: Marina Bay → Changi Airport
✅ Route calculated successfully
Response length: 12543 characters

📍 Route 2: Raffles Place → Marina Bay Sands
✅ Route calculated successfully
Response length: 3421 characters

📍 Route 3: Orchard Road → Bugis (Motorcycle)
✅ Motorcycle route calculated successfully
Response length: 5234 characters

✅ Actor closed

═══════════════════════════════════════════════════════════
  Example completed successfully!
═══════════════════════════════════════════════════════════
```

## Configuration Options

### Environment Variables
```bash
export VALHALLA_TILES_DIR=/mnt/tiles
export TILES_DIR=/mnt/tiles  # Alternative
```

### System Properties
```bash
./gradlew run -Dvalhalla.tiles.dir=/mnt/tiles
```

### In Code
```kotlin
// Auto-detect
val actor = Actor.createWithExternalTiles("singapore")

// Explicit path
val actor = Actor.createWithTilePath("/custom/path")
```
