# Valhalla JNI — Build & Run Guide

This guide covers the complete process of building and running the Valhalla routing service across all environments (local/WSL2, staging, production).

The process is split into four phases:

- **Phase 1 — Tile Generation** *(once per region)* — check for tiles, download OSM data, and build routing tiles. Tiles are portable across environments.
- **Phase 2 — Build JNI Library** — compile the native C++ bindings and produce `valhalla-jni.jar` (WSL2/Linux build path).
- **Phase 3 — Configure Tile Path** — tell the JAR where to find tiles at runtime.
- **Phase 4 — Build & Run HTTP Server** — build the `valhalla-server` Docker image and run the routing API.

> **New developer? Start at Phase 1, Step 1.0 — it checks whether tiles already exist before doing any work.**

---

## Repository Layout

```
valhalla/                          # JNI library (this repo)
├── docker/
│   ├── Dockerfile.prod              # Builds valhalla-jni.jar
│   ├── docker-compose.yml           # Production compose config
│   └── docker-compose.dev.yml       # Dev/local override
├── scripts/
│   └── regions/
│       ├── download-region-osm.sh   # Phase 1a: Download OSM data
│       ├── build-tiles.sh           # Phase 1b: Build routing tiles
│       └── validate-tiles.sh        # Phase 1c: Validate tile output
├── config/
│   └── regions/
│       └── regions.json             # Master region configuration
├── src/bindings/java/               # Kotlin/JNI source
└── data/
    ├── osm/                         # Downloaded OSM .pbf files
    └── valhalla_tiles/              # Built routing tiles (per region)
        └── singapore/

valhalla-server/                     # HTTP server (separate repo)
├── Dockerfile                       # Builds runnable valhalla-server.jar
├── src/main/kotlin/.../server/
│   ├── Application.kt               # Entry point, Ktor server setup
│   ├── Routing.kt                   # HTTP route handlers
│   └── Plugins.kt                   # Serialization, error pages, logging
└── build.gradle.kts
```

---

## Prerequisites

### All Environments

| Tool | Version | Purpose |
|------|---------|---------|
| Docker | 20.10+ | Build and run the service |
| Docker Compose | v2+ | Multi-container orchestration |
| WSL2 (Windows only) | Ubuntu 22.04+ | Linux environment on Windows |

### Phase 1 (Tile Generation) Only

| Tool | Install | Purpose |
|------|---------|---------|
| `jq` | `sudo apt-get install jq` | Parse `regions.json` config |
| `wget` | `sudo apt-get install wget` | Download OSM data |

> Tile generation scripts use Docker (`ghcr.io/valhalla/valhalla:latest`) internally — no native Valhalla installation required.

---

## Phase 1 — Tile Generation

Tiles are the pre-processed routing map data (~620 MB for Singapore). Without them the routing engine cannot calculate routes. Build once per region; tiles are portable across all environments.

### Step 1.0 — Check if tiles already exist (start here)

```bash
# Open WSL terminal first
wsl -d Ubuntu-22.04
cd /mnt/c/Users/<YOUR_USERNAME>/Workspace/valhalla

# Count .gph tile files — Singapore needs 700+
find data/valhalla_tiles/singapore -name "*.gph" 2>/dev/null | wc -l
```

- **700+ files** → tiles are ready, **skip to Phase 2**
- **0 files or directory missing** → continue to Step 1.1 below

**Quick validation (optional sanity check when tiles exist):**
```bash
./scripts/regions/validate-tiles.sh singapore
# Checks: file count, total size, hierarchy (0/ 1/ 2/ dirs), admin DB, bounds
```

Expected output when tiles are healthy:
```
[✓] Found 735 tile files
[✓] Total tile size: 620M
[✓] Found 3 tile level directories
[✓] All validation tests passed!
```

---

### Step 1.1 — Install prerequisites for tile building

```bash
sudo apt-get update
sudo apt-get install -y jq wget
# Docker is also required — install from https://docs.docker.com/engine/install/ubuntu/
# Tile build scripts use ghcr.io/valhalla/valhalla:latest via Docker internally
```

**Fix Windows line endings** (run once after `git checkout` on Windows — otherwise scripts fail with `bad interpreter: /bin/bash^M`):
```bash
find scripts/ src/bindings/java -name "*.sh" | xargs sed -i 's/\r$//'
```

