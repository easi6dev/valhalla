# Singapore Setup Scripts

Collection of automated scripts for setting up Valhalla with Singapore region support.

## Scripts Overview

### 1. `setup-valhalla.sh` - Automated Setup ⭐

**One-command setup script** that automatically detects your system and installs everything.

```bash
# Full automated setup
./setup-valhalla.sh

# The script will:
# ✓ Auto-detect your OS (Windows/Linux/macOS)
# ✓ Detect available tools (Python/Docker)
# ✓ Install Valhalla using best method
# ✓ Download Singapore OSM data
# ✓ Build routing tiles
# ✓ Validate installation
# ✓ Run JNI tests
```

**Options:**
```bash
./setup-valhalla.sh --help           # Show help
./setup-valhalla.sh --method python  # Force Python method
./setup-valhalla.sh --method docker  # Force Docker method
./setup-valhalla.sh --region thailand # Setup Thailand instead
./setup-valhalla.sh --skip-install   # Skip installation (already have tools)
```

**Use this script if:**
- ✅ You're new to Valhalla
- ✅ You want automated setup
- ✅ You don't know which installation method to use

---

### 2. `download-region-osm.sh` - OSM Data Downloader

Downloads OpenStreetMap data for any region defined in `config/regions/singapore/regions.json`.

```bash
# Download Singapore data
./download-region-osm.sh singapore

# Download Thailand data
./download-region-osm.sh thailand
```

**What it does:**
- Reads region config from `config/regions/singapore/regions.json`
- Downloads OSM data from Geofabrik
- Saves to `data/osm/{region}-latest.osm.pbf`
- Verifies MD5 checksum
- Shows progress and file size

**Use this script if:**
- ✅ You only need to download OSM data
- ✅ You want to update OSM data
- ✅ You're setting up multiple regions

---

### 3. `build-tiles.sh` - Tile Builder

Builds Valhalla routing tiles from OSM data.

```bash
# Build Singapore tiles
./build-tiles.sh singapore

# Build Thailand tiles
./build-tiles.sh thailand
```

**What it does:**
- Reads OSM data from `data/osm/{region}-latest.osm.pbf`
- Generates routing graph tiles using `valhalla_build_tiles`
- Creates admin database using `valhalla_build_admins`
- Saves tiles to `data/valhalla_tiles/{region}/`
- Takes 10-20 minutes for Singapore

**Requirements:**
- Valhalla tools must be installed (`valhalla_build_tiles`, `valhalla_build_admins`)
- OSM data must be downloaded first

**Use this script if:**
- ✅ You want to build tiles only
- ✅ You've updated OSM data
- ✅ You're rebuilding tiles after config changes

---

### 4. `validate-tiles.sh` - Tile Validator

Validates that tiles were built correctly.

```bash
# Validate Singapore tiles
./validate-tiles.sh singapore
```

**What it does:**
- Runs 7 validation checks:
  1. ✅ Tile directory exists
  2. ✅ Tiles have correct format (.gph)
  3. ✅ Total size > 100 MB
  4. ✅ Tile hierarchy structure (2/xxx/xxx)
  5. ✅ Admin database exists
  6. ✅ Bounds check (coordinates)
  7. ✅ Sample tile integrity

**Use this script if:**
- ✅ You want to verify tiles are valid
- ✅ You're troubleshooting tile issues
- ✅ You want to check tile quality

---

## Quick Start Examples

### Example 1: First Time Setup (Automated)

```bash
# Run the automated setup script
./setup-valhalla.sh

# That's it! Everything is done automatically.
```

### Example 2: First Time Setup (Manual)

```bash
# Step 1: Install Valhalla tools
pip install pyvalhalla

# Step 2: Download OSM data
./download-region-osm.sh singapore

# Step 3: Build tiles
./build-tiles.sh singapore

# Step 4: Validate tiles
./validate-tiles.sh singapore

# Step 5: Test
cd ../../src/bindings/java
./gradlew test --tests "SingaporeRideHaulingTest"
```

### Example 3: Update OSM Data

```bash
# Download latest OSM data
./download-region-osm.sh singapore

# Rebuild tiles
./build-tiles.sh singapore

# Validate
./validate-tiles.sh singapore
```

### Example 4: Setup Multiple Regions

