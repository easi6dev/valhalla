# Valhalla Multi-Region Routing Documentation

Complete guide for adding and using geographic regions with Valhalla routing.

---

## 📚 Documentation Index

### Core Guides

| Guide | Description | Use When |
|-------|-------------|----------|
| **[Adding Regions Guide](./ADDING_REGIONS.md)** | Complete guide for adding any region (international & US) | Adding Thailand, Japan, New York, California, etc. |
| **[Multi-Region API Guide](./MULTI_REGION_API.md)** | API reference for using multiple regions in code | Building multi-region applications |

### Quick References

| Topic | Link |
|-------|------|
| **Quick Start** | [Jump to Quick Start](#-quick-start) |
| **Pre-configured Regions** | [Singapore, Thailand](#-pre-configured-regions) |
| **Finding OSM Data** | [Geofabrik Sources](#-finding-osm-data-sources) |
| **Testing** | [Test Examples](#-testing-regions) |
| **Troubleshooting** | [Common Issues](#-troubleshooting) |

---

## 🚀 Quick Start

### 1. Choose Your Region

| Region Type | Use Guide | Example |
|-------------|-----------|---------|
| **Asian/European/African countries** | [International Section](./ADDING_REGIONS.md#international-regions) | Thailand, Japan, Germany |
| **US cities/states** | [US Section](./ADDING_REGIONS.md#us-regions) | New York, California, Denver |
| **Custom region** | [Custom Section](./ADDING_REGIONS.md#custom-regions) | Any location |

### 2. Basic Workflow

```bash
# 1. Add to config/regions/regions.json
# 2. Download OSM data
./scripts/regions/download-region-osm.sh <region-name>

# 3. Build routing tiles
./scripts/regions/build-tiles.sh <region-name>

# 4. Validate tiles
./scripts/regions/validate-tiles.sh <region-name>
```

### 3. Use in Code

```kotlin
import global.tada.valhalla.Actor

// Set tile base directory (once)
export VALHALLA_TILES_DIR=/path/to/data/valhalla_tiles

// Use any region
val actor = Actor.createWithExternalTiles("region-name")
val route = actor.route("""
{
  "locations": [
    {"lat": lat1, "lon": lon1},
    {"lat": lat2, "lon": lon2}
  ],
  "costing": "auto"
}
""")
actor.close()
```

---

## 📋 Pre-Configured Regions

| Region | Status | Enable & Use |
|--------|--------|--------------|
| **Singapore** | ✅ Enabled | Ready to use immediately |
| **Thailand** | ⚠️ Disabled | Set `enabled: true` in config |

**All other regions** need to be added to `config/regions/regions.json`.

---

## 🗺️ Popular Region Examples

### Asia-Pacific
```bash
# Thailand (pre-configured, just enable)
./scripts/regions/download-region-osm.sh thailand
./scripts/regions/build-tiles.sh thailand

# Japan
./scripts/regions/download-region-osm.sh japan
./scripts/regions/build-tiles.sh japan

# Australia
./scripts/regions/download-region-osm.sh australia
./scripts/regions/build-tiles.sh australia
```

### United States
```bash
# New York State
./scripts/regions/download-region-osm.sh new-york
./scripts/regions/build-tiles.sh new-york

# California
./scripts/regions/download-region-osm.sh california
./scripts/regions/build-tiles.sh california

# Texas
./scripts/regions/download-region-osm.sh texas
./scripts/regions/build-tiles.sh texas
```

### Europe
```bash
# Germany
./scripts/regions/download-region-osm.sh germany
./scripts/regions/build-tiles.sh germany

# France
./scripts/regions/download-region-osm.sh france
./scripts/regions/build-tiles.sh france

# UK
./scripts/regions/download-region-osm.sh uk
./scripts/regions/build-tiles.sh uk
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
- 🌍 Global coverage with daily updates
- 📦 Pre-extracted regions
- ✅ Reliable mirrors

**Structure:**
```
https://download.geofabrik.de/
├── africa/
├── asia/
│   ├── thailand-latest.osm.pbf
│   ├── japan-latest.osm.pbf
│   └── ...
├── europe/
│   ├── germany-latest.osm.pbf
│   ├── france-latest.osm.pbf
│   └── ...
└── north-america/
    ├── us/
    │   ├── california-latest.osm.pbf
    │   ├── new-york-latest.osm.pbf
    │   └── ... (all 50 states)
    ├── canada/
    └── mexico/
```

### Finding Your Region

1. **Browse:** https://download.geofabrik.de/
2. **Navigate:** continent → country → state/region
3. **Copy URL:** ending in `-latest.osm.pbf`
4. **Add to:** `config/regions/regions.json`

---

## 🧪 Testing Regions

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

## 🐛 Troubleshooting

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
cat config/regions/regions.json | jq '.regions["region-name"].bounds'

# Validate tiles
./scripts/regions/validate-tiles.sh region-name
```

---

## 🎯 Quick Decision Tree

```
Need to add routing for a location?
│
├─ Is it in Asia/Africa/Europe/South America?
│  └─ Use: ADDING_REGIONS.md → International Section
│
├─ Is it in the United States?
│  ├─ Single city (NYC, Denver, etc.)?
│  │  └─ Use: ADDING_REGIONS.md → US Metro Section
│  │
│  └─ Entire state or multiple cities?
│     └─ Use: ADDING_REGIONS.md → US State Section
│
└─ Is it in Canada/Australia/Other?
   └─ Use: ADDING_REGIONS.md → Custom Region Section
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

## 📚 Additional Resources

### Documentation
- **[Complete Adding Regions Guide](./ADDING_REGIONS.md)** - Detailed step-by-step instructions
- **[Multi-Region API Guide](./MULTI_REGION_API.md)** - API reference and code examples
- **[Development Guide](../guides/DEVELOPMENT.md)** - Development setup
- **[Production Guide](../guides/PRODUCTION.md)** - Production deployment

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

**Need help?** Check the [complete guide](./ADDING_REGIONS.md) or open an issue on GitHub.