---

### Step 1.2 — Download OSM Data

```bash
cd /mnt/c/Users/<YOUR_USERNAME>/Workspace/valhalla

./scripts/regions/download-region-osm.sh singapore
```

- Reads `osm_source` URL from `config/regions/regions.json`
- Downloads to `data/osm/singapore-latest.osm.pbf` (~230 MB)
- Verifies MD5 checksum; prompts before re-downloading if file exists
- Time: 5–15 min depending on connection speed

**Supported regions:**

| Region | Geofabrik source | Download size |
|--------|-----------------|---------------|
| `singapore` | Malaysia-Singapore-Brunei | ~230 MB |
| `thailand` | Thailand | ~700 MB |

---

### Step 1.3 — Build Routing Tiles

```bash
./scripts/regions/build-tiles.sh singapore --no-elevation
```

| Flag | Build time | Description |
|------|-----------|-------------|
| *(none)* | 60+ min | Include elevation data (hill/slope info) |
| `--no-elevation` | 15–20 min | Skip elevation — recommended for most use cases |
| `--clean` | — | Delete existing tiles before rebuilding |

When prompted `"Include elevation data? (y/N)"` → type `N` for faster builds.

- Builds tiles into `data/valhalla_tiles/singapore/`
- Builds admin boundaries database into `data/admin_data/admins.sqlite`
- Logs to `logs/tile-build-singapore-TIMESTAMP.log`

---

### Step 1.4 — Validate Tiles

```bash
./scripts/regions/validate-tiles.sh singapore
```

Checks: directory exists, `.gph` files present, size > 10 MB, level directories (0/ 1/ 2/), admin database, region bounds, sample tile readable.

---

### Copying Tiles to Another Environment

Tiles are plain files — copy them to any server and mount at runtime.

```bash
# rsync to a remote server
rsync -avz --progress \
  data/valhalla_tiles/singapore/ \
  user@server:/var/valhalla/tiles/singapore/

# Copy to AWS EFS / NFS mount
cp -r data/valhalla_tiles/singapore/ /mnt/efs/valhalla/tiles/singapore/
```

---

## Phase 2 — Build JNI Library

This phase compiles the native Valhalla C++ bindings and produces `valhalla-jni-1.0.0-SNAPSHOT.jar`. The JAR bundles all three native libraries inside it so your server only needs the `.jar`.

There are two build paths — choose based on your situation:

| Path | When to use |
|------|-------------|
| **2A — WSL/Linux direct build** | Local development, CI on Linux, first-time setup |
| **2B — Docker build** | Reproducible builds, no GCC requirement on host |

---

### Step 2A — WSL/Linux Direct Build

#### Step 2A.1 — Install build dependencies

```bash
sudo apt-get update
sudo apt-get install -y \
  build-essential cmake pkg-config \
  libboost-all-dev libprotobuf-dev protobuf-compiler \
  libsqlite3-dev libspatialite-dev libgeos-dev \
  libcurl4-openssl-dev zlib1g-dev liblz4-dev \
  openjdk-17-jdk

# Set JAVA_HOME — add to ~/.bashrc to make permanent
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
export PATH=$JAVA_HOME/bin:$PATH

# Verify
java -version    # must be 17+
cmake --version  # must be 3.22+
```

#### Step 2A.2 — Run the JNI build script

```bash
cd /mnt/c/Users/<YOUR_USERNAME>/Workspace/valhalla/src/bindings/java

# SKIP_APT_INSTALL=1 skips reinstalling packages (they're already installed from 2A.1)
SKIP_APT_INSTALL=1 ./build-jni-bindings.sh
```

**What this script does:**
1. Verifies `libvalhalla.so.3.6.2` exists in `src/main/resources/lib/linux-amd64/`
2. Creates symlinks: `libvalhalla.so.3` and `libvalhalla.so`
3. Runs CMake to compile `libvalhalla_jni.so` from C++ source
4. Copies `libvalhalla_jni.so` into `src/main/resources/lib/linux-amd64/`
5. Runs `./gradlew clean build` to package the JAR

Expected final output:
```
========================================
✓ Build Complete!
========================================
  Main JAR:    .../build/libs/valhalla-jni-1.0.0-SNAPSHOT.jar
  JNI Library: .../src/main/resources/lib/linux-amd64/libvalhalla_jni.so
```

