# Region Documentation Index

Quick access to guides for adding geographic regions to Valhalla.

---

## 📚 Available Guides

### 🌏 International Regions
**Guide:** [ADD_NEW_REGION_GUIDE.md](./ADD_NEW_REGION_GUIDE.md)

**Covers:**
- Thailand (pre-configured, just enable)
- Southeast Asia (Malaysia, Vietnam, Philippines, Indonesia, Cambodia)
- East Asia (Japan, South Korea, Taiwan)
- South Asia (India, Bangladesh)
- Middle East (UAE, Saudi Arabia)
- Step-by-step instructions
- Custom region addition
- Performance comparisons

**Quick Example - Thailand:**
```bash
./scripts/regions/download-region-osm.sh thailand
./scripts/regions/build-tiles.sh thailand
```

---

### 🇺🇸 United States Regions
**Guide:** [ADD_US_REGIONS_GUIDE.md](./ADD_US_REGIONS_GUIDE.md)

**Covers:**
- All 50 US states with OSM sources
- Major metro areas (NYC, LA, Chicago, Denver, etc.)
- City vs State decision matrix
- Custom metro area extraction
- Complete state reference table

**Quick Example - New York:**
```bash
./scripts/regions/download-region-osm.sh new-york
./scripts/regions/build-tiles.sh new-york
```

**Quick Example - Denver:**
```bash
./scripts/regions/download-region-osm.sh denver
./scripts/regions/build-tiles.sh denver
```

---

## 🚀 Quick Start

### 1. Choose Your Region

| Region Type | Use Guide | Example |
|-------------|-----------|---------|
| **Asian countries** | [International Guide](./ADD_NEW_REGION_GUIDE.md) | Thailand, Japan, Singapore |
| **US cities** | [US Guide](./ADD_US_REGIONS_GUIDE.md) | New York, Denver, LA |
| **US states** | [US Guide](./ADD_US_REGIONS_GUIDE.md) | California, Texas, Florida |
| **European countries** | [International Guide](./ADD_NEW_REGION_GUIDE.md) | Germany, France, UK |
| **Other continents** | [International Guide](./ADD_NEW_REGION_GUIDE.md) | Australia, Brazil, etc. |

### 2. Basic Steps (All Regions)

```bash
# Step 1: Add to config/regions/regions.json
# Step 2: Download OSM data
./scripts/regions/download-region-osm.sh <region-name>

# Step 3: Build tiles
./scripts/regions/build-tiles.sh <region-name>

# Step 4: Validate
./scripts/regions/validate-tiles.sh <region-name>
```

### 3. Use in Code

```kotlin
import global.tada.valhalla.Actor

// Set tile location (once)
export VALHALLA_TILES_DIR=/path/to/data/valhalla_tiles

// Use any region
val actor = Actor.createWithExternalTiles("region-name")
val route = actor.route(/* ... */)
actor.close()
```

---

## 📋 Pre-Configured Regions

These regions are already defined in `config/regions/regions.json`:

| Region | Status | Enable & Use |
|--------|--------|--------------|
| **Singapore** | ✅ Enabled | Ready to use |
| **Thailand** | ⚠️ Disabled | Set `enabled: true` |

All other regions need to be added to the configuration file.

---

## 🗺️ Popular Region Examples

### Asia-Pacific

```json
{
  "thailand": {
    "enabled": true,
    "osm_source": "https://download.geofabrik.de/asia/thailand-latest.osm.pbf"
  },
  "japan": {
    "enabled": true,
    "osm_source": "https://download.geofabrik.de/asia/japan-latest.osm.pbf"
  },
  "australia": {
    "enabled": true,
    "osm_source": "https://download.geofabrik.de/australia-oceania/australia-latest.osm.pbf"
  }
}
```

### United States

```json
{
  "new-york": {
    "enabled": true,
    "osm_source": "https://download.geofabrik.de/north-america/us/new-york-latest.osm.pbf"
  },
  "california": {
    "enabled": true,
    "osm_source": "https://download.geofabrik.de/north-america/us/california-latest.osm.pbf"
  },
  "texas": {
    "enabled": true,
    "osm_source": "https://download.geofabrik.de/north-america/us/texas-latest.osm.pbf"
  }
}
```

### Europe

```json
{
  "germany": {
    "enabled": true,
    "osm_source": "https://download.geofabrik.de/europe/germany-latest.osm.pbf"
  },
  "france": {
    "enabled": true,
    "osm_source": "https://download.geofabrik.de/europe/france-latest.osm.pbf"
  },
  "uk": {
    "enabled": true,
    "osm_source": "https://download.geofabrik.de/europe/great-britain-latest.osm.pbf"
  }
}
```

---

## 📊 Resource Planning

### By Region Size

| Region Type | OSM Size | Tile Size | Build Time | RAM |
|-------------|----------|-----------|------------|-----|
| **Small City** | 20-50 MB | 50-120 MB | 5-10 min | 2-4 GB |
| **Medium City** | 50-200 MB | 120-500 MB | 10-25 min | 4-6 GB |
| **Large City/State** | 200-500 MB | 500 MB-1.5 GB | 25-60 min | 6-10 GB |
| **Large State/Country** | 500 MB-2 GB | 1.5-5 GB | 60-180 min | 10-16 GB |
| **Very Large Country** | 2-10 GB | 5-25 GB | 180-600 min | 16-32 GB |

### Storage Planning

