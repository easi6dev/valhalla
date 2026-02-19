# Adding US Cities and States to Valhalla

Complete guide for adding US metropolitan areas (New York, Denver, etc.) and states as routing regions.

---

## 📋 Table of Contents

1. [Quick Start - Adding New York City](#quick-start---adding-new-york-city)
2. [Adding Denver](#adding-denver)
3. [Adding Entire US States](#adding-entire-us-states)
4. [City vs State: Which to Choose](#city-vs-state-which-to-choose)
5. [Complete US Region List](#complete-us-region-list)
6. [Custom Metro Area Extraction](#custom-metro-area-extraction)
7. [Production Deployment](#production-deployment)

---

## 🗽 Quick Start - Adding New York City

### Overview

**New York Metro Area includes:**
- New York City (5 boroughs)
- Northern New Jersey
- Long Island
- Westchester County
- Parts of Connecticut

**Options:**
1. **New York State** - Entire state (~200 MB OSM, 500 MB tiles)
2. **New York Metro** - Custom extracted metro area (~50 MB OSM, 120 MB tiles)
3. **Northeast US** - NY + surrounding states (~800 MB OSM, 2 GB tiles)

---

### Step 1: Add New York to Configuration

Edit `config/regions/regions.json`:

```json
{
  "regions": {
    "singapore": { /* ... */ },
    "thailand": { /* ... */ },
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
          "country_crossing_penalty": 0,
          "use_highways": 1.0,
          "use_tolls": 0.5,
          "top_speed": 120
        },
        "taxi": {
          "maneuver_penalty": 5,
          "use_highways": 1.0,
          "use_tolls": 0.3,
          "top_speed": 120
        },
        "bicycle": {
          "maneuver_penalty": 5,
          "use_roads": 0.5,
          "use_hills": 0.3
        },
        "pedestrian": {
          "walking_speed": 5.1,
          "max_distance": 100000
        }
      },
      "timezone": "America/New_York",
      "locale": "en-US",
      "currency": "USD",
      "description": "New York State including NYC metro area"
    }
  }
}
```

### Step 2: Download New York OSM Data

```bash
cd /path/to/valhallaV3

# Download New York State data
./scripts/regions/download-region-osm.sh new-york
```

**Expected output:**
```
════════════════════════════════════════════════════════════
  Downloading OpenStreetMap Data for New York
════════════════════════════════════════════════════════════

📦 Downloading: new-york-latest.osm.pbf
   Source: https://download.geofabrik.de/north-america/us/new-york-latest.osm.pbf
   Size: ~200 MB

✅ Download complete!
✅ MD5 checksum verified
📁 Saved to: data/osm/new-york-latest.osm.pbf
```

**Time:** 2-5 minutes

### Step 3: Build New York Tiles

```bash
./scripts/regions/build-tiles.sh new-york
```

**Expected output:**
```
════════════════════════════════════════════════════════════
  Building Valhalla Tiles for New York
════════════════════════════════════════════════════════════

📂 Input:  data/osm/new-york-latest.osm.pbf
📂 Output: data/valhalla_tiles/new-york/

🔨 Building tiles...
   [====================] 100%

✅ Tile build complete!
📊 Statistics:
   - Total tiles: 8,234
   - Total size: 520 MB
   - Build time: 25 minutes
```

**Time:** 20-35 minutes
**RAM Required:** 6-8 GB
**Disk Space:** 2 GB (OSM + tiles + temp)

### Step 4: Validate Tiles

```bash
./scripts/regions/validate-tiles.sh new-york
```

### Step 5: Test New York Routes

```kotlin
import global.tada.valhalla.Actor

fun main() {
    // Create New York actor
    val actor = Actor.createWithExternalTiles("new-york")

    // Test 1: Manhattan route
    println("📍 Test 1: Times Square to Central Park")
    val manhattan = actor.route("""
    {
      "locations": [
        {"lat": 40.7580, "lon": -73.9855},  // Times Square
        {"lat": 40.7829, "lon": -73.9654}   // Central Park
      ],
      "costing": "auto",
      "units": "miles"
    }
    """)
    println("✅ Manhattan route calculated")

    // Test 2: Cross-borough route
    println("\n📍 Test 2: Manhattan to JFK Airport")
    val crossBorough = actor.route("""
    {
      "locations": [
        {"lat": 40.7580, "lon": -73.9855},  // Times Square
        {"lat": 40.6413, "lon": -73.7781}   // JFK Airport
      ],
      "costing": "auto",
      "units": "miles"
    }
    """)
    println("✅ Cross-borough route calculated")

    // Test 3: Bicycle route
    println("\n📍 Test 3: Brooklyn Bridge (bicycle)")
    val bicycle = actor.route("""
    {
      "locations": [
        {"lat": 40.7061, "lon": -74.0087},  // Brooklyn Bridge (Manhattan)
        {"lat": 40.6974, "lon": -73.9875}   // Brooklyn Bridge (Brooklyn)
      ],
      "costing": "bicycle",
      "units": "miles"
    }
    """)
    println("✅ Bicycle route calculated")

    actor.close()
    println("\n✅ All New York tests passed!")
}
```

---

## 🏔️ Adding Denver

### Step 1: Add Denver to Configuration

```json
{
  "regions": {
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
        "auto": {
          "maneuver_penalty": 5,
          "use_highways": 1.0,
          "use_tolls": 0.7,
          "top_speed": 120
        },
        "bicycle": {
          "use_hills": 0.4,
          "avoid_bad_surfaces": 0.25
        }
      },
      "timezone": "America/Denver",
      "locale": "en-US",
      "currency": "USD",
      "description": "Denver metropolitan area (using Colorado state data)"
    }
  }
}
```

**Note:** Denver uses Colorado state data. You can filter to metro area only (see [Custom Metro Area Extraction](#custom-metro-area-extraction)).

### Step 2: Download Colorado Data

```bash
./scripts/regions/download-region-osm.sh denver
```

This downloads Colorado state data (~80 MB).

### Step 3: Build Denver Tiles

```bash
./scripts/regions/build-tiles.sh denver
```

**Expected:**
- Tiles: ~200 MB (full Colorado)
- Build time: 15-20 minutes
- RAM: 4-6 GB

### Step 4: Test Denver Routes

```kotlin
val actor = Actor.createWithExternalTiles("denver")

// Downtown Denver to Denver Airport
val route = actor.route("""
{
  "locations": [
    {"lat": 39.7392, "lon": -104.9903},  // Downtown Denver
    {"lat": 39.8561, "lon": -104.6737}   // Denver Int'l Airport
  ],
  "costing": "auto",
  "units": "miles"
}
""")

actor.close()
```

---

## 🗺️ Adding Entire US States

### Available US States from Geofabrik

All 50 US states + territories are available. Here are the most commonly used:

#### Large States (>500 MB tiles)

```json
{
  "california": {
    "name": "California",
    "enabled": true,
    "osm_source": "https://download.geofabrik.de/north-america/us/california-latest.osm.pbf",
    "bounds": {"min_lat": 32.5343, "max_lat": 42.0095, "min_lon": -124.4096, "max_lon": -114.1312},
    "tile_dir": "data/valhalla_tiles/california",
    "timezone": "America/Los_Angeles",
    "description": "California - includes LA, SF, San Diego"
  },
  "texas": {
    "name": "Texas",
    "enabled": true,
    "osm_source": "https://download.geofabrik.de/north-america/us/texas-latest.osm.pbf",
    "bounds": {"min_lat": 25.8371, "max_lat": 36.5007, "min_lon": -106.6456, "max_lon": -93.5083},
    "tile_dir": "data/valhalla_tiles/texas",
    "timezone": "America/Chicago",
    "description": "Texas - includes Houston, Dallas, Austin, San Antonio"
  },
  "florida": {
    "name": "Florida",
    "enabled": true,
    "osm_source": "https://download.geofabrik.de/north-america/us/florida-latest.osm.pbf",
    "bounds": {"min_lat": 24.5210, "max_lat": 31.0009, "min_lon": -87.6349, "max_lon": -80.0310},
    "tile_dir": "data/valhalla_tiles/florida",
    "timezone": "America/New_York",
    "description": "Florida - includes Miami, Orlando, Tampa"
  }
}
```

#### Medium States (100-500 MB tiles)

```json
{
  "illinois": {
    "name": "Illinois",
    "enabled": true,
    "osm_source": "https://download.geofabrik.de/north-america/us/illinois-latest.osm.pbf",
    "bounds": {"min_lat": 36.9703, "max_lat": 42.5083, "min_lon": -91.5130, "max_lon": -87.4950},
    "tile_dir": "data/valhalla_tiles/illinois",
    "timezone": "America/Chicago",
    "description": "Illinois - includes Chicago"
  },
  "pennsylvania": {
    "name": "Pennsylvania",
    "enabled": true,
    "osm_source": "https://download.geofabrik.de/north-america/us/pennsylvania-latest.osm.pbf",
    "bounds": {"min_lat": 39.7198, "max_lat": 42.2694, "min_lon": -80.5195, "max_lon": -74.6895},
    "tile_dir": "data/valhalla_tiles/pennsylvania",
    "timezone": "America/New_York",
    "description": "Pennsylvania - includes Philadelphia, Pittsburgh"
  },
  "washington": {
    "name": "Washington",
    "enabled": true,
    "osm_source": "https://download.geofabrik.de/north-america/us/washington-latest.osm.pbf",
    "bounds": {"min_lat": 45.5435, "max_lat": 49.0024, "min_lon": -124.8489, "max_lon": -116.9155},
    "tile_dir": "data/valhalla_tiles/washington",
    "timezone": "America/Los_Angeles",
    "description": "Washington - includes Seattle, Spokane"
  }
}
```

#### Small States (<100 MB tiles)

```json
{
  "massachusetts": {
    "name": "Massachusetts",
    "enabled": true,
    "osm_source": "https://download.geofabrik.de/north-america/us/massachusetts-latest.osm.pbf",
    "bounds": {"min_lat": 41.2376, "max_lat": 42.8867, "min_lon": -73.5081, "max_lon": -69.9286},
    "tile_dir": "data/valhalla_tiles/massachusetts",
    "timezone": "America/New_York",
    "description": "Massachusetts - includes Boston"
  },
  "connecticut": {
    "name": "Connecticut",
    "enabled": true,
    "osm_source": "https://download.geofabrik.de/north-america/us/connecticut-latest.osm.pbf",
    "bounds": {"min_lat": 40.9509, "max_lat": 42.0508, "min_lon": -73.7277, "max_lon": -71.7867},
    "tile_dir": "data/valhalla_tiles/connecticut",
    "timezone": "America/New_York",
    "description": "Connecticut"
  },
  "colorado": {
    "name": "Colorado",
    "enabled": true,
    "osm_source": "https://download.geofabrik.de/north-america/us/colorado-latest.osm.pbf",
    "bounds": {"min_lat": 36.9930, "max_lat": 41.0023, "min_lon": -109.0452, "max_lon": -102.0415},
    "tile_dir": "data/valhalla_tiles/colorado",
    "timezone": "America/Denver",
    "description": "Colorado - includes Denver, Colorado Springs"
  }
}
```

---

## 🎯 City vs State: Which to Choose?

### Decision Matrix

| Scenario | Recommendation | Reason |
|----------|----------------|--------|
| **Single city focus** | Extract metro area | Smaller files, faster builds |
| **Multi-city state** | Use full state | One download covers all cities |
| **Cross-state routes** | Regional extract | Covers metro + suburbs |
| **Nationwide service** | All states or US-wide | Complete coverage |
| **Development/Testing** | Small state or city | Fast iteration |

### Examples

#### ✅ Use City Extract When:
- **New York City taxi service** → NYC metro area only
- **Denver food delivery** → Denver metro only
- **Boston bike sharing** → Boston metro only

#### ✅ Use Full State When:
- **California ride-hailing** → Need LA, SF, SD, etc.
- **Texas logistics** → Houston, Dallas, Austin, San Antonio
- **Florida tourism** → Miami, Orlando, Tampa

#### ✅ Use Multi-State When:
- **Northeast corridor** → NY + NJ + CT + MA
- **Pacific Northwest** → WA + OR
- **Southwest** → AZ + NM + NV

---

## 📋 Complete US Region List

### All 50 States

| State | OSM Source | Est. Tiles | Build Time |
|-------|------------|------------|------------|
| Alabama | `https://download.geofabrik.de/north-america/us/alabama-latest.osm.pbf` | 150 MB | 12 min |
| Alaska | `https://download.geofabrik.de/north-america/us/alaska-latest.osm.pbf` | 80 MB | 10 min |
| Arizona | `https://download.geofabrik.de/north-america/us/arizona-latest.osm.pbf` | 180 MB | 15 min |
| Arkansas | `https://download.geofabrik.de/north-america/us/arkansas-latest.osm.pbf` | 120 MB | 12 min |
| California | `https://download.geofabrik.de/north-america/us/california-latest.osm.pbf` | 850 MB | 60 min |
| Colorado | `https://download.geofabrik.de/north-america/us/colorado-latest.osm.pbf` | 180 MB | 15 min |
| Connecticut | `https://download.geofabrik.de/north-america/us/connecticut-latest.osm.pbf` | 90 MB | 10 min |
| Delaware | `https://download.geofabrik.de/north-america/us/delaware-latest.osm.pbf` | 50 MB | 8 min |
| Florida | `https://download.geofabrik.de/north-america/us/florida-latest.osm.pbf` | 450 MB | 35 min |
| Georgia | `https://download.geofabrik.de/north-america/us/georgia-latest.osm.pbf` | 250 MB | 20 min |
| Hawaii | `https://download.geofabrik.de/north-america/us/hawaii-latest.osm.pbf` | 60 MB | 8 min |
| Idaho | `https://download.geofabrik.de/north-america/us/idaho-latest.osm.pbf` | 100 MB | 12 min |
| Illinois | `https://download.geofabrik.de/north-america/us/illinois-latest.osm.pbf` | 320 MB | 25 min |
| Indiana | `https://download.geofabrik.de/north-america/us/indiana-latest.osm.pbf` | 200 MB | 18 min |
| Iowa | `https://download.geofabrik.de/north-america/us/iowa-latest.osm.pbf` | 150 MB | 14 min |
| Kansas | `https://download.geofabrik.de/north-america/us/kansas-latest.osm.pbf` | 140 MB | 13 min |
| Kentucky | `https://download.geofabrik.de/north-america/us/kentucky-latest.osm.pbf` | 160 MB | 14 min |
| Louisiana | `https://download.geofabrik.de/north-america/us/louisiana-latest.osm.pbf` | 150 MB | 14 min |
| Maine | `https://download.geofabrik.de/north-america/us/maine-latest.osm.pbf` | 90 MB | 10 min |
| Maryland | `https://download.geofabrik.de/north-america/us/maryland-latest.osm.pbf` | 140 MB | 13 min |
| Massachusetts | `https://download.geofabrik.de/north-america/us/massachusetts-latest.osm.pbf` | 150 MB | 13 min |
| Michigan | `https://download.geofabrik.de/north-america/us/michigan-latest.osm.pbf` | 280 MB | 22 min |
| Minnesota | `https://download.geofabrik.de/north-america/us/minnesota-latest.osm.pbf` | 200 MB | 17 min |
| Mississippi | `https://download.geofabrik.de/north-america/us/mississippi-latest.osm.pbf` | 120 MB | 12 min |
| Missouri | `https://download.geofabrik.de/north-america/us/missouri-latest.osm.pbf` | 200 MB | 17 min |
| Montana | `https://download.geofabrik.de/north-america/us/montana-latest.osm.pbf` | 100 MB | 12 min |
| Nebraska | `https://download.geofabrik.de/north-america/us/nebraska-latest.osm.pbf` | 110 MB | 12 min |
| Nevada | `https://download.geofabrik.de/north-america/us/nevada-latest.osm.pbf` | 110 MB | 12 min |
| New Hampshire | `https://download.geofabrik.de/north-america/us/new-hampshire-latest.osm.pbf` | 80 MB | 10 min |
| New Jersey | `https://download.geofabrik.de/north-america/us/new-jersey-latest.osm.pbf` | 210 MB | 18 min |
| New Mexico | `https://download.geofabrik.de/north-america/us/new-mexico-latest.osm.pbf` | 110 MB | 12 min |
| New York | `https://download.geofabrik.de/north-america/us/new-york-latest.osm.pbf` | 520 MB | 40 min |
| North Carolina | `https://download.geofabrik.de/north-america/us/north-carolina-latest.osm.pbf` | 280 MB | 22 min |
| North Dakota | `https://download.geofabrik.de/north-america/us/north-dakota-latest.osm.pbf` | 80 MB | 10 min |
| Ohio | `https://download.geofabrik.de/north-america/us/ohio-latest.osm.pbf` | 300 MB | 24 min |
| Oklahoma | `https://download.geofabrik.de/north-america/us/oklahoma-latest.osm.pbf` | 140 MB | 13 min |
| Oregon | `https://download.geofabrik.de/north-america/us/oregon-latest.osm.pbf` | 180 MB | 15 min |
| Pennsylvania | `https://download.geofabrik.de/north-america/us/pennsylvania-latest.osm.pbf` | 340 MB | 26 min |
| Rhode Island | `https://download.geofabrik.de/north-america/us/rhode-island-latest.osm.pbf` | 50 MB | 8 min |
| South Carolina | `https://download.geofabrik.de/north-america/us/south-carolina-latest.osm.pbf` | 150 MB | 13 min |
| South Dakota | `https://download.geofabrik.de/north-america/us/south-dakota-latest.osm.pbf` | 90 MB | 10 min |
| Tennessee | `https://download.geofabrik.de/north-america/us/tennessee-latest.osm.pbf` | 190 MB | 16 min |
| Texas | `https://download.geofabrik.de/north-america/us/texas-latest.osm.pbf` | 680 MB | 50 min |
| Utah | `https://download.geofabrik.de/north-america/us/utah-latest.osm.pbf` | 130 MB | 12 min |
| Vermont | `https://download.geofabrik.de/north-america/us/vermont-latest.osm.pbf` | 70 MB | 9 min |
| Virginia | `https://download.geofabrik.de/north-america/us/virginia-latest.osm.pbf` | 240 MB | 20 min |
| Washington | `https://download.geofabrik.de/north-america/us/washington-latest.osm.pbf` | 250 MB | 20 min |
| West Virginia | `https://download.geofabrik.de/north-america/us/west-virginia-latest.osm.pbf` | 100 MB | 11 min |
| Wisconsin | `https://download.geofabrik.de/north-america/us/wisconsin-latest.osm.pbf` | 200 MB | 17 min |
| Wyoming | `https://download.geofabrik.de/north-america/us/wyoming-latest.osm.pbf` | 80 MB | 10 min |

### Major Metropolitan Areas

| Metro Area | Use State | Major Cities Included |
|------------|-----------|----------------------|
| **New York Metro** | New York + New Jersey | NYC, Newark, Jersey City |
| **Los Angeles Metro** | California | LA, Long Beach, Anaheim |
| **Chicago Metro** | Illinois | Chicago, Aurora, Joliet |
| **Dallas-Fort Worth** | Texas | Dallas, Fort Worth, Arlington |
| **Houston Metro** | Texas | Houston, Sugar Land, The Woodlands |
| **Washington DC Metro** | DC + Virginia + Maryland | DC, Arlington, Alexandria |
| **Miami Metro** | Florida | Miami, Fort Lauderdale, West Palm Beach |
| **Philadelphia Metro** | Pennsylvania | Philadelphia, Camden, Wilmington |
| **Atlanta Metro** | Georgia | Atlanta, Sandy Springs, Roswell |
| **Boston Metro** | Massachusetts | Boston, Cambridge, Newton |
| **San Francisco Bay Area** | California | SF, Oakland, San Jose |
| **Phoenix Metro** | Arizona | Phoenix, Mesa, Scottsdale |
| **Seattle Metro** | Washington | Seattle, Tacoma, Bellevue |
| **Denver Metro** | Colorado | Denver, Aurora, Lakewood |
| **Las Vegas Metro** | Nevada | Las Vegas, Henderson, North Las Vegas |

---

## 🔧 Custom Metro Area Extraction

For extracting specific metro areas from state data (smaller tile sizes):

### Method 1: Using Osmium Tool

```bash
# Install osmium
sudo apt-get install osmium-tool

# Extract NYC metro from New York state
osmium extract \
  --bbox -74.3,40.5,-73.7,41.0 \
  data/osm/new-york-latest.osm.pbf \
  -o data/osm/nyc-metro.osm.pbf

# Build tiles from extracted data
valhalla_build_tiles \
  -c config/valhalla-nyc.json \
  data/osm/nyc-metro.osm.pbf
```

### Method 2: Using Bounding Box in Configuration

Create custom region with specific bounds:

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
    "description": "NYC Metro - Manhattan, Brooklyn, Queens, Bronx, Staten Island"
  }
}
```

Then create a custom build script:

```bash
#!/bin/bash
# File: scripts/regions/build-metro-tiles.sh

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

# Build tiles from extracted data
valhalla_build_tiles \
  -c config/valhalla-config.json \
  "$EXTRACT_FILE"

echo "✅ Metro tiles built: $TILE_DIR"
```

### Bounding Boxes for Major US Cities

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
    "houston": {
      "min_lat": 29.5233, "max_lat": 30.1104,
      "min_lon": -95.7885, "max_lon": -95.0145
    },
    "phoenix": {
      "min_lat": 33.2948, "max_lat": 33.7620,
      "min_lon": -112.3232, "max_lon": -111.9266
    },
    "philadelphia": {
      "min_lat": 39.8670, "max_lat": 40.1379,
      "min_lon": -75.2803, "max_lon": -74.9558
    },
    "san-antonio": {
      "min_lat": 29.3132, "max_lat": 29.6471,
      "min_lon": -98.7002, "max_lon": -98.2952
    },
    "san-diego": {
      "min_lat": 32.5343, "max_lat": 33.1143,
      "min_lon": -117.2713, "max_lon": -116.9065
    },
    "dallas": {
      "min_lat": 32.6179, "max_lat": 33.0235,
      "min_lon": -97.0168, "max_lon": -96.5836
    },
    "san-jose": {
      "min_lat": 37.1359, "max_lat": 37.4694,
      "min_lon": -122.0574, "max_lon": -121.6509
    },
    "austin": {
      "min_lat": 30.0986, "max_lat": 30.5168,
      "min_lon": -97.9383, "max_lon": -97.5698
    },
    "seattle": {
      "min_lat": 47.4811, "max_lat": 47.7341,
      "min_lon": -122.4598, "max_lon": -122.2244
    },
    "denver": {
      "min_lat": 39.6143, "max_lat": 39.9143,
      "min_lon": -105.1100, "max_lon": -104.6000
    },
    "boston": {
      "min_lat": 42.2279, "max_lat": 42.4000,
      "min_lon": -71.1912, "max_lon": -70.9231
    },
    "miami": {
      "min_lat": 25.7090, "max_lat": 25.8554,
      "min_lon": -80.3201, "max_lon": -80.1373
    }
  }
}
```

---

## 🚀 Production Deployment

### Multi-Region Application Example

```kotlin
// File: src/main/kotlin/routing/USRegionRouter.kt
package routing

import global.tada.valhalla.Actor
import java.util.concurrent.ConcurrentHashMap

class USRegionRouter(
    private val regions: List<String>
) {
    private val actors = ConcurrentHashMap<String, Actor>()

    init {
        // Load all regions
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

    fun detectRegionFromCoordinates(lat: Double, lon: Double): String? {
        // Simple region detection based on coordinates
        return when {
            // New York
            lat in 40.4..41.0 && lon in -74.3..-73.7 -> "new-york"
            // California
            lat in 32.5..42.0 && lon in -124.4..-114.1 -> "california"
            // Texas
            lat in 25.8..36.5 && lon in -106.6..-93.5 -> "texas"
            // Florida
            lat in 24.5..31.0 && lon in -87.6..-80.0 -> "florida"
            // Add more regions...
            else -> null
        }
    }

    fun routeAuto(lat: Double, lon: Double, request: String): String {
        val region = detectRegionFromCoordinates(lat, lon)
            ?: throw IllegalArgumentException("No region found for coordinates: $lat, $lon")
        return route(region, request)
    }

    fun close() {
        actors.values.forEach { it.close() }
    }
}

// Usage
fun main() {
    val router = USRegionRouter(
        regions = listOf("new-york", "california", "texas", "florida")
    )

    // Route in New York
    val nyRoute = router.route("new-york", """
    {
      "locations": [
        {"lat": 40.7580, "lon": -73.9855},
        {"lat": 40.7829, "lon": -73.9654}
      ],
      "costing": "auto"
    }
    """)

    // Auto-detect region and route
    val autoRoute = router.routeAuto(40.7580, -73.9855, """
    {
      "locations": [
        {"lat": 40.7580, "lon": -73.9855},
        {"lat": 40.7829, "lon": -73.9654}
      ],
      "costing": "auto"
    }
    """)

    router.close()
}
```

### Docker Deployment with Multiple US Regions

```dockerfile
# Dockerfile
FROM openjdk:17-slim

# Install Valhalla tools (optional, for on-demand tile building)
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

# Expose port
EXPOSE 8080

CMD ["sh", "-c", "java $JAVA_OPTS -jar valhalla-routing.jar"]
```

```yaml
# docker-compose.yml
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
      - ENABLED_REGIONS=new-york,california,texas,florida
    deploy:
      resources:
        limits:
          memory: 8G
        reservations:
          memory: 4G
```

### Kubernetes Deployment

```yaml
# kubernetes/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: valhalla-us-routing
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
          value: "new-york,california,texas,florida,illinois"
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
        livenessProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 60
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /ready
            port: 8080
          initialDelaySeconds: 30
          periodSeconds: 5
      volumes:
      - name: tiles
        persistentVolumeClaim:
          claimName: valhalla-tiles-pvc

---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: valhalla-tiles-pvc
spec:
  accessModes:
    - ReadOnlyMany
  storageClassName: nfs-storage
  resources:
    requests:
      storage: 50Gi
```

---

## 📊 Resource Planning

### Storage Requirements by Coverage

| Coverage | States/Regions | OSM Size | Tile Size | Total |
|----------|----------------|----------|-----------|-------|
| **Single City** | 1 metro extract | 50 MB | 120 MB | 200 MB |
| **Single State** | 1 state | 100-500 MB | 200-800 MB | 1-2 GB |
| **Regional** | 5 states | 800 MB | 2 GB | 3 GB |
| **Major Metro Areas** | 10 cities | 1.5 GB | 3.5 GB | 5 GB |
| **Nationwide** | All 50 states | 8 GB | 18 GB | 26 GB |

### RAM Requirements

| Concurrent Regions | Recommended RAM |
|-------------------|-----------------|
| 1-2 regions | 4 GB |
| 3-5 regions | 8 GB |
| 6-10 regions | 16 GB |
| 11-20 regions | 32 GB |
| 20+ regions | 64 GB |

### CPU Requirements

- **Tile Building:** Use all available cores
- **Runtime Routing:** 2 cores per 1000 req/min
- **Recommended:** 4-8 cores for production

---

## 🧪 Testing US Regions

### Test Coordinates for Major US Cities

```kotlin
val testCoordinates = mapOf(
    // New York
    "Times Square" to Pair(40.7580, -73.9855),
    "Central Park" to Pair(40.7829, -73.9654),
    "JFK Airport" to Pair(40.6413, -73.7781),

    // Los Angeles
    "Hollywood" to Pair(34.0928, -118.3287),
    "Santa Monica" to Pair(34.0195, -118.4912),
    "LAX Airport" to Pair(33.9416, -118.4085),

    // Chicago
    "Loop" to Pair(41.8781, -87.6298),
    "O'Hare Airport" to Pair(41.9742, -87.9073),

    // Houston
    "Downtown Houston" to Pair(29.7604, -95.3698),
    "IAH Airport" to Pair(29.9902, -95.3368),

    // Denver
    "Downtown Denver" to Pair(39.7392, -104.9903),
    "DIA Airport" to Pair(39.8561, -104.6737),

    // Miami
    "South Beach" to Pair(25.7907, -80.1300),
    "Miami Airport" to Pair(25.7959, -80.2871),

    // Seattle
    "Pike Place" to Pair(47.6097, -122.3422),
    "SeaTac Airport" to Pair(47.4502, -122.3088),

    // Boston
    "Boston Common" to Pair(42.3551, -71.0656),
    "Logan Airport" to Pair(42.3656, -71.0096)
)
```

---

## 📚 Quick Reference

### Add New York
```bash
# 1. Edit config/regions/regions.json - add new-york
# 2. Download and build
./scripts/regions/download-region-osm.sh new-york
./scripts/regions/build-tiles.sh new-york
# 3. Use in code
export VALHALLA_TILES_DIR=$(pwd)/data/valhalla_tiles
```

### Add Denver (using Colorado)
```bash
# 1. Edit config/regions/regions.json - add denver
# 2. Download and build
./scripts/regions/download-region-osm.sh denver
./scripts/regions/build-tiles.sh denver
```

### Add Multiple States
```bash
# Batch download and build
for state in california texas florida new-york; do
    ./scripts/regions/download-region-osm.sh $state
    ./scripts/regions/build-tiles.sh $state
done
```

---

**Ready to route across the United States!** 🇺🇸

For more information, see:
- [Complete Region Guide](./ADD_NEW_REGION_GUIDE.md)
- [External Tiles Configuration](../../EXTERNAL_TILES_GUIDE.md)
- [Examples](../../examples/)