**Verify the built files:**
```bash
# JAR should be ~15 MB and contain embedded .so files
ls -lh build/libs/valhalla-jni-*.jar

# Native libraries in resources
ls -lh src/main/resources/lib/linux-amd64/
# libprotobuf-lite.so.23    ~700 KB
# libvalhalla.so.3.6.2       ~13 MB
# libvalhalla.so.3           symlink
# libvalhalla.so             symlink
# libvalhalla_jni.so        ~165 KB

# Confirm .so files are embedded inside the JAR
jar tf build/libs/valhalla-jni-1.0.0-SNAPSHOT.jar | grep "\.so"
```

---

### Step 2B — Docker Build (alternative)

Run from the `valhalla` project root:

```bash
cd /mnt/c/Users/<YOUR_USERNAME>/Workspace/valhalla

docker build \
  --progress=plain \
  -f docker/Dockerfile.prod \
  -t valhalla-jni:latest .
```

**What the build does (multi-stage):**

| Stage | Base | Actions |
|-------|------|---------|
| Builder | `ubuntu:24.04` | Installs GCC 13, CMake, OpenJDK 17; compiles `libvalhalla_jni.so`; builds JAR via Gradle |
| Runtime | `eclipse-temurin:17-jre-noble` | Minimal JRE + Valhalla runtime libs; copies `valhalla-jni.jar` |

**Extract the JAR from the built image:**

```bash
docker create --name jni-extract valhalla-jni:latest
docker cp jni-extract:/app/valhalla-jni.jar \
  src/bindings/java/build/libs/valhalla-jni-1.0.0-SNAPSHOT.jar
docker rm jni-extract
```

> `valhalla-jni.jar` is a **library JAR** — it has no main class and cannot be run standalone. It is used as a dependency by `valhalla-server`.

---

## Phase 3 — Configure Tile Path

The JAR does **not** bundle tiles (they are hundreds of MB). You must tell the JAR where to find them at runtime. The `RegionConfigFactory` resolves the tile directory in this priority order:

```
Priority 1 — Environment variable:   VALHALLA_TILE_DIR=/path/to/tiles
Priority 2 — JVM system property:    -Dvalhalla.tile.dir=/path/to/tiles
Priority 3 — Direct code parameter:  Actor.createWithTilePath("/path/to/tiles/singapore")
Priority 4 — Default (dev only):     data/valhalla_tiles/  (relative to working directory)
```

The region subdirectory is **appended automatically** when using options 1 or 2:
```
VALHALLA_TILE_DIR=/var/valhalla/tiles  +  region="singapore"
→ loads tiles from /var/valhalla/tiles/singapore/
```

### Option A — Environment variable (recommended)

```bash
# Linux / Docker
export VALHALLA_TILE_DIR=/var/valhalla/tiles
```

```kotlin
// In code — region subdir appended automatically
val actor = Actor.createWithExternalTiles("singapore")
// → reads: /var/valhalla/tiles/singapore/
```

In `docker-compose.yml`:
```yaml
services:
  valhalla-server:
    environment:
      - VALHALLA_TILE_DIR=/var/valhalla/tiles
    volumes:
      - /host/path/to/tiles:/var/valhalla/tiles:ro
```

### Option B — JVM system property

```bash
java -Dvalhalla.tile.dir=/var/valhalla/tiles -jar your-server.jar
```

### Option C — Direct path in code

```kotlin
// Absolute path — clearest for production
val actor = Actor.createWithTilePath("/var/valhalla/tiles/singapore", "singapore")

// Or via region factory
val actor = Actor.createForRegion("singapore", "/var/valhalla/tiles/singapore")
```

### Option D — Default path (development only)

No environment variable needed when running from the project root:
```kotlin
val actor = Actor.createForRegion("singapore")
// Resolves to: <working-dir>/data/valhalla_tiles/singapore/
```

### Expected tile directory structure

```
/var/valhalla/tiles/
└── singapore/              ← VALHALLA_TILE_DIR/singapore
    ├── 0/                  ← level 0: low detail, large areas
    ├── 1/                  ← level 1: medium detail
    └── 2/                  ← level 2: high detail (streets)
        ├── 000/
        │   ├── 456.gph
        │   └── 457.gph
        └── ...
```