```bash
# Setup Singapore
./setup-valhalla.sh --region singapore

# Setup Thailand (after enabling in regions.json)
./setup-valhalla.sh --region thailand --skip-install
```

### Example 5: Use Docker Method

```bash
# Force Docker installation
./setup-valhalla.sh --method docker
```

### Example 6: Only Download and Build (Tools Already Installed)

```bash
# Skip installation step
./setup-valhalla.sh --skip-install --skip-test
```

---

## Installation Methods

The setup script supports two installation methods:

### Method A: Python (pyvalhalla) ⭐ Recommended

**Best for:** Windows, macOS, quick setup

```bash
pip install pyvalhalla
```

**Usage:**
```bash
python -m valhalla valhalla_build_tiles --help
```

**Pros:**
- ✅ Pre-built binaries
- ✅ Cross-platform
- ✅ Easy installation
- ✅ No compilation needed

**Cons:**
- ❌ Requires Python 3.8+

---

### Method B: Docker 🐳

**Best for:** Linux servers, isolated environments

```bash
docker pull ghcr.io/valhalla/valhalla:latest
```

**Usage:**
```bash
docker run -v $(pwd):/data ghcr.io/valhalla/valhalla:latest valhalla_build_tiles --help
```

**Pros:**
- ✅ Isolated environment
- ✅ No dependency conflicts
- ✅ Easy version management

**Cons:**
- ❌ Requires Docker
- ❌ Slower than native

---

## Configuration

Scripts read configuration from:

```
config/regions/singapore/
├── regions.json                 # Region definitions
├── valhalla-singapore.json      # Valhalla config
└── profiles/
    ├── auto_singapore.json      # Car routing profile
    └── motorcycle_singapore.json # Motorcycle profile
```

### Adding a New Region

1. Edit `config/regions/singapore/regions.json`:

```json
{
  "regions": {
    "malaysia": {
      "name": "Malaysia",
      "enabled": true,
      "osm_source": "https://download.geofabrik.de/asia/malaysia-latest.osm.pbf",
      "tile_dir": "data/valhalla_tiles/malaysia",
      "bounds": {
        "min_lat": 0.85,
        "max_lat": 7.36,
        "min_lon": 99.64,
        "max_lon": 119.27
      }
    }
  }
}
```

2. Run setup:

```bash
./setup-valhalla.sh --region malaysia
```

---

## Troubleshooting

### Script Permission Denied

```bash
chmod +x *.sh
```

### Python Not Found

Install Python 3.8+:
- Windows: https://www.python.org/downloads/
- Linux: `sudo apt install python3 python3-pip`
- macOS: `brew install python3`

### Docker Not Found

Install Docker:
- Windows/macOS: https://docs.docker.com/desktop/
- Linux: https://docs.docker.com/engine/install/

### Tiles Build Fails

Check logs:
```bash
./build-tiles.sh singapore 2>&1 | tee build.log
```

Common causes:
- Insufficient memory (need 4GB+)
- Corrupted OSM file (re-download)
- Disk space full

### Tests Fail

```bash
# Validate tiles first
./validate-tiles.sh singapore

# Check tile directory
ls -la data/valhalla_tiles/singapore/

# Rebuild if needed
./build-tiles.sh singapore
```

---

## Performance

### Build Times

| Region | OSM Size | Build Time | Tiles | Tile Size |
|--------|----------|------------|-------|-----------|
| Singapore | 230 MB | 10-20 min | 147 | 450 MB |
| Thailand | 850 MB | 30-60 min | 580 | 1.8 GB |
| Malaysia | 450 MB | 20-40 min | 320 | 1.1 GB |

### Disk Space Requirements

| Component | Size |
|-----------|------|
| Singapore OSM data | 230 MB |
| Singapore tiles | 450 MB |
| Admin database | 50 MB |
| **Total** | **730 MB** |

Add 20 GB if building all Southeast Asia regions.

---

## Support

For detailed documentation, see:
- [Complete Setup Guide](../../docs/singapore/SETUP_GUIDE.md)
- [Quick Start Guide](../../docs/singapore/SINGAPORE_QUICKSTART.md)
- [Troubleshooting Guide](../../docs/singapore/SETUP_GUIDE.md#troubleshooting)

For issues, see: https://github.com/valhalla/valhalla/issues
