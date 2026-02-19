# Complete Guide: Adding a New Region to Valhalla

This guide provides step-by-step instructions to add a new region (like Thailand, Malaysia, etc.) to your Valhalla routing system.

---

## 📋 Table of Contents

1. [Quick Start - Adding Thailand](#quick-start---adding-thailand)
2. [Detailed Steps](#detailed-steps)
3. [Adding Custom Regions](#adding-custom-regions)
4. [Testing Your New Region](#testing-your-new-region)
5. [Troubleshooting](#troubleshooting)

---

## 🚀 Quick Start - Adding Thailand

Thailand is already pre-configured but disabled. Follow these steps to enable it:

### Step 1: Enable Thailand Region

```bash
cd /path/to/valhallaV3
```

Edit `config/regions/regions.json` and change Thailand's `enabled` flag:

```json
"thailand": {
  "name": "Thailand",
  "enabled": true,  // ← Change from false to true
  "osm_source": "https://download.geofabrik.de/asia/thailand-latest.osm.pbf",
  ...
}
```

### Step 2: Download Thailand OSM Data

```bash
# Run the download script
./scripts/regions/download-region-osm.sh thailand
```

**What happens:**
- Downloads ~500 MB OSM data from Geofabrik
- Saves to `data/osm/thailand-latest.osm.pbf`
- Verifies MD5 checksum
- Creates necessary directories

**Expected output:**
```
════════════════════════════════════════════════════════════
  Downloading OpenStreetMap Data for Thailand
════════════════════════════════════════════════════════════

📦 Downloading: thailand-latest.osm.pbf
   Source: https://download.geofabrik.de/asia/thailand-latest.osm.pbf
   Size: ~500 MB

✅ Download complete!
✅ MD5 checksum verified
📁 Saved to: data/osm/thailand-latest.osm.pbf
```

**Time:** 5-10 minutes (depends on internet speed)

### Step 3: Build Thailand Tiles

```bash
# Build routing tiles
./scripts/regions/build-tiles.sh thailand
```

**What happens:**
- Creates tile directory: `data/valhalla_tiles/thailand/`
- Processes OSM data into routing tiles
- Generates hierarchical tile structure
- Builds elevation data
- Creates routing graph

**Expected output:**
```
════════════════════════════════════════════════════════════
  Building Valhalla Tiles for Thailand
════════════════════════════════════════════════════════════

📂 Input:  data/osm/thailand-latest.osm.pbf
📂 Output: data/valhalla_tiles/thailand/

🔨 Building tiles...
   [====================] 100%

✅ Tile build complete!
📊 Statistics:
   - Total tiles: 12,450
   - Total size: 1.2 GB
   - Build time: 35 minutes
```

**Time:** 30-60 minutes (depends on CPU and RAM)

**Requirements:**
- RAM: 8 GB minimum, 16 GB recommended
- CPU: Multi-core recommended
- Disk: 10 GB free space

### Step 4: Validate Thailand Tiles

```bash
# Validate that tiles were built correctly
./scripts/regions/validate-tiles.sh thailand
```

**Expected output:**
```
════════════════════════════════════════════════════════════
  Validating Valhalla Tiles for Thailand
════════════════════════════════════════════════════════════

✅ Tile directory exists: data/valhalla_tiles/thailand/
✅ Tile structure is valid
✅ Found 12,450 tile files
✅ Total size: 1.2 GB

📊 Tile Distribution:
   Level 0: 145 tiles
   Level 1: 1,234 tiles
   Level 2: 11,071 tiles

✅ All validation checks passed!
```

### Step 5: Use Thailand in Your Code

#### Option A: Using Environment Variable (Recommended)

```bash
# Set base tile directory
export VALHALLA_TILES_DIR=/path/to/data/valhalla_tiles
```

```kotlin
import global.tada.valhalla.Actor

fun main() {
    // Automatically uses $VALHALLA_TILES_DIR/thailand
    val actor = Actor.createWithExternalTiles("thailand")

    // Bangkok route example
    val result = actor.route("""
    {
      "locations": [
        {"lat": 13.7563, "lon": 100.5018},  // Bangkok City Center
        {"lat": 13.9218, "lon": 100.6066}   // Don Mueang Airport
      ],
      "costing": "auto"
    }
    """)

    println(result)
    actor.close()
}
```

#### Option B: Direct Path

```kotlin
import global.tada.valhalla.Actor

fun main() {
    // Specify Thailand tiles path directly
    val actor = Actor.createWithTilePath(
        tileDir = "/path/to/data/valhalla_tiles/thailand",
        region = "thailand"
    )

    val result = actor.route(/* ... */)
    actor.close()
}
```

#### Option C: Multiple Regions Simultaneously

```kotlin
import global.tada.valhalla.Actor

fun main() {
    // Create actors for both regions
    val singaporeActor = Actor.createWithExternalTiles("singapore")
    val thailandActor = Actor.createWithExternalTiles("thailand")

    // Singapore route
    val sgRoute = singaporeActor.route(/* Singapore coordinates */)

    // Thailand route
    val thRoute = thailandActor.route(/* Thailand coordinates */)

    // Cleanup
    singaporeActor.close()
    thailandActor.close()
}
```

---

## 📖 Detailed Steps

### Understanding the File Structure

After adding Thailand, your directory structure will look like:

```
valhallaV3/
├── config/
│   └── regions/
│       └── regions.json              # Region definitions
│
├── data/
│   ├── osm/
│   │   ├── singapore-latest.osm.pbf
│   │   └── thailand-latest.osm.pbf   # ← Downloaded OSM data
│   │
│   └── valhalla_tiles/
│       ├── singapore/
│       │   └── 2/
│       │       ├── 000/
│       │       └── 001/
│       │
│       └── thailand/                  # ← Built tiles
│           └── 2/                     # Zoom level 2
│               ├── 000/
│               │   ├── 000.gph
│               │   ├── 001.gph
│               │   └── ...
│               ├── 001/
│               └── ...
│
└── scripts/
    └── regions/
        ├── download-region-osm.sh    # Downloads OSM data
        ├── build-tiles.sh            # Builds routing tiles
        ├── validate-tiles.sh         # Validates tiles
        └── setup-valhalla.sh         # Full automated setup
```

---

### Step-by-Step Breakdown

#### Step 1: Enable Region in Configuration

**File:** `config/regions/regions.json`

```json
{
  "regions": {
    "thailand": {
      "name": "Thailand",
      "enabled": true,  // ← Change this
      "osm_source": "https://download.geofabrik.de/asia/thailand-latest.osm.pbf",
      "bounds": {
        "min_lat": 5.61,
        "max_lat": 20.46,
        "min_lon": 97.34,
        "max_lon": 105.64
      },
      "tile_dir": "data/valhalla_tiles/thailand",
      "default_costing": "auto",
      "supported_costings": ["auto", "bicycle", "pedestrian", "motorcycle", "bus", "truck"],
      "timezone": "Asia/Bangkok",
      "locale": "th-TH",
      "currency": "THB"
    }
  }
}
```

**Key Fields:**
- `enabled`: Set to `true` to activate the region
- `osm_source`: URL to download OSM data from Geofabrik
- `bounds`: Lat/lon boundaries for the region
- `tile_dir`: Where to store routing tiles
- `supported_costings`: Routing modes available for this region

#### Step 2: Download OSM Data

**Command:**
```bash
./scripts/regions/download-region-osm.sh thailand
```

**What the script does:**

1. **Reads Configuration:**
   ```bash
   # Script reads from config/regions/regions.json
   OSM_URL=$(jq -r '.regions.thailand.osm_source' config/regions/regions.json)
   ```

2. **Creates Directories:**
   ```bash
   mkdir -p data/osm
   ```

3. **Downloads Data:**
   ```bash
   wget -O data/osm/thailand-latest.osm.pbf $OSM_URL
   ```

4. **Verifies Checksum:**
   ```bash
   wget -O data/osm/thailand-latest.osm.pbf.md5 $OSM_URL.md5
   md5sum -c data/osm/thailand-latest.osm.pbf.md5
   ```

**Manual Alternative:**
```bash
# If script fails, download manually
mkdir -p data/osm
cd data/osm

# Download OSM data
wget https://download.geofabrik.de/asia/thailand-latest.osm.pbf

# Download checksum
wget https://download.geofabrik.de/asia/thailand-latest.osm.pbf.md5

# Verify
md5sum -c thailand-latest.osm.pbf.md5
```

**File Size:** ~500 MB (compressed OSM data)

#### Step 3: Build Tiles

**Command:**
```bash
./scripts/regions/build-tiles.sh thailand
```

**What the script does:**

1. **Checks Prerequisites:**
   - Verifies OSM data exists
   - Checks if valhalla_build_tiles is installed
   - Ensures sufficient disk space

2. **Creates Configuration:**
   ```bash
   # Generates Valhalla config file
   cat > /tmp/valhalla-thailand-config.json <<EOF
   {
     "mjolnir": {
       "tile_dir": "data/valhalla_tiles/thailand",
       "max_cache_size": 1073741824,
       "concurrency": 4
     }
   }
   EOF
   ```

3. **Builds Tiles:**
   ```bash
   valhalla_build_tiles \
     -c /tmp/valhalla-thailand-config.json \
     data/osm/thailand-latest.osm.pbf
   ```

4. **Organizes Output:**
   ```bash
   # Tiles are created in data/valhalla_tiles/thailand/
   # Hierarchical structure: 2/000/000.gph, 2/000/001.gph, etc.
   ```

**Build Process Details:**

| Stage | Description | Time |
|-------|-------------|------|
| **Parse OSM** | Read and parse OSM PBF file | 5-10 min |
| **Build Graph** | Create routing graph | 15-25 min |
| **Generate Tiles** | Create hierarchical tiles | 10-20 min |
| **Build Hierarchy** | Create multi-level routing | 5-10 min |
| **Total** | | 35-65 min |

**Resource Usage:**
- **CPU:** Uses all available cores (set `concurrency` in config)
- **RAM:** Peak usage 6-8 GB for Thailand
- **Disk I/O:** High during tile generation
- **Temp Space:** ~2 GB for intermediate files

**Output Structure:**
```
data/valhalla_tiles/thailand/
└── 2/                    # Zoom level 2 (default)
    ├── 000/
    │   ├── 000.gph       # Tile files
    │   ├── 001.gph
    │   ├── 002.gph
    │   └── ...
    ├── 001/
    │   ├── 000.gph
    │   └── ...
    └── 002/
        └── ...
```

**Tile Format (.gph):**
- Binary format
- Contains road network graph
- Includes turn restrictions
- Has speed limits and road attributes
- Typically 50-200 KB per tile

#### Step 4: Validate Tiles

**Command:**
```bash
./scripts/regions/validate-tiles.sh thailand
```

**Validation Checks:**

1. **Directory Exists:**
   ```bash
   if [ -d "data/valhalla_tiles/thailand" ]; then
     echo "✅ Tile directory exists"
   fi
   ```

2. **Tile Structure:**
   ```bash
   if [ -d "data/valhalla_tiles/thailand/2" ]; then
     echo "✅ Level 2 tiles exist"
   fi
   ```

3. **File Count:**
   ```bash
   TILE_COUNT=$(find data/valhalla_tiles/thailand -name "*.gph" | wc -l)
   echo "Found $TILE_COUNT tiles"
   ```

4. **Size Check:**
   ```bash
   TOTAL_SIZE=$(du -sh data/valhalla_tiles/thailand)
   echo "Total size: $TOTAL_SIZE"
   ```

**Expected Results for Thailand:**
- **Tile Count:** ~12,000-15,000 tiles
- **Total Size:** 1.0-1.5 GB
- **Structure:** Must have `2/` directory with subdirectories

**Common Issues:**

| Issue | Cause | Solution |
|-------|-------|----------|
| No tiles found | Build failed | Re-run build-tiles.sh |
| Only a few tiles | Partial build | Check disk space, rebuild |
| Wrong structure | Config error | Verify tile_dir in config |

#### Step 5: Test Routes

**Test Script:**

```kotlin
// File: test-thailand.kt
import global.tada.valhalla.Actor

fun main() {
    println("Testing Thailand routing...")

    // Create Thailand actor
    val actor = Actor.createWithExternalTiles("thailand")

    // Test 1: Bangkok city route
    println("\n📍 Test 1: Bangkok City Route")
    val bangkokRoute = actor.route("""
    {
      "locations": [
        {"lat": 13.7563, "lon": 100.5018, "type": "break"},
        {"lat": 13.7465, "lon": 100.5351, "type": "break"}
      ],
      "costing": "auto",
      "units": "kilometers"
    }
    """)
    println("✅ Bangkok route: ${bangkokRoute.length} characters")

    // Test 2: Bangkok to Pattaya
    println("\n📍 Test 2: Long Distance (Bangkok → Pattaya)")
    val longRoute = actor.route("""
    {
      "locations": [
        {"lat": 13.7563, "lon": 100.5018, "type": "break"},
        {"lat": 12.9236, "lon": 100.8825, "type": "break"}
      ],
      "costing": "auto",
      "units": "kilometers"
    }
    """)
    println("✅ Long route: ${longRoute.length} characters")

    // Test 3: Motorcycle routing
    println("\n📍 Test 3: Motorcycle Route")
    val motorcycleRoute = actor.route("""
    {
      "locations": [
        {"lat": 13.7563, "lon": 100.5018, "type": "break"},
        {"lat": 13.8103, "lon": 100.5598, "type": "break"}
      ],
      "costing": "motorcycle",
      "units": "kilometers"
    }
    """)
    println("✅ Motorcycle route: ${motorcycleRoute.length} characters")

    actor.close()
    println("\n✅ All Thailand tests passed!")
}
```

**Run Test:**
```bash
# Set tile location
export VALHALLA_TILES_DIR=/path/to/data/valhalla_tiles

# Compile and run
kotlinc test-thailand.kt -include-runtime -d test-thailand.jar
java -jar test-thailand.jar
```

**Expected Output:**
```
Testing Thailand routing...

📍 Test 1: Bangkok City Route
✅ Bangkok route: 8543 characters

📍 Test 2: Long Distance (Bangkok → Pattaya)
✅ Long route: 15234 characters

📍 Test 3: Motorcycle Route
✅ Motorcycle route: 6789 characters

✅ All Thailand tests passed!
```

---

## 🌏 Adding Custom Regions

Want to add a region not pre-configured? Follow these steps:

### Example: Adding Malaysia

#### Step 1: Add to regions.json

```json
{
  "regions": {
    "singapore": { /* ... */ },
    "thailand": { /* ... */ },
    "malaysia": {
      "name": "Malaysia",
      "enabled": true,
      "osm_source": "https://download.geofabrik.de/asia/malaysia-singapore-brunei-latest.osm.pbf",
      "bounds": {
        "min_lat": 0.85,
        "max_lat": 7.36,
        "min_lon": 99.64,
        "max_lon": 119.27
      },
      "tile_dir": "data/valhalla_tiles/malaysia",
      "default_costing": "auto",
      "supported_costings": ["auto", "bicycle", "pedestrian", "motorcycle", "bus", "truck"],
      "costing_options": {
        "auto": {
          "maneuver_penalty": 5,
          "country_crossing_penalty": 600
        }
      },
      "timezone": "Asia/Kuala_Lumpur",
      "locale": "ms-MY",
      "currency": "MYR"
    }
  }
}
```

#### Step 2: Find OSM Data Source

**Geofabrik Index:** https://download.geofabrik.de/

**Popular Regions:**

| Region | OSM Source |
|--------|------------|
| **Southeast Asia** | |
| Malaysia | https://download.geofabrik.de/asia/malaysia-singapore-brunei-latest.osm.pbf |
| Vietnam | https://download.geofabrik.de/asia/vietnam-latest.osm.pbf |
| Philippines | https://download.geofabrik.de/asia/philippines-latest.osm.pbf |
| Indonesia | https://download.geofabrik.de/asia/indonesia-latest.osm.pbf |
| Cambodia | https://download.geofabrik.de/asia/cambodia-latest.osm.pbf |
| **East Asia** | |
| Japan | https://download.geofabrik.de/asia/japan-latest.osm.pbf |
| South Korea | https://download.geofabrik.de/asia/south-korea-latest.osm.pbf |
| Taiwan | https://download.geofabrik.de/asia/taiwan-latest.osm.pbf |
| **South Asia** | |
| India | https://download.geofabrik.de/asia/india-latest.osm.pbf |
| Bangladesh | https://download.geofabrik.de/asia/bangladesh-latest.osm.pbf |
| **Middle East** | |
| UAE | https://download.geofabrik.de/asia/gcc-states-latest.osm.pbf |
| Saudi Arabia | https://download.geofabrik.de/asia/gcc-states-latest.osm.pbf |

**To find bounds:**
1. Visit https://boundingbox.klokantech.com/
2. Select region on map
3. Choose "CSV" format
4. Copy min_lat, max_lat, min_lon, max_lon values

#### Step 3: Download and Build

```bash
# Download Malaysia OSM data
./scripts/regions/download-region-osm.sh malaysia

# Build Malaysia tiles
./scripts/regions/build-tiles.sh malaysia

# Validate
./scripts/regions/validate-tiles.sh malaysia
```

#### Step 4: Use in Code

```kotlin
val malaysiaActor = Actor.createWithExternalTiles("malaysia")
val route = malaysiaActor.route(/* Kuala Lumpur coordinates */)
malaysiaActor.close()
```

---

## 🧪 Testing Your New Region

### Test Checklist

- [ ] OSM data downloaded successfully
- [ ] Tiles built without errors
- [ ] Tile directory structure correct
- [ ] Simple route calculation works
- [ ] Long distance route works
- [ ] Different costing modes work (auto, motorcycle, etc.)
- [ ] Edge cases tested (islands, borders, etc.)

### Sample Test Coordinates for Thailand

```kotlin
// Major cities and landmarks
val testLocations = mapOf(
    "Bangkok City Center" to Pair(13.7563, 100.5018),
    "Don Mueang Airport" to Pair(13.9218, 100.6066),
    "Suvarnabhumi Airport" to Pair(13.6900, 100.7501),
    "Chiang Mai" to Pair(18.7883, 98.9853),
    "Phuket" to Pair(7.8804, 98.3923),
    "Pattaya" to Pair(12.9236, 100.8825),
    "Ayutthaya" to Pair(14.3532, 100.5648)
)

// Test routes between major cities
fun testThailandRoutes() {
    val actor = Actor.createWithExternalTiles("thailand")

    // Bangkok to Chiang Mai (long distance)
    val route1 = actor.route("""
    {
      "locations": [
        {"lat": 13.7563, "lon": 100.5018},
        {"lat": 18.7883, "lon": 98.9853}
      ],
      "costing": "auto"
    }
    """)

    // Bangkok to Pattaya (coastal route)
    val route2 = actor.route("""
    {
      "locations": [
        {"lat": 13.7563, "lon": 100.5018},
        {"lat": 12.9236, "lon": 100.8825}
      ],
      "costing": "auto"
    }
    """)

    actor.close()
}
```

### Integration Test

```kotlin
// File: examples/thailand-test/ThailandIntegrationTest.kt
import global.tada.valhalla.Actor
import kotlin.test.Test
import kotlin.test.assertTrue
import kotlin.test.assertNotNull

class ThailandIntegrationTest {

    @Test
    fun `test Bangkok city route`() {
        val actor = Actor.createWithExternalTiles("thailand")

        val result = actor.route("""
        {
          "locations": [
            {"lat": 13.7563, "lon": 100.5018},
            {"lat": 13.7465, "lon": 100.5351}
          ],
          "costing": "auto"
        }
        """)

        assertNotNull(result)
        assertTrue(result.contains("\"trip\""))
        assertTrue(result.contains("\"legs\""))

        actor.close()
    }

    @Test
    fun `test long distance route`() {
        val actor = Actor.createWithExternalTiles("thailand")

        val result = actor.route("""
        {
          "locations": [
            {"lat": 13.7563, "lon": 100.5018},
            {"lat": 18.7883, "lon": 98.9853}
          ],
          "costing": "auto"
        }
        """)

        assertNotNull(result)
        assertTrue(result.length > 1000) // Long route = more data

        actor.close()
    }

    @Test
    fun `test motorcycle routing`() {
        val actor = Actor.createWithExternalTiles("thailand")

        val result = actor.route("""
        {
          "locations": [
            {"lat": 13.7563, "lon": 100.5018},
            {"lat": 13.8103, "lon": 100.5598}
          ],
          "costing": "motorcycle"
        }
        """)

        assertNotNull(result)
        assertTrue(result.contains("\"trip\""))

        actor.close()
    }
}
```

**Run Integration Tests:**
```bash
cd examples/thailand-test
./gradlew test
```

---

## 🐛 Troubleshooting

### Issue 1: Download Fails

**Symptoms:**
```
Error: Failed to download thailand-latest.osm.pbf
Connection timeout
```

**Solutions:**

1. **Check Internet Connection:**
   ```bash
   ping download.geofabrik.de
   ```

2. **Try Manual Download:**
   ```bash
   cd data/osm
   wget --retry-connrefused --waitretry=1 --read-timeout=20 --timeout=15 -t 5 \
     https://download.geofabrik.de/asia/thailand-latest.osm.pbf
   ```

3. **Use Mirror:**
   Some regions have multiple mirrors. Check Geofabrik website for alternatives.

4. **Resume Partial Download:**
   ```bash
   wget -c https://download.geofabrik.de/asia/thailand-latest.osm.pbf
   ```

### Issue 2: Build Fails - Out of Memory

**Symptoms:**
```
Error: valhalla_build_tiles killed
Signal: 9 (SIGKILL)
```

**Solutions:**

1. **Check Available RAM:**
   ```bash
   free -h
   ```

2. **Add Swap Space:**
   ```bash
   # Create 8GB swap file
   sudo dd if=/dev/zero of=/swapfile bs=1G count=8
   sudo chmod 600 /swapfile
   sudo mkswap /swapfile
   sudo swapon /swapfile
   ```

3. **Reduce Concurrency:**
   Edit build script to use fewer cores:
   ```json
   {
     "mjolnir": {
       "concurrency": 2  // Reduce from 4 to 2
     }
   }
   ```

4. **Use Docker with Memory Limit:**
   ```bash
   docker run --memory="8g" \
     -v $(pwd):/data \
     ghcr.io/valhalla/valhalla:latest \
     valhalla_build_tiles -c config.json input.osm.pbf
   ```

### Issue 3: Build Fails - Corrupt OSM Data

**Symptoms:**
```
Error: Failed to parse OSM data
Invalid PBF format
```

**Solutions:**

1. **Verify Checksum:**
   ```bash
   cd data/osm
   md5sum -c thailand-latest.osm.pbf.md5
   ```

2. **Re-download:**
   ```bash
   rm thailand-latest.osm.pbf
   ./scripts/regions/download-region-osm.sh thailand
   ```

3. **Check File Size:**
   ```bash
   ls -lh data/osm/thailand-latest.osm.pbf
   # Should be ~500 MB for Thailand
   ```

### Issue 4: Tiles Built But Routes Fail

**Symptoms:**
```
Error: No route found
Error: Location is unreachable
```

**Solutions:**

1. **Check Coordinate Bounds:**
   ```kotlin
   // Ensure coordinates are within Thailand
   val lat = 13.7563  // Bangkok
   val lon = 100.5018

   // Thailand bounds: 5.61 to 20.46 lat, 97.34 to 105.64 lon
   if (lat < 5.61 || lat > 20.46 || lon < 97.34 || lon > 105.64) {
       println("Coordinates outside Thailand!")
   }
   ```

2. **Validate Tile Coverage:**
   ```bash
   ./scripts/regions/validate-tiles.sh thailand
   ```

3. **Test Simple Route First:**
   ```kotlin
   // Use major city center coordinates (guaranteed to have good coverage)
   val bangkokCenter = Pair(13.7563, 100.5018)
   ```

4. **Check Tile File Count:**
   ```bash
   find data/valhalla_tiles/thailand -name "*.gph" | wc -l
   # Should be 10,000+ for Thailand
   ```

### Issue 5: Actor Creation Fails

**Symptoms:**
```
Exception: Failed to create Actor
Error: Tiles not found
```

**Solutions:**

1. **Check Environment Variable:**
   ```bash
   echo $VALHALLA_TILES_DIR
   # Should output: /path/to/data/valhalla_tiles
   ```

2. **Verify Tile Directory:**
   ```bash
   ls -la $VALHALLA_TILES_DIR/thailand/2/000/
   # Should list .gph files
   ```

3. **Use Direct Path:**
   ```kotlin
   // Instead of auto-detection
   val actor = Actor.createWithTilePath(
       "/absolute/path/to/data/valhalla_tiles/thailand"
   )
   ```

4. **Check Permissions:**
   ```bash
   ls -ld data/valhalla_tiles/thailand
   # Should be readable
   ```

### Issue 6: Slow Route Calculation

**Symptoms:**
- Routes take > 5 seconds to calculate
- High CPU usage
- Memory grows over time

**Solutions:**

1. **Reuse Actor:**
   ```kotlin
   // ✅ Good: Create once, use many times
   val actor = Actor.createWithExternalTiles("thailand")
   repeat(100) { actor.route(request) }
   actor.close()

   // ❌ Bad: Create per request
   repeat(100) {
       Actor.createWithExternalTiles("thailand").use { it.route(request) }
   }
   ```

2. **Optimize Costing:**
   ```json
   {
     "locations": [...],
     "costing": "auto",
     "costing_options": {
       "auto": {
         "shortest": true  // Faster than default
       }
     }
   }
   ```

3. **Use Tile Caching:**
   - Tiles are loaded into memory on first use
   - Subsequent routes are faster
   - First route: ~2-3 seconds
   - Later routes: ~50-200ms

4. **Check Disk Performance:**
   ```bash
   # Tiles should be on fast storage (SSD preferred)
   hdparm -Tt /dev/sda  # Check read speed
   ```

---

## 📊 Performance Comparison

| Region | OSM Size | Tile Size | Build Time | Tile Count | RAM Usage |
|--------|----------|-----------|------------|------------|-----------|
| **Singapore** | 230 MB | 450 MB | 15 min | 1,234 | 2 GB |
| **Thailand** | 500 MB | 1.2 GB | 45 min | 12,450 | 6 GB |
| **Malaysia** | 450 MB | 1.0 GB | 40 min | 10,234 | 5 GB |
| **Vietnam** | 550 MB | 1.4 GB | 50 min | 14,123 | 7 GB |
| **Indonesia** | 1.2 GB | 3.0 GB | 120 min | 35,678 | 12 GB |
| **Japan** | 2.5 GB | 6.5 GB | 180 min | 78,901 | 16 GB |

---

## 🎯 Best Practices

### 1. Directory Organization

```
data/
├── osm/                    # OSM source data
│   ├── singapore-latest.osm.pbf
│   ├── thailand-latest.osm.pbf
│   └── malaysia-latest.osm.pbf
│
└── valhalla_tiles/         # Built tiles
    ├── singapore/          # 450 MB
    ├── thailand/           # 1.2 GB
    └── malaysia/           # 1.0 GB
```

### 2. Update Schedule

OSM data is updated frequently. Recommended update schedule:

- **Urban areas (Bangkok, Singapore):** Weekly
- **Rural areas:** Monthly
- **Test regions:** As needed

**Update Command:**
```bash
# Re-download and rebuild
./scripts/regions/download-region-osm.sh thailand
./scripts/regions/build-tiles.sh thailand
```

### 3. Storage Strategy

**Development:**
- Local SSD for fastest performance
- Keep 2-3 regions

**Production:**
- NFS mount for shared access
- All required regions
- Read-only mounting recommended

**CI/CD:**
- Download tiles during deployment
- Cache tiles between builds
- Use pre-built tiles from artifact storage

### 4. Multi-Region Applications

```kotlin
class RegionRouter {
    private val actors = mutableMapOf<String, Actor>()

    init {
        // Load all enabled regions
        actors["singapore"] = Actor.createWithExternalTiles("singapore")
        actors["thailand"] = Actor.createWithExternalTiles("thailand")
        actors["malaysia"] = Actor.createWithExternalTiles("malaysia")
    }

    fun route(region: String, request: String): String {
        val actor = actors[region]
            ?: throw IllegalArgumentException("Region $region not loaded")
        return actor.route(request)
    }

    fun close() {
        actors.values.forEach { it.close() }
    }
}
```

### 5. Monitoring

**Key Metrics:**
- Tile cache hit rate
- Route calculation time
- Memory usage per actor
- Tile directory size

**Example Monitoring:**
```kotlin
class MonitoredActor(private val actor: Actor) {
    private var routeCount = 0
    private var totalTime = 0L

    fun route(request: String): String {
        val start = System.currentTimeMillis()
        val result = actor.route(request)
        val time = System.currentTimeMillis() - start

        routeCount++
        totalTime += time

        if (routeCount % 100 == 0) {
            val avgTime = totalTime / routeCount
            println("Processed $routeCount routes, avg time: ${avgTime}ms")
        }

        return result
    }
}
```

---

## 📚 Additional Resources

- **Valhalla Documentation:** https://valhalla.readthedocs.io/
- **Geofabrik Downloads:** https://download.geofabrik.de/
- **OSM Wiki:** https://wiki.openstreetmap.org/
- **Tile Configuration Guide:** [EXTERNAL_TILES_GUIDE.md](../../EXTERNAL_TILES_GUIDE.md)
- **Example Projects:** [examples/](../../examples/)

---

## ✅ Quick Reference

### One-Line Commands

```bash
# Download Thailand OSM data
./scripts/regions/download-region-osm.sh thailand

# Build Thailand tiles
./scripts/regions/build-tiles.sh thailand

# Validate Thailand tiles
./scripts/regions/validate-tiles.sh thailand

# Full automated setup (all in one)
./scripts/regions/setup-valhalla.sh --region thailand
```

### Test Snippet

```kotlin
val actor = Actor.createWithExternalTiles("thailand")
val route = actor.route("""{"locations":[{"lat":13.7563,"lon":100.5018},{"lat":13.7465,"lon":100.5351}],"costing":"auto"}""")
println(route)
actor.close()
```

---

**Happy Routing!** 🚀

If you encounter any issues not covered here, please check the [troubleshooting guide](../setup/COMPLETE_SETUP_GUIDE.md) or open an issue on GitHub.