---

## Phase 4 — Build & Run HTTP Server

The `valhalla-server` project (`../valhalla-server/`) is the runnable HTTP routing API. It depends on `valhalla-jni.jar` from Phase 2.

**Endpoints:**
- `GET  /health` — health check
- `POST /route` — turn-by-turn routing
- `POST /matrix` — time/distance matrix
- `POST /isochrone` — reachability polygons
- `POST /trace-route` — GPS map-matching

### Step 4.1 — Build the Server Docker Image

The `valhalla-server` Dockerfile picks up the pre-built `valhalla-jni.jar` automatically:

```bash
cd /path/to/valhalla-server

docker build \
  --progress=plain \
  -t valhalla-server:latest .
```

**Build argument** (if JAR is at a non-default path):
```bash
docker build \
  --build-arg VALHALLA_JNI_JAR=/custom/path/valhalla-jni-1.0.0-SNAPSHOT.jar \
  -t valhalla-server:latest .
```

**Tagging for environments:**
```bash
docker build -t valhalla-server:dev .
docker build -t valhalla-server:staging .
docker build -t valhalla-server:1.0.0 .
```

---

### Step 4.2 — Run the Server

#### Local / WSL2 (Dev)

```bash
# Fix CRLF line endings (WSL2 only, run once)
sed -i 's/\r//' /path/to/valhalla/docker/docker-compose.yml \
                /path/to/valhalla/docker/docker-compose.dev.yml

# Run with local tiles
docker run -d \
  --name valhalla-server-dev \
  -p 8080:8080 \
  -v /path/to/valhalla/data/valhalla_tiles/singapore:/var/valhalla/tiles:ro \
  -e VALHALLA_TILE_DIR=/var/valhalla/tiles \
  -e VALHALLA_REGION=singapore \
  -e PORT=8080 \
  valhalla-server:dev

# View logs
docker logs -f valhalla-server-dev
```

#### Staging / Production

```bash
docker run -d \
  --name valhalla-server \
  -p 8080:8080 \
  -v /var/valhalla/tiles:/var/valhalla/tiles:ro \
  -e VALHALLA_TILE_DIR=/var/valhalla/tiles \
  -e VALHALLA_REGION=singapore \
  -e PORT=8080 \
  --restart unless-stopped \
  valhalla-server:latest
```

---

### Step 4.3 — Verify the Service

```bash
# Health check
curl http://localhost:8080/health
# {"status":"ok"}

# Route request (Singapore)
curl -s -X POST http://localhost:8080/route \
  -H "Content-Type: application/json" \
  -d '{
    "locations": [
      {"lat": 1.2855, "lon": 103.8565},
      {"lat": 1.3000, "lon": 103.8700}
    ],
    "costing": "auto"
  }' | head -c 500
```

---

## Environment Variable Reference

| Variable | Default | Description |
|----------|---------|-------------|
| `VALHALLA_TILE_DIR` | `data/valhalla_tiles` | Path to routing tiles directory |
| `VALHALLA_REGION` | `singapore` | Active region |
| `VALHALLA_ENV` | `prod` | Environment name (`dev`, `staging`, `prod`) |
| `PORT` | `8080` | HTTP server port |
| `JAVA_OPTS` | `-Xmx2g -Xms512m -XX:+UseG1GC` | JVM heap and GC options |

---

## Resource Requirements

| Environment | CPU | Memory | Disk (tiles) |
|-------------|-----|--------|--------------|
| Local/Dev | 2 cores | 2–4 GB | ~500MB/region |
| Staging | 2 cores | 4 GB | ~500MB/region |
| Production | 4 cores | 8 GB | ~500MB/region |

---

## Day-to-Day Commands

```bash
# Stop server
docker stop valhalla-server-dev

# Restart server
docker restart valhalla-server-dev

# View logs (last 100 lines)
docker logs --tail 100 valhalla-server-dev

# Shell into running container (debug)
docker exec -it valhalla-server-dev bash

# Check resource usage
docker stats valhalla-server-dev

# Rebuild after server code changes (JAR already built)
docker build -t valhalla-server:dev /path/to/valhalla-server && \
docker run -d --name valhalla-server-dev -p 8080:8080 \
  -v /path/to/valhalla/data/valhalla_tiles/singapore:/var/valhalla/tiles:ro \
  -e VALHALLA_TILE_DIR=/var/valhalla/tiles \
  -e VALHALLA_REGION=singapore \
  valhalla-server:dev
```