| Coverage | Regions | Total Storage |
|----------|---------|---------------|
| **Single City** | 1 metro | 200 MB - 1 GB |
| **Multi-City** | 3-5 cities | 1-5 GB |
| **Regional** | 5-10 states/countries | 5-20 GB |
| **Continental** | 20-50 regions | 20-100 GB |
| **Global** | 100+ regions | 100-500 GB |

---

## 🔍 Finding OSM Data Sources

### Primary Source: Geofabrik

**Website:** https://download.geofabrik.de/

**Coverage:**
- 🌍 Global coverage
- 📅 Daily updates
- ✅ Reliable mirrors
- 📦 Pre-extracted regions

**Structure:**
```
https://download.geofabrik.de/
├── africa/
├── antarctica/
├── asia/
├── australia-oceania/
├── central-america/
├── europe/
├── north-america/
│   ├── us/
│   │   ├── california-latest.osm.pbf
│   │   ├── new-york-latest.osm.pbf
│   │   └── ... (all 50 states)
│   ├── canada/
│   └── mexico/
└── south-america/
```

### Finding Your Region

1. **Browse Geofabrik:** https://download.geofabrik.de/
2. **Navigate to continent** → country → state/region
3. **Copy URL** ending in `-latest.osm.pbf`
4. **Add to** `config/regions/regions.json`

**Example URLs:**
- California: `https://download.geofabrik.de/north-america/us/california-latest.osm.pbf`
- Thailand: `https://download.geofabrik.de/asia/thailand-latest.osm.pbf`
- Germany: `https://download.geofabrik.de/europe/germany-latest.osm.pbf`

---

## 🧪 Testing New Regions

### Basic Test Template

```kotlin
import global.tada.valhalla.Actor

fun testRegion(regionName: String, lat1: Double, lon1: Double, lat2: Double, lon2: Double) {
    println("Testing $regionName...")

    val actor = Actor.createWithExternalTiles(regionName)

    val route = actor.route("""
    {
      "locations": [
        {"lat": $lat1, "lon": $lon1},
        {"lat": $lat2, "lon": $lon2}
      ],
      "costing": "auto"
    }
    """)

    if (route.contains("\"trip\"")) {
        println("✅ $regionName: Route calculated successfully")
    } else {
        println("❌ $regionName: Route calculation failed")
    }

    actor.close()
}

// Test multiple regions
fun main() {
    testRegion("new-york", 40.7580, -73.9855, 40.7829, -73.9654)
    testRegion("thailand", 13.7563, 100.5018, 13.9218, 100.6066)
    testRegion("california", 34.0522, -118.2437, 37.7749, -122.4194)
}
```

---

## 🐛 Common Issues

### "Region not found"
```bash
# Check regions.json
cat config/regions/regions.json | jq '.regions | keys'

# Ensure region is added and enabled: true
```

### "OSM download failed"
```bash
# Try manual download
cd data/osm
wget https://download.geofabrik.de/path/to/region-latest.osm.pbf

# Then run build
cd ../..
./scripts/regions/build-tiles.sh region-name
```

### "Out of memory during build"
```bash
# Add swap space
sudo fallocate -l 8G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile

# Or reduce concurrency in build script
```

### "No route found"
```bash
# Verify coordinates are within region bounds
# Check regions.json for bounds
cat config/regions/regions.json | jq '.regions["region-name"].bounds'

# Validate tiles
./scripts/regions/validate-tiles.sh region-name
```

---

## 📚 Additional Resources

### Documentation
- [External Tiles Guide](../../EXTERNAL_TILES_GUIDE.md) - Configuration details
- [Examples](../../examples/) - Working code examples
- [Complete Setup Guide](../../src/bindings/java/docs/setup/COMPLETE_SETUP_GUIDE.md) - Full setup

### Tools
- [Geofabrik Downloads](https://download.geofabrik.de/) - OSM data source
- [Bounding Box Tool](https://boundingbox.klokantech.com/) - Find coordinates
- [OpenStreetMap Wiki](https://wiki.openstreetmap.org/) - OSM documentation

### Scripts
- `scripts/regions/download-region-osm.sh` - Download OSM data
- `scripts/regions/build-tiles.sh` - Build routing tiles
- `scripts/regions/validate-tiles.sh` - Validate tile structure
- `scripts/regions/setup-valhalla.sh` - Automated full setup

---

## 🎯 Quick Decision Tree

```
Need to add routing for a location?
│
├─ Is it in Asia/Africa/Europe/South America?
│  └─ Use: ADD_NEW_REGION_GUIDE.md
│
├─ Is it in the United States?
│  ├─ Single city (NYC, Denver, etc.)?
│  │  └─ Use: ADD_US_REGIONS_GUIDE.md (Metro Area Section)
│  │
│  └─ Entire state or multiple cities?
│     └─ Use: ADD_US_REGIONS_GUIDE.md (State Section)
│
└─ Is it in Canada/Australia/Other?
   └─ Use: ADD_NEW_REGION_GUIDE.md (Custom Region Section)
```

---

## 💡 Pro Tips

1. **Start Small:** Test with a small region first (city or small state)
2. **Use State Data:** For US cities, using full state data is often easier
3. **Cache OSM Data:** Keep downloaded OSM files for rebuilding
4. **Update Regularly:** OSM data updates weekly/daily
5. **Batch Processing:** Build multiple regions overnight
6. **Monitor Resources:** Watch RAM during tile building
7. **Test Thoroughly:** Verify routes before production deployment

---

**Need help?** Check the detailed guides above or see the [troubleshooting section](./ADD_NEW_REGION_GUIDE.md#troubleshooting) in the main guide.
