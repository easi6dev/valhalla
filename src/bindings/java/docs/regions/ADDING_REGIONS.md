# Adding Regions to Valhalla

Complete guide for adding routing regions to your Valhalla system - from international countries to US states and custom metro areas.

---

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Quick Start](#quick-start)
3. [International Regions](#international-regions)
4. [US Regions](#us-regions)
5. [Custom Regions](#custom-regions)
6. [Validation and Testing](#validation-and-testing)
7. [Production Deployment](#production-deployment)
8. [Troubleshooting](#troubleshooting)
9. [Reference](#reference)

---

## Prerequisites

### System Requirements

- **RAM:** 8 GB minimum, 16 GB recommended
- **CPU:** Multi-core processor (4+ cores recommended)
- **Disk Space:** 10 GB+ free space per region
- **OS:** Linux, macOS, or Windows with WSL

### Software Requirements

- Valhalla build tools installed
- `wget` or `curl` for downloads
- `jq` for JSON processing (optional)
- `osmium-tool` for custom extracts (optional)

### Directory Structure

```
valhalla/
├── config/
│   └── regions/
│       ├── regions.json          # Region definitions
│       ├── regions-dev.json      # Development config
│       ├── regions-prod.json     # Production config
│       └── regions-staging.json  # Staging config
│
├── data/
│   ├── osm/                      # Downloaded OSM files
│   └── valhalla_tiles/           # Built routing tiles
│
└── scripts/
    └── regions/
        ├── download-region-osm.sh
        ├── build-tiles.sh
        ├── validate-tiles.sh
        └── setup-valhalla.sh
```

---

## Quick Start

### Add Pre-configured Region (Thailand Example)

Thailand is pre-configured but disabled. Enable and build:

```bash
cd /path/to/valhalla

# 1. Enable Thailand in config/regions/regions.json
# Change "enabled": false to "enabled": true

# 2. Download OSM data (~500 MB, 5-10 min)
./scripts/regions/download-region-osm.sh thailand

# 3. Build routing tiles (~1.2 GB, 30-60 min)
./scripts/regions/build-tiles.sh thailand

# 4. Validate tiles
./scripts/regions/validate-tiles.sh thailand

# 5. Set environment variable
export VALHALLA_TILES_DIR=$(pwd)/data/valhalla_tiles
```

### Use in Code

```kotlin
import global.tada.valhalla.Actor

fun main() {
    // Create actor for Thailand
    val actor = Actor.createWithExternalTiles("thailand")

    // Route in Bangkok
    val result = actor.route("""
    {
      "locations": [
        {"lat": 13.7563, "lon": 100.5018},
        {"lat": 13.9218, "lon": 100.6066}
      ],
      "costing": "auto"
    }
    """)

    println(result)
    actor.close()
}
```

---

## International Regions

### Adding Thailand

**Region Details:**
- OSM Size: ~500 MB
- Tile Size: ~1.2 GB
- Build Time: 30-60 minutes
- Coverage: Entire country

**Configuration:**

Edit `config/regions/regions.json`:

```json
{
  "regions": {
    "thailand": {
      "name": "Thailand",
      "enabled": true,
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

**Build Steps:**

```bash
# Download OSM data
./scripts/regions/download-region-osm.sh thailand

# Build tiles
./scripts/regions/build-tiles.sh thailand

# Validate
./scripts/regions/validate-tiles.sh thailand
```

**Test Coordinates:**

```kotlin
val testLocations = mapOf(
    "Bangkok City Center" to Pair(13.7563, 100.5018),
    "Don Mueang Airport" to Pair(13.9218, 100.6066),
    "Suvarnabhumi Airport" to Pair(13.6900, 100.7501),
    "Chiang Mai" to Pair(18.7883, 98.9853),
    "Phuket" to Pair(7.8804, 98.3923),
    "Pattaya" to Pair(12.9236, 100.8825)
)
```

### Adding Malaysia

**Configuration:**

```json
{
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
```

**Build:**

```bash
./scripts/regions/download-region-osm.sh malaysia
./scripts/regions/build-tiles.sh malaysia
./scripts/regions/validate-tiles.sh malaysia
```

### Popular International Regions

| Region | OSM Source | Est. Size | Build Time |
|--------|------------|-----------|------------|
| **Southeast Asia** | | | |
| Vietnam | `https://download.geofabrik.de/asia/vietnam-latest.osm.pbf` | 1.4 GB | 50 min |
| Philippines | `https://download.geofabrik.de/asia/philippines-latest.osm.pbf` | 800 MB | 35 min |
| Indonesia | `https://download.geofabrik.de/asia/indonesia-latest.osm.pbf` | 3.0 GB | 120 min |
| Cambodia | `https://download.geofabrik.de/asia/cambodia-latest.osm.pbf` | 400 MB | 25 min |
| **East Asia** | | | |
| Japan | `https://download.geofabrik.de/asia/japan-latest.osm.pbf` | 6.5 GB | 180 min |
| South Korea | `https://download.geofabrik.de/asia/south-korea-latest.osm.pbf` | 1.8 GB | 60 min |
| Taiwan | `https://download.geofabrik.de/asia/taiwan-latest.osm.pbf` | 800 MB | 35 min |
| **South Asia** | | | |
| India | `https://download.geofabrik.de/asia/india-latest.osm.pbf` | 4.5 GB | 150 min |
| Bangladesh | `https://download.geofabrik.de/asia/bangladesh-latest.osm.pbf` | 600 MB | 30 min |
| **Middle East** | | | |
| UAE | `https://download.geofabrik.de/asia/gcc-states-latest.osm.pbf` | 500 MB | 28 min |
| Saudi Arabia | `https://download.geofabrik.de/asia/gcc-states-latest.osm.pbf` | 500 MB | 28 min |

---

## US Regions

### Adding New York State

**Overview:**
- Coverage: Entire New York State (includes NYC metro)
- OSM Size: ~200 MB
- Tile Size: ~520 MB
- Build Time: 20-35 minutes

**Configuration:**

```json
{
  "new-york": {
    "name": "New York",
    "enabled": true,
    "osm_source": "https://download.geofabrik.de/north-america/us/new-york-latest.osm.pbf",
    "bounds": {
      "min_lat": 40.4774,
      "max_lat": 45.0153,
      "min_lon": -79.7624,
      "max_lon": -71.8560
    },
    "tile_dir": "data/valhalla_tiles/new-york",
    "default_costing": "auto",
    "supported_costings": ["auto", "bicycle", "pedestrian", "motorcycle", "bus", "truck", "taxi"],
    "costing_options": {
      "auto": {
        "maneuver_penalty": 5,
        "use_highways": 1.0,
        "use_tolls": 0.5,
        "top_speed": 120
      },
      "taxi": {
        "use_tolls": 0.3
      }
    },
    "timezone": "America/New_York",
    "locale": "en-US",
    "currency": "USD"
  }
}
```

**Build Steps:**

```bash
./scripts/regions/download-region-osm.sh new-york
./scripts/regions/build-tiles.sh new-york
./scripts/regions/validate-tiles.sh new-york
```

**Test in Code:**

```kotlin
val actor = Actor.createWithExternalTiles("new-york")

// Times Square to Central Park
val manhattan = actor.route("""
{
  "locations": [
    {"lat": 40.7580, "lon": -73.9855},
    {"lat": 40.7829, "lon": -73.9654}
  ],
  "costing": "auto",
  "units": "miles"
}
""")

actor.close()
```

### Adding Denver (Colorado)

**Configuration:**

```json
{
  "denver": {
    "name": "Denver",
    "enabled": true,
    "osm_source": "https://download.geofabrik.de/north-america/us/colorado-latest.osm.pbf",
    "bounds": {
      "min_lat": 39.6143,
      "max_lat": 39.9143,
      "min_lon": -105.1100,
      "max_lon": -104.6000
    },
    "tile_dir": "data/valhalla_tiles/denver",
    "default_costing": "auto",
    "supported_costings": ["auto", "bicycle", "pedestrian", "motorcycle", "bus", "truck"],
    "costing_options": {
      "bicycle": {
        "use_hills": 0.4,
        "avoid_bad_surfaces": 0.25
      }
    },
    "timezone": "America/Denver",
    "locale": "en-US",
    "currency": "USD"
  }
}
```

### US States by Size

#### Large States (>500 MB tiles)

| State | OSM Source | Tile Size | Build Time |
|-------|------------|-----------|------------|
| California | `https://download.geofabrik.de/north-america/us/california-latest.osm.pbf` | 850 MB | 60 min |
| Texas | `https://download.geofabrik.de/north-america/us/texas-latest.osm.pbf` | 680 MB | 50 min |
| Florida | `https://download.geofabrik.de/north-america/us/florida-latest.osm.pbf` | 450 MB | 35 min |
| New York | `https://download.geofabrik.de/north-america/us/new-york-latest.osm.pbf` | 520 MB | 40 min |

#### Medium States (100-500 MB tiles)

| State | OSM Source | Tile Size | Build Time |
|-------|------------|-----------|------------|
| Illinois | `https://download.geofabrik.de/north-america/us/illinois-latest.osm.pbf` | 320 MB | 25 min |
| Pennsylvania | `https://download.geofabrik.de/north-america/us/pennsylvania-latest.osm.pbf` | 340 MB | 26 min |
| Washington | `https://download.geofabrik.de/north-america/us/washington-latest.osm.pbf` | 250 MB | 20 min |
| Ohio | `https://download.geofabrik.de/north-america/us/ohio-latest.osm.pbf` | 300 MB | 24 min |
| Michigan | `https://download.geofabrik.de/north-america/us/michigan-latest.osm.pbf` | 280 MB | 22 min |

#### Small States (<100 MB tiles)

| State | OSM Source | Tile Size | Build Time |
|-------|------------|-----------|------------|
| Massachusetts | `https://download.geofabrik.de/north-america/us/massachusetts-latest.osm.pbf` | 150 MB | 13 min |
| Connecticut | `https://download.geofabrik.de/north-america/us/connecticut-latest.osm.pbf` | 90 MB | 10 min |
| Colorado | `https://download.geofabrik.de/north-america/us/colorado-latest.osm.pbf` | 180 MB | 15 min |
| Rhode Island | `https://download.geofabrik.de/north-america/us/rhode-island-latest.osm.pbf` | 50 MB | 8 min |

### Major US Metropolitan Areas

| Metro Area | Use State | Major Cities Included |
|------------|-----------|----------------------|
| New York Metro | New York + New Jersey | NYC, Newark, Jersey City |
| Los Angeles Metro | California | LA, Long Beach, Anaheim |
| Chicago Metro | Illinois | Chicago, Aurora, Joliet |
| Dallas-Fort Worth | Texas | Dallas, Fort Worth, Arlington |
| Houston Metro | Texas | Houston, Sugar Land, The Woodlands |
| Washington DC Metro | DC + Virginia + Maryland | DC, Arlington, Alexandria |
| Miami Metro | Florida | Miami, Fort Lauderdale, West Palm Beach |
| Philadelphia Metro | Pennsylvania | Philadelphia, Camden, Wilmington |
| Atlanta Metro | Georgia | Atlanta, Sandy Springs, Roswell |
| Boston Metro | Massachusetts | Boston, Cambridge, Newton |
| San Francisco Bay | California | SF, Oakland, San Jose |
| Phoenix Metro | Arizona | Phoenix, Mesa, Scottsdale |
| Seattle Metro | Washington | Seattle, Tacoma, Bellevue |
| Denver Metro | Colorado | Denver, Aurora, Lakewood |

### City vs State: Which to Choose?

| Scenario | Recommendation | Reason |
|----------|----------------|--------|
| Single city focus | Extract metro area | Smaller files, faster builds |
| Multi-city state | Use full state | One download covers all cities |
| Cross-state routes | Regional extract | Covers metro + suburbs |
| Nationwide service | All states or US-wide | Complete coverage |
| Development/Testing | Small state or city | Fast iteration |

**Examples:**

- **NYC taxi service** → NYC metro extract (120 MB vs 520 MB full state)
- **California ride-hailing** → Full California state (covers LA, SF, SD)
- **Boston bike sharing** → Massachusetts state (150 MB, includes suburbs)

### Test Coordinates for US Cities

```kotlin
val usTestCoordinates = mapOf(
    // New York
    "Times Square" to Pair(40.7580, -73.9855),
    "JFK Airport" to Pair(40.6413, -73.7781),

    // Los Angeles
    "Hollywood" to Pair(34.0928, -118.3287),
    "LAX Airport" to Pair(33.9416, -118.4085),

    // Chicago
    "Loop" to Pair(41.8781, -87.6298),
    "O'Hare Airport" to Pair(41.9742, -87.9073),

    // Denver
    "Downtown Denver" to Pair(39.7392, -104.9903),
    "DIA Airport" to Pair(39.8561, -104.6737),

    // Miami
    "South Beach" to Pair(25.7907, -80.1300),
    "Miami Airport" to Pair(25.7959, -80.2871)
)
```

---

## Custom Regions

### Finding OSM Data Sources

**Geofabrik Index:** https://download.geofabrik.de/

**To find region bounds:**
1. Visit https://boundingbox.klokantech.com/
2. Select region on map
3. Choose "CSV" format
4. Copy min_lat, max_lat, min_lon, max_lon values

### Method 1: Custom Metro Area Extract

Extract specific metro area from larger state data:

**Using Osmium Tool:**

```bash
# Install osmium
sudo apt-get install osmium-tool

# Extract NYC metro from New York state
osmium extract \
  --bbox -74.3,40.5,-73.7,41.0 \
  data/osm/new-york-latest.osm.pbf \
  -o data/osm/nyc-metro.osm.pbf

# Build tiles from extracted data
./scripts/regions/build-tiles.sh nyc-metro
```

**Configuration with Extract:**

```json
{
  "nyc-metro": {
    "name": "NYC Metro",
    "enabled": true,
    "osm_source": "https://download.geofabrik.de/north-america/us/new-york-latest.osm.pbf",
    "bounds": {
      "min_lat": 40.4774,
      "max_lat": 41.0000,
      "min_lon": -74.3000,
      "max_lon": -73.7000
    },
    "tile_dir": "data/valhalla_tiles/nyc-metro",
    "extract_bbox": true,
    "description": "NYC Metro - 5 boroughs + Northern NJ"
  }
}
```

### Method 2: Custom Build Script

Create `scripts/regions/build-metro-tiles.sh`:

```bash
#!/bin/bash
REGION=$1
OSM_FILE="data/osm/${REGION}-latest.osm.pbf"
EXTRACT_FILE="data/osm/${REGION}-metro.osm.pbf"
TILE_DIR="data/valhalla_tiles/${REGION}"

# Get bounds from regions.json
MIN_LAT=$(jq -r ".regions[\"$REGION\"].bounds.min_lat" config/regions/regions.json)
MAX_LAT=$(jq -r ".regions[\"$REGION\"].bounds.max_lat" config/regions/regions.json)
MIN_LON=$(jq -r ".regions[\"$REGION\"].bounds.min_lon" config/regions/regions.json)
MAX_LON=$(jq -r ".regions[\"$REGION\"].bounds.max_lon" config/regions/regions.json)

# Extract metro area
osmium extract \
  --bbox ${MIN_LON},${MIN_LAT},${MAX_LON},${MAX_LAT} \
  "$OSM_FILE" \
  -o "$EXTRACT_FILE"

# Build tiles
valhalla_build_tiles \
  -c config/valhalla-config.json \
  "$EXTRACT_FILE"

echo "✅ Metro tiles built: $TILE_DIR"
```

### Bounding Boxes for US Metro Areas

```json
{
  "metro_bounds": {
    "nyc": {
      "min_lat": 40.4774, "max_lat": 41.0000,
      "min_lon": -74.3000, "max_lon": -73.7000
    },
    "los-angeles": {
      "min_lat": 33.7037, "max_lat": 34.3373,
      "min_lon": -118.6682, "max_lon": -118.1553
    },
    "chicago": {
      "min_lat": 41.6445, "max_lat": 42.0230,
      "min_lon": -87.9401, "max_lon": -87.5240
    },
    "seattle": {
      "min_lat": 47.4811, "max_lat": 47.7341,
      "min_lon": -122.4598, "max_lon": -122.2244
    },
    "boston": {
      "min_lat": 42.2279, "max_lat": 42.4000,
      "min_lon": -71.1912, "max_lon": -70.9231
    }
  }
}
```

---

## Validation and Testing

### Download Process

**Command:**
```bash
./scripts/regions/download-region-osm.sh <region>
```

**What Happens:**
1. Reads OSM source from configuration
2. Creates data/osm directory
3. Downloads OSM PBF file
4. Downloads and verifies MD5 checksum
5. Reports file size and location

**Expected Time:** 2-10 minutes depending on region size

### Build Process

**Command:**
```bash
./scripts/regions/build-tiles.sh <region>
```

**What Happens:**

| Stage | Description | Time |
|-------|-------------|------|
| Parse OSM | Read and parse OSM PBF file | 5-10 min |
| Build Graph | Create routing graph | 15-25 min |
| Generate Tiles | Create hierarchical tiles | 10-20 min |
| Build Hierarchy | Create multi-level routing | 5-10 min |

**Resource Usage:**
- **CPU:** Uses all available cores
- **RAM:** Peak 6-8 GB for medium regions
- **Disk I/O:** High during tile generation
- **Temp Space:** ~2 GB for intermediate files

**Output Structure:**
```
data/valhalla_tiles/<region>/
└── 2/                    # Zoom level 2
    ├── 000/
    │   ├── 000.gph       # Binary tile files
    │   ├── 001.gph
    │   └── ...
    ├── 001/
    └── 002/
```

### Validation

**Command:**
```bash
./scripts/regions/validate-tiles.sh <region>
```

**Checks Performed:**
1. Tile directory exists
2. Correct hierarchical structure (2/xxx/xxx.gph)
3. Tile file count reasonable
4. Total size reasonable
5. Sample tile files are readable

**Expected Output:**
```
════════════════════════════════════════════════════════════
  Validating Valhalla Tiles for <region>
════════════════════════════════════════════════════════════

✅ Tile directory exists: data/valhalla_tiles/<region>/
✅ Tile structure is valid
✅ Found 12,450 tile files
✅ Total size: 1.2 GB

📊 Tile Distribution:
   Level 0: 145 tiles
   Level 1: 1,234 tiles
   Level 2: 11,071 tiles

✅ All validation checks passed!
```

### Integration Testing

**Basic Test:**

```kotlin
import global.tada.valhalla.Actor
import kotlin.test.*

class RegionIntegrationTest {

    @Test
    fun `test basic route calculation`() {
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
        assertTrue(result.length > 1000)

        actor.close()
    }

    @Test
    fun `test multiple costing modes`() {
        val actor = Actor.createWithExternalTiles("thailand")

        val modes = listOf("auto", "bicycle", "pedestrian")

        modes.forEach { mode ->
            val result = actor.route("""
            {
              "locations": [
                {"lat": 13.7563, "lon": 100.5018},
                {"lat": 13.7465, "lon": 100.5351}
              ],
              "costing": "$mode"
            }
            """)

            assertNotNull(result)
        }

        actor.close()
    }
}
```

**Run Tests:**
```bash
cd src/bindings/java
./gradlew test --tests "*RegionIntegrationTest"
```

---

## Production Deployment

### Multi-Region Application

```kotlin
import global.tada.valhalla.Actor
import java.util.concurrent.ConcurrentHashMap

class MultiRegionRouter(
    private val regions: List<String>
) {
    private val actors = ConcurrentHashMap<String, Actor>()

    init {
        regions.forEach { region ->
            try {
                actors[region] = Actor.createWithExternalTiles(region)
                println("✅ Loaded region: $region")
            } catch (e: Exception) {
                println("❌ Failed to load region: $region - ${e.message}")
            }
        }
    }

    fun route(region: String, request: String): String {
        val actor = actors[region]
            ?: throw IllegalArgumentException("Region $region not loaded")
        return actor.route(request)
    }

    fun detectRegion(lat: Double, lon: Double): String? {
        // Implement region detection based on coordinates
        return when {
            lat in 13.0..21.0 && lon in 97.0..106.0 -> "thailand"
            lat in 40.4..41.0 && lon in -74.3..-73.7 -> "new-york"
            // Add more regions...
            else -> null
        }
    }

    fun close() {
        actors.values.forEach { it.close() }
    }
}

// Usage
fun main() {
    val router = MultiRegionRouter(
        regions = listOf("thailand", "singapore", "new-york")
    )

    val route = router.route("thailand", """
    {
      "locations": [
        {"lat": 13.7563, "lon": 100.5018},
        {"lat": 13.9218, "lon": 100.6066}
      ],
      "costing": "auto"
    }
    """)

    router.close()
}
```

### Docker Deployment

**Dockerfile:**

```dockerfile
FROM openjdk:17-slim

# Install dependencies
RUN apt-get update && apt-get install -y \
    wget \
    && rm -rf /var/lib/apt/lists/*

# Copy application
COPY build/libs/valhalla-routing.jar /app/
WORKDIR /app

# Mount point for tiles
VOLUME /tiles

# Environment variables
ENV VALHALLA_TILES_DIR=/tiles
ENV JAVA_OPTS="-Xmx4g -Xms1g"

EXPOSE 8080

CMD ["sh", "-c", "java $JAVA_OPTS -jar valhalla-routing.jar"]
```

**docker-compose.yml:**

```yaml
version: '3.8'

services:
  valhalla-routing:
    build: .
    ports:
      - "8080:8080"
    volumes:
      - ./data/valhalla_tiles:/tiles:ro
    environment:
      - VALHALLA_TILES_DIR=/tiles
      - ENABLED_REGIONS=thailand,singapore,new-york
    deploy:
      resources:
        limits:
          memory: 8G
        reservations:
          memory: 4G
```

### Kubernetes Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: valhalla-routing
spec:
  replicas: 3
  selector:
    matchLabels:
      app: valhalla-routing
  template:
    metadata:
      labels:
        app: valhalla-routing
    spec:
      containers:
      - name: valhalla
        image: your-registry/valhalla-routing:latest
        ports:
        - containerPort: 8080
        env:
        - name: VALHALLA_TILES_DIR
          value: "/tiles"
        - name: ENABLED_REGIONS
          value: "thailand,singapore,new-york"
        resources:
          requests:
            memory: "4Gi"
            cpu: "2"
          limits:
            memory: "8Gi"
            cpu: "4"
        volumeMounts:
        - name: tiles
          mountPath: /tiles
          readOnly: true
      volumes:
      - name: tiles
        persistentVolumeClaim:
          claimName: valhalla-tiles-pvc
```

### Update Strategy

OSM data is updated frequently. Recommended update schedule:

- **Urban areas (Bangkok, NYC):** Weekly
- **Rural areas:** Monthly
- **Test regions:** As needed

**Update Command:**
```bash
# Re-download and rebuild
./scripts/regions/download-region-osm.sh thailand
./scripts/regions/build-tiles.sh thailand
```

---

## Troubleshooting

### Download Fails

**Symptoms:**
```
Error: Failed to download thailand-latest.osm.pbf
Connection timeout
```

**Solutions:**

1. Check internet connection:
   ```bash
   ping download.geofabrik.de
   ```

2. Try manual download with retry:
   ```bash
   wget -c --retry-connrefused --waitretry=1 \
     https://download.geofabrik.de/asia/thailand-latest.osm.pbf
   ```

3. Use alternative mirror (check Geofabrik website)

### Build Fails - Out of Memory

**Symptoms:**
```
Error: valhalla_build_tiles killed
Signal: 9 (SIGKILL)
```

**Solutions:**

1. Check available RAM:
   ```bash
   free -h
   ```

2. Add swap space:
   ```bash
   sudo dd if=/dev/zero of=/swapfile bs=1G count=8
   sudo chmod 600 /swapfile
   sudo mkswap /swapfile
   sudo swapon /swapfile
   ```

3. Reduce concurrency in build config:
   ```json
   {
     "mjolnir": {
       "concurrency": 2
     }
   }
   ```

### Build Fails - Corrupt OSM Data

**Symptoms:**
```
Error: Failed to parse OSM data
Invalid PBF format
```

**Solutions:**

1. Verify checksum:
   ```bash
   md5sum -c data/osm/thailand-latest.osm.pbf.md5
   ```

2. Re-download:
   ```bash
   rm data/osm/thailand-latest.osm.pbf
   ./scripts/regions/download-region-osm.sh thailand
   ```

3. Check file size is correct

### Routes Fail - Location Unreachable

**Symptoms:**
```
Error: No route found
Error: Location is unreachable
```

**Solutions:**

1. Check coordinates are within region bounds:
   ```kotlin
   // Ensure coordinates match region
   val bounds = config.regions.thailand.bounds
   if (lat < bounds.min_lat || lat > bounds.max_lat) {
       println("Coordinates outside region!")
   }
   ```

2. Validate tiles:
   ```bash
   ./scripts/regions/validate-tiles.sh thailand
   ```

3. Test with major city coordinates (guaranteed coverage)

### Actor Creation Fails

**Symptoms:**
```
Exception: Failed to create Actor
Error: Tiles not found
```

**Solutions:**

1. Check environment variable:
   ```bash
   echo $VALHALLA_TILES_DIR
   ```

2. Verify tile directory exists:
   ```bash
   ls -la $VALHALLA_TILES_DIR/thailand/2/000/
   ```

3. Use direct path:
   ```kotlin
   val actor = Actor.createWithTilePath(
       "/absolute/path/to/data/valhalla_tiles/thailand"
   )
   ```

### Slow Route Calculation

**Symptoms:**
- Routes take > 5 seconds
- High CPU usage
- Memory grows over time

**Solutions:**

1. Reuse Actor instances:
   ```kotlin
   // Good: Create once, use many times
   val actor = Actor.createWithExternalTiles("thailand")
   repeat(100) { actor.route(request) }
   actor.close()

   // Bad: Create per request
   repeat(100) {
       Actor.createWithExternalTiles("thailand").use { it.route(request) }
   }
   ```

2. Optimize costing options:
   ```json
   {
     "costing_options": {
       "auto": {
         "shortest": true
       }
     }
   }
   ```

3. Use SSD storage for tiles

---

## Reference

### Performance Comparison

| Region | OSM Size | Tile Size | Build Time | Tile Count | RAM Usage |
|--------|----------|-----------|------------|------------|-----------|
| Singapore | 230 MB | 450 MB | 15 min | 1,234 | 2 GB |
| Thailand | 500 MB | 1.2 GB | 45 min | 12,450 | 6 GB |
| Malaysia | 450 MB | 1.0 GB | 40 min | 10,234 | 5 GB |
| New York | 200 MB | 520 MB | 25 min | 8,234 | 4 GB |
| California | 650 MB | 850 MB | 60 min | 15,678 | 8 GB |
| Texas | 550 MB | 680 MB | 50 min | 12,890 | 7 GB |

### Resource Planning

**Storage Requirements:**

| Coverage | Regions | OSM Size | Tile Size | Total |
|----------|---------|----------|-----------|-------|
| Single City | 1 metro | 50 MB | 120 MB | 200 MB |
| Single State | 1 state | 200 MB | 500 MB | 1 GB |
| Regional | 5 regions | 800 MB | 2 GB | 3 GB |
| Multi-Country | 10 countries | 3 GB | 8 GB | 11 GB |

**RAM Requirements:**

| Concurrent Regions | Recommended RAM |
|-------------------|-----------------|
| 1-2 regions | 4 GB |
| 3-5 regions | 8 GB |
| 6-10 regions | 16 GB |
| 11-20 regions | 32 GB |

### Quick Commands

```bash
# Download region
./scripts/regions/download-region-osm.sh <region>

# Build tiles
./scripts/regions/build-tiles.sh <region>

# Validate tiles
./scripts/regions/validate-tiles.sh <region>

# Full automated setup
./scripts/regions/setup-valhalla.sh --region <region>

# Batch processing
for region in thailand malaysia vietnam; do
    ./scripts/regions/download-region-osm.sh $region
    ./scripts/regions/build-tiles.sh $region
done
```

### Code Template

```kotlin
import global.tada.valhalla.Actor

fun main() {
    // Set environment variable
    // export VALHALLA_TILES_DIR=/path/to/data/valhalla_tiles

    val actor = Actor.createWithExternalTiles("region-name")

    val result = actor.route("""
    {
      "locations": [
        {"lat": 0.0, "lon": 0.0},
        {"lat": 0.0, "lon": 0.0}
      ],
      "costing": "auto",
      "units": "kilometers"
    }
    """)

    println(result)
    actor.close()
}
```

---

## Additional Resources

- **Valhalla Documentation:** https://valhalla.readthedocs.io/
- **Geofabrik Downloads:** https://download.geofabrik.de/
- **OSM Wiki:** https://wiki.openstreetmap.org/
- **Multi-Region API Guide:** [MULTI_REGION_API.md](./MULTI_REGION_API.md)
- **Region Configuration Guide:** [README.md](./README.md)

---

**Happy Routing!**

For issues not covered here, check the project documentation or open an issue on GitHub.
