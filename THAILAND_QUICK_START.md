# Thailand Quick Start Guide

**5-minute guide to add Thailand routing to your Valhalla system.**

---

## ⚡ Quick Commands

```bash
# 1. Enable Thailand (already configured in regions.json)
# Edit config/regions/regions.json: Set thailand.enabled = true

# 2. Download OSM data (~500 MB, 5-10 min)
./scripts/regions/download-region-osm.sh thailand

# 3. Build tiles (~1.2 GB, 30-60 min)
./scripts/regions/build-tiles.sh thailand

# 4. Validate tiles
./scripts/regions/validate-tiles.sh thailand
```

**Total Time:** ~1 hour
**Disk Space:** ~2 GB (OSM data + tiles)
**RAM Required:** 8 GB minimum

---

## 💻 Use in Code

### Method 1: Environment Variable (Recommended)

```bash
export VALHALLA_TILES_DIR=/path/to/data/valhalla_tiles
```

```kotlin
import global.tada.valhalla.Actor

val actor = Actor.createWithExternalTiles("thailand")

val route = actor.route("""
{
  "locations": [
    {"lat": 13.7563, "lon": 100.5018},  // Bangkok Center
    {"lat": 13.9218, "lon": 100.6066}   // Don Mueang Airport
  ],
  "costing": "auto"
}
""")

println(route)
actor.close()
```

### Method 2: Direct Path

```kotlin
val actor = Actor.createWithTilePath(
    tileDir = "/path/to/data/valhalla_tiles/thailand",
    region = "thailand"
)

val route = actor.route(/* ... */)
actor.close()
```

---

## 🗺️ Test Coordinates

```kotlin
// Popular Thailand locations for testing
val locations = mapOf(
    "Bangkok City Center" to Pair(13.7563, 100.5018),
    "Suvarnabhumi Airport" to Pair(13.6900, 100.7501),
    "Chiang Mai" to Pair(18.7883, 98.9853),
    "Phuket" to Pair(7.8804, 98.3923),
    "Pattaya" to Pair(12.9236, 100.8825)
)
```

---

## 🐛 Common Issues

### "No route found"
- Check coordinates are within Thailand bounds (5.61-20.46 lat, 97.34-105.64 lon)
- Ensure tiles were built successfully

### "Out of memory during build"
```bash
# Add swap space
sudo dd if=/dev/zero of=/swapfile bs=1G count=8
sudo mkswap /swapfile
sudo swapon /swapfile
```

### "Tiles not found"
```bash
# Check environment variable
echo $VALHALLA_TILES_DIR

# Verify tiles exist
ls -la $VALHALLA_TILES_DIR/thailand/2/000/
```

---

## 📚 Full Documentation

For detailed information, see:
- **Complete Guide:** [docs/regions/ADD_NEW_REGION_GUIDE.md](./docs/regions/ADD_NEW_REGION_GUIDE.md)
- **Tile Configuration:** [EXTERNAL_TILES_GUIDE.md](./EXTERNAL_TILES_GUIDE.md)
- **Examples:** [examples/multiple-regions/](./examples/multiple-regions/)

---

**Ready to route in Thailand!** 🇹🇭