---

## Updating Tiles

To refresh routing tiles with latest OSM data without rebuilding either Docker image:

```bash
# 1. Download latest OSM data (prompts to re-download if exists)
./scripts/regions/download-region-osm.sh singapore

# 2. Rebuild tiles
./scripts/regions/build-tiles.sh singapore --clean --no-elevation

# 3. Validate
./scripts/regions/validate-tiles.sh singapore

# 4. Restart server (picks up new tiles from mounted volume)
docker restart valhalla-server-dev
```

---

## Adding a New Region

1. Add the region to `config/regions/regions.json` with `osm_source`, `bounds`, `tile_dir`, `enabled: true`
2. Run the tile pipeline:
   ```bash
   ./scripts/regions/download-region-osm.sh thailand
   ./scripts/regions/build-tiles.sh thailand --no-elevation
   ./scripts/regions/validate-tiles.sh thailand
   ```
3. Start the server pointing at the new tile directory:
   ```bash
   docker run -d \
     -v /path/to/tiles/thailand:/var/valhalla/tiles:ro \
     -e VALHALLA_TILE_DIR=/var/valhalla/tiles \
     -e VALHALLA_REGION=thailand \
     -p 8080:8080 \
     valhalla-server:latest
   ```

---

## Run Tests (Standalone — no server needed)

After Phase 2 completes you can verify the JNI library and tiles work correctly without starting the server:

```bash
cd /mnt/c/Users/<YOUR_USERNAME>/Workspace/valhalla/src/bindings/java

# Run Singapore ride-hailing test suite (11 route scenarios)
./gradlew test --tests "global.tada.valhalla.singapore.SingaporeRideHaulingTest"

# Run all tests
./gradlew test

# Run with verbose output (shows route distances and latencies)
./gradlew test --info
```

Tests use `data/valhalla_tiles/singapore/` by default (the project-root-relative path). To override:
```bash
VALHALLA_TILE_DIR=/custom/path ./gradlew test
```

View HTML test report in Windows:
```bash
explorer.exe "$(wslpath -w build/reports/tests/test/index.html)"
```

Expected test results:
```
test 01 - Service Status                              PASSED   (~2ms)
test 02 - Short Route (Raffles Place → Marina Bay)    PASSED   (~3ms)
test 03 - Medium Route (Orchard Rd → East Coast)      PASSED   (~5ms)
test 04 - Long Route (Marina Bay → Changi Airport)    PASSED   (~8ms)
test 05 - Expressway Route (Jurong → Changi via PIE)  PASSED
test 06 - Multi-Waypoint Route                        PASSED
test 07 - Driver Dispatch Matrix (1×5)                PASSED
test 08 - Motorcycle Routing                          PASSED
test 09 - Isochrone (10/20/30 min zones)              PASSED
test 10 - Location API (nearest road lookup)          PASSED
test 11 - Performance (100 iterations)                PASSED
BUILD SUCCESSFUL
```

---

## Scripts Summary

| Script | Location | Purpose | Run when |
|--------|----------|---------|----------|
| `download-region-osm.sh` | `scripts/regions/` | Downloads OSM map data (~230 MB) from Geofabrik | Tiles are missing |
| `build-tiles.sh` | `scripts/regions/` | Converts OSM `.pbf` into Valhalla `.gph` routing tiles | Tiles are missing |
| `validate-tiles.sh` | `scripts/regions/` | Checks tile count, size, hierarchy and file integrity | After tile build; verify existing tiles |
| `setup-valhalla.sh` | `scripts/regions/` | All-in-one: auto-installs + downloads + builds + tests | Fully automated setup on fresh machine |
| `build-jni-bindings.sh` | `src/bindings/java/` | Compiles `libvalhalla_jni.so` via CMake + builds Gradle JAR | First setup or after C++ source changes |
| `bundle-production-jar.sh` | `src/bindings/java/` | Assembles production JAR with all native libs bundled | Before deploying the JAR to a server |

### Quick cheatsheet

```bash
# ── One-time: fix Windows line endings after git checkout on Windows ──────────
find scripts/ src/bindings/java -name "*.sh" | xargs sed -i 's/\r$//'

# ── Phase 1: Check tiles ──────────────────────────────────────────────────────
find data/valhalla_tiles/singapore -name "*.gph" | wc -l   # expect 700+
./scripts/regions/validate-tiles.sh singapore

# ── Phase 1: Build tiles from scratch ────────────────────────────────────────
./scripts/regions/download-region-osm.sh singapore
./scripts/regions/build-tiles.sh singapore --no-elevation

# ── Phase 2A: Build JNI + JAR (WSL) ──────────────────────────────────────────
cd src/bindings/java
SKIP_APT_INSTALL=1 ./build-jni-bindings.sh

# ── Phase 2B: Build JNI + JAR (Docker) ───────────────────────────────────────
docker build --progress=plain -f docker/Dockerfile.prod -t valhalla-jni:latest .
docker create --name jni-extract valhalla-jni:latest
docker cp jni-extract:/app/valhalla-jni.jar src/bindings/java/build/libs/valhalla-jni-1.0.0-SNAPSHOT.jar
docker rm jni-extract

# ── Run tests ─────────────────────────────────────────────────────────────────
cd src/bindings/java
./gradlew test

# ── Phase 4: Run server (Docker) ─────────────────────────────────────────────
docker run -d --name valhalla-server -p 8080:8080 \
  -v /mnt/c/Users/<USERNAME>/Workspace/valhalla/data/valhalla_tiles/singapore:/var/valhalla/tiles:ro \
  -e VALHALLA_TILE_DIR=/var/valhalla/tiles \
  -e VALHALLA_REGION=singapore \
  valhalla-server:latest
```

---

## Troubleshooting

| Problem | Cause | Fix |
|---------|-------|-----|
| `Unable to locate package gcc-13` | Ubuntu 22.04 base | Dockerfile uses Ubuntu 24.04 — ensure you're using the current `Dockerfile.prod` |
| `bad interpreter: /bin/bash^M` | Windows CRLF in shell scripts | `find scripts/ src/bindings/java -name "*.sh" \| xargs sed -i 's/\r$//'` |
| Script runs but produces no output | Script was 0 bytes (sed ran from wrong shell) | `git checkout <script-path>` then re-run sed from WSL |
| `\r': command not found` in WSL | Windows CRLF line endings | `find scripts/ src/bindings/java -name "*.sh" \| xargs sed -i 's/\r$//'` |
| `UID 1000 is not unique` | Base image already uses UID 1000 | Fixed in current Dockerfile — `useradd` has no `-u 1000` |
| `No tile files found` | Tile build incomplete | Run `validate-tiles.sh`; re-run `build-tiles.sh` if needed |
| `Cannot connect to Docker daemon` | Docker Desktop not running | Start Docker Desktop on Windows before using WSL2 |
| Port 8080 already in use | Another service on 8080 | Change port: `-p 8081:8080` |
| Server exits immediately | Missing tiles or wrong path | Verify `VALHALLA_TILE_DIR` matches the mounted volume path |
| `valhalla-jni.jar not found` during server build | Phase 2 not complete | Run Phase 2 to extract `valhalla-jni-1.0.0-SNAPSHOT.jar` first |
| `Failed to initialize Valhalla Actor` | Tiles missing or corrupted | Run `validate-tiles.sh`; check `VALHALLA_REGION` matches tile directory name |
| `libvalhalla.so.3.6.2 not found` | Pre-built Valhalla lib missing from resources | `ls src/bindings/java/src/main/resources/lib/linux-amd64/` — must contain `libvalhalla.so.3.6.2` |
| `UnsatisfiedLinkError: no valhalla_jni` | JAR built without embedded `.so` | `jar tf build/libs/valhalla-jni-*.jar \| grep .so` — if empty, run `./gradlew clean build -x test` |
| `Tile directory does not exist` | Wrong `VALHALLA_TILE_DIR` or tiles not built | `echo $VALHALLA_TILE_DIR` and verify path; run `validate-tiles.sh` |
| Tests fail: `Location is unreachable` | Coordinates outside Singapore bounds or tiles incomplete | Singapore bounds: lat 1.15–1.48, lon 103.6–104.0; re-run `validate-tiles.sh` |
