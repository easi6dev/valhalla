# Valhalla JNI Complete Setup Guide

Comprehensive guide for setting up, building, and configuring Valhalla JNI bindings with IDE integration.

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Installation Methods](#installation-methods)
3. [Automated Setup](#automated-setup)
4. [Manual Build (WSL2/Linux)](#manual-build-wsl2linux)
5. [IDE Setup](#ide-setup)
6. [Building Singapore Tiles](#building-singapore-tiles)
7. [Testing](#testing)
8. [Troubleshooting](#troubleshooting)
9. [Production Deployment](#production-deployment)

---

## Prerequisites

### System Requirements

**Hardware:**
- **Disk Space**: 20 GB minimum (OSM data + tiles + builds)
- **RAM**: 8 GB minimum, 16 GB recommended
- **CPU**: Multi-core processor (4+ cores recommended)

**Software:**
- **JDK 17+** (Java Development Kit)
- **Git** (for version control)

### Platform-Specific Requirements

**Windows:**
- WSL2 (Windows Subsystem for Linux) with Ubuntu 22.04
- Python 3.8+ (for pyvalhalla method) OR Docker

**Linux:**
- Ubuntu 20.04+ or equivalent
- Python 3.8+ OR Docker

**macOS:**
- Xcode Command Line Tools
- Python 3.8+ OR Docker

### Verify Prerequisites

```bash
# Check JDK version
java -version
# Required: version 17 or higher

# Check Python version (for pyvalhalla method)
python --version
# Required: Python 3.8 or higher

# Check Docker (for Docker method)
docker --version
# Required: Docker 20.10 or higher

# Check WSL2 (Windows only - run in PowerShell)
wsl --list --verbose
# Should show Ubuntu-22.04 with VERSION 2
```

---

## Installation Methods

Valhalla provides three installation methods for tile building tools:

### Method A: Python Valhalla (pyvalhalla) ⭐ Recommended

**Best for:** Windows, macOS, quick setup

**Pros:**
- ✅ Pre-built binaries included
- ✅ No compilation required
- ✅ Cross-platform support
- ✅ Easy installation via pip
- ✅ Fastest setup (5 minutes)

**Cons:**
- ❌ Requires Python 3.8+
- ❌ Limited to supported platforms (Windows x64, Linux x64, macOS ARM64)

**Installation:**
```bash
pip install pyvalhalla

# Verify installation
python -m valhalla --version
```

**Usage:**
```bash
# Build tiles
python -m valhalla valhalla_build_tiles -c config.json

# Build admin database
python -m valhalla valhalla_build_admins -c config.json
```

---

### Method B: Docker 🐳

**Best for:** Linux servers, isolated environments, CI/CD

**Pros:**
- ✅ Isolated environment
- ✅ No dependency conflicts
- ✅ Works on all platforms with Docker
- ✅ Easy version management

**Cons:**
- ❌ Requires Docker installation
- ❌ Slower than native binaries
- ❌ Larger disk usage

**Installation:**
```bash
# Pull Valhalla Docker image
docker pull ghcr.io/valhalla/valhalla:latest

# Verify installation
docker run ghcr.io/valhalla/valhalla:latest --version
```

**Usage:**
```bash
# Build tiles (mount current directory as /data)
docker run -v $(pwd):/data ghcr.io/valhalla/valhalla:latest \
  valhalla_build_tiles -c /data/config.json
```

---

### Method C: Build from Source 🛠️

**Best for:** Custom modifications, unsupported platforms, JNI development

**When to use:**
- Modifying Valhalla C++ code
- Building JNI library for unsupported platforms
- Need latest development features
- Contributing to Valhalla project

**Pros:**
- ✅ Full control over build
- ✅ Latest development features
- ✅ Platform-specific optimizations
- ✅ Required for JNI development

**Cons:**
- ❌ Complex setup
- ❌ Requires C++ compiler and dependencies
- ❌ Long compilation time (30-60 minutes)

**See:** [Manual Build (WSL2/Linux)](#manual-build-wsl2linux) section below

---

## Automated Setup

### Quick Start (Recommended)

The automated setup script handles everything:

```bash
# Navigate to project root
cd valhalla

# Run automated setup
./scripts/regions/setup-valhalla.sh
```

**What it does:**
1. ✅ Detects your OS and environment
2. ✅ Recommends best installation method
3. ✅ Installs Valhalla tools
4. ✅ Downloads Singapore OSM data (230 MB)
5. ✅ Builds routing tiles (450 MB)
6. ✅ Validates tile integrity
7. ✅ Runs JNI tests

**Estimated time:** 20-40 minutes (depending on network speed)

### Advanced Options

```bash
# Force specific installation method
./scripts/regions/setup-valhalla.sh --method python
./scripts/regions/setup-valhalla.sh --method docker

# Skip specific steps
./scripts/regions/setup-valhalla.sh --skip-install    # Tools already installed
./scripts/regions/setup-valhalla.sh --skip-download   # OSM data exists
./scripts/regions/setup-valhalla.sh --skip-build      # Tiles already built

# Setup different region
./scripts/regions/setup-valhalla.sh --region thailand

# Show all options
./scripts/regions/setup-valhalla.sh --help
```

---

## Manual Build (WSL2/Linux)

This section covers building Valhalla JNI library from source. Required for:
- JNI development
- Unsupported platforms
- Custom modifications

### Step 1: Open Terminal

**Windows (WSL2):**
```bash
# From Windows PowerShell or CMD
wsl -d Ubuntu-22.04

# You should see a prompt like:
# username@hostname:/mnt/c/Users/...$
```

**Linux/macOS:**
```bash
# Use your regular terminal
```

### Step 2: Navigate to Project

```bash
# Set project path
export VALHALLA_DIR="/mnt/c/Users/<YOUR_USERNAME>/Workspace/valhalla"  # Windows WSL
# or
export VALHALLA_DIR="$HOME/workspace/valhalla"  # Linux/macOS

# Navigate
cd $VALHALLA_DIR
```

### Step 3: Update Package Lists

```bash
sudo apt-get update
```

**Note:** You may see warnings about PPAs - these can be safely ignored.

### Step 4: Install Build Dependencies

```bash
sudo apt-get install -y \
  build-essential \
  cmake \
  git \
  pkg-config \
  libboost-all-dev \
  libcurl4-openssl-dev \
  libprotobuf-dev \
  protobuf-compiler \
  libsqlite3-dev \
  liblz4-dev \
  zlib1g-dev \
  openjdk-17-jdk-headless
```

**If installation fails** (network errors are common), simply retry:
```bash
sudo apt-get install -y <package list>
```

### Step 5: Install Full JDK 17

The headless JDK is missing AWT libraries required for JNI. Install the full JDK:

```bash
sudo apt-get install -y openjdk-17-jdk
```

**Why?** CMake requires `JAVA_AWT_LIBRARY` and `JAVA_AWT_INCLUDE_PATH` for JNI bindings.

### Step 6: Upgrade to GCC 13

Valhalla uses C++20 features (`<format>` header) that require GCC 13+:

```bash
# Add Ubuntu Toolchain PPA
sudo apt-get install -y software-properties-common
sudo add-apt-repository -y ppa:ubuntu-toolchain-r/test
sudo apt-get update

# Install GCC 13 and G++ 13
sudo apt-get install -y gcc-13 g++-13

# Set GCC 13 as default
sudo update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-13 100
sudo update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-13 100

# Verify installation
gcc --version
# Expected: gcc (Ubuntu 13.1.0-8ubuntu1~22.04) 13.1.0
```

**Why?** GCC 11 (default in Ubuntu 22.04) doesn't support C++20 `<format>` header.

### Step 7: Verify Tool Versions

```bash
cmake --version      # Expected: 3.22.1 or higher
javac -version       # Expected: javac 17.x.x or higher
gcc --version        # Expected: gcc 13.x.x or higher
```

### Step 8: Set Environment Variables

```bash
# Set JAVA_HOME for JDK 17
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64

# Suppress GCC warnings treated as errors
export CXXFLAGS="-Wno-error=maybe-uninitialized"

# Verify JAVA_HOME
echo $JAVA_HOME
ls $JAVA_HOME/include/jni.h    # Should show the jni.h file
```

**Why suppress warnings?** GCC 13 is stricter and flags some uninitialized variables as errors when `-Werror` is enabled.

### Step 9: Clean Previous Builds (If Needed)

```bash
# Remove build directory
rm -rf build

# Or with sudo if permission denied (from Docker builds)
sudo rm -rf build
```

### Step 10: Configure CMake Build

```bash
cmake -B build \
  -DCMAKE_BUILD_TYPE=Release \
  -DENABLE_PYTHON_BINDINGS=OFF \
  -DENABLE_TOOLS=OFF \
  -DENABLE_SERVICES=OFF \
  -DENABLE_DATA_TOOLS=OFF \
  -DENABLE_JAVA_BINDINGS=ON \
  -DBUILD_SHARED_LIBS=ON
```

**Expected Output:**
```
-- The C compiler identification is GNU 13.1.0
-- The CXX compiler identification is GNU 13.1.0
...
-- Configuring done
-- Generating done
-- Build files have been written to: .../valhalla/build
```

**Note:** "Configuring done" may take 10-30 seconds - this is normal.

**Common Error:** "JNI not found, skipping Java bindings"
- **Solution:** Ensure full JDK 17 is installed and `JAVA_HOME` is set correctly

### Step 11: Build JNI Library

```bash
cmake --build build --target valhalla_jni -j4
```

**Parameters:**
- `--target valhalla_jni`: Build only JNI library (faster)
- `-j4`: Use 4 parallel jobs (adjust based on CPU cores)

**Expected Output:**
```
[  0%] Building CXX object src/baldr/CMakeFiles/valhalla.dir/admin.cc.o
[  1%] Building CXX object src/baldr/CMakeFiles/valhalla.dir/access_restriction.cc.o
...
[ 97%] Building CXX object src/bindings/java/CMakeFiles/valhalla_jni.dir/src/main/cpp/valhalla_jni.cc.o
[100%] Linking CXX shared library libs/native/libvalhalla_jni.so
[100%] Built target valhalla_jni
```

**Build Time:** 5-15 minutes (depending on hardware)

**Warnings:** You may see warnings like:
```
warning: 'first_bridge_index' may be used uninitialized [-Wmaybe-uninitialized]
```
These are acceptable (prevented from being errors by `CXXFLAGS`).

### Step 12: Verify Build

```bash
# Check if JNI library was created
ls -lh build/src/bindings/java/libs/native/libvalhalla_jni.so
```

**Expected Output:**
```
-rwxrwxrwx 1 user user 165K Feb 11 12:11 build/src/bindings/java/libs/native/libvalhalla_jni.so
```

**If you see this file, the build was successful! ✅**

### Step 13: Copy Library to Java Resources

```bash
# Copy built library to Java resources directory
cp build/src/bindings/java/libs/native/libvalhalla_jni.so \
   src/bindings/java/src/main/resources/lib/linux-amd64/

# Verify the copy
ls -lh src/bindings/java/src/main/resources/lib/linux-amd64/libvalhalla_jni.so
```

---

## IDE Setup

### IntelliJ IDEA (Recommended for Java/Kotlin)

#### Method 1: Open as Gradle Project

**Best for:** Primarily working with Java/Kotlin bindings

**Steps:**

1. **Open the Java subproject:**
   ```
   File → Open → Navigate to: src/bindings/java → OK
   ```

2. **Wait for Gradle sync** (2-5 minutes)
   - IntelliJ will detect `build.gradle.kts` automatically
   - Dependencies will be downloaded

3. **Verify project structure:**
   ```
   java-bindings
   ├── src
   │   ├── main
   │   │   ├── kotlin
   │   │   │   └── global.tada.valhalla
   │   │   │       ├── Actor.kt
   │   │   │       └── config/
   │   │   └── resources
   │   └── test
   │       └── kotlin
   │           └── global.tada.valhalla.singapore
   ├── build.gradle.kts
   └── gradlew
   ```

4. **Configure JDK:**
   ```
   File → Project Structure → Project
     - SDK: Select JDK 17 or higher
     - Language level: 17
   ```

#### Method 2: Open Root with Gradle Support

**Best for:** Seeing both C++ and Java/Kotlin code

**Steps:**

1. **Open root directory:**
   ```
   File → Open → valhalla (root directory) → OK
   ```

2. **Import Gradle module:**
   ```
   File → Project Structure → Modules → + → Import Module
     - Select: src/bindings/java
     - Import module from external model → Gradle
     - Finish
   ```

3. **Mark directories:**
   - Right-click directories and mark as:
     - `src/bindings/java/src/main/kotlin` → Sources Root
     - `src/bindings/java/src/test/kotlin` → Test Sources Root
     - `config` → Resources Root
     - `build` → Excluded
     - `data` → Excluded
     - `docs` → Excluded

#### Running Tests in IntelliJ

**Method 1: Run all tests**
1. Open `SingaporeRideHaulingTest.kt`
2. Click green play button (▶) next to class name
3. Select "Run 'SingaporeRideHaulingTest'"

**Method 2: Run specific test**
1. Click green play button (▶) next to test function
2. Select "Run 'test 02 - Short Route...'"

**Method 3: Via Gradle**
```
View → Tool Windows → Gradle
  - valhalla → java-bindings → Tasks → verification → test
  - Double-click to run
```

#### Building in IntelliJ

```
Build → Build Project (Ctrl+F9)
Build → Rebuild Project
```

**Via Gradle:**
```
View → Tool Windows → Gradle
  - clean → Run
  - build → jar → Run
```

---

### Visual Studio Code

#### Prerequisites

- **VS Code 1.80+**
- **Extension Pack for Java** (Microsoft)
- **Kotlin Language** extension
- **Gradle for Java** extension

#### Setup Steps

1. **Open project:**
   ```
   File → Open Folder → valhalla
   ```

2. **Install extensions:**
   - Press `Ctrl+Shift+X`
   - Install:
     - Extension Pack for Java
     - Kotlin Language
     - Gradle for Java

3. **Configure Java:**
   - Press `Ctrl+Shift+P`
   - Type: "Java: Configure Java Runtime"
   - Ensure JDK 17+ is selected

4. **Open Java subproject:**
   ```
   File → Add Folder to Workspace → src/bindings/java
   ```

5. **Gradle sync:**
   - Press `Ctrl+Shift+P`
   - Type: "Gradle: Refresh Gradle Project"

#### Running Tests in VS Code

**Method 1: Test Explorer**
1. Open Testing view (test tube icon)
2. Expand `SingaporeRideHaulingTest`
3. Click play button to run

**Method 2: Code Lens**
1. Open `SingaporeRideHaulingTest.kt`
2. Click "Run Test" above each test function

**Method 3: Terminal**
```bash
cd src/bindings/java
./gradlew test
```

---

### CLion

#### Prerequisites

- **CLion 2023.1+**
- **JDK 17+** for Gradle support

#### Setup Steps

1. **Open as CMake project:**
   ```
   File → Open → valhalla/CMakeLists.txt → Open as Project
   ```

2. **Configure CMake:**
   ```
   File → Settings → Build, Execution, Deployment → CMake
     - Build directory: build
     - CMake options: -DENABLE_TOOLS=ON -DENABLE_DATA_TOOLS=ON
   ```

3. **Add Gradle module:**
   ```
   File → Settings → Build, Execution, Deployment → Build Tools → Gradle
     - Linked Gradle projects: + → src/bindings/java/build.gradle.kts
   ```

4. **Enable Kotlin support:**
   ```
   File → Settings → Plugins → Install "Kotlin"
   ```

---

### Eclipse

#### Prerequisites

- **Eclipse 2023-06+**
- **Buildship Gradle Integration** plugin
- **Kotlin Plugin for Eclipse** (optional)

#### Setup Steps

1. **Import Gradle project:**
   ```
   File → Import → Gradle → Existing Gradle Project
     - Project root directory: valhalla/src/bindings/java
     - Finish
   ```

2. **Configure JDK:**
   ```
   Window → Preferences → Java → Installed JREs
     - Add → Standard VM → JDK 17+
     - Set as default
   ```

3. **Gradle sync:**
   ```
   Right-click project → Gradle → Refresh Gradle Project
   ```

---

### Common IDE Issues

#### Issue 1: Only "External Libraries" Visible

**Solutions:**

a) Invalidate IntelliJ cache:
```
File → Invalidate Caches / Restart → Invalidate and Restart
```

b) Re-import Gradle project:
```
File → Close Project
Delete .idea directory (optional)
File → Open → valhalla
```

c) Refresh Gradle:
```
View → Tool Windows → Gradle → Click refresh icon (🔄)
```

#### Issue 2: "Cannot resolve symbol" Errors

**Solutions:**

a) Rebuild project:
```
Build → Rebuild Project
```

b) Sync Gradle:
```
View → Tool Windows → Gradle → Reload All Gradle Projects
```

#### Issue 3: Tests Not Running

**Solutions:**

a) Rebuild test classes:
```
Build → Rebuild Project
```

b) Run via Gradle:
```bash
cd src/bindings/java
./gradlew test --tests "SingaporeRideHaulingTest"
```

#### Issue 4: Kotlin Not Recognized

**Solutions:**

a) Install Kotlin plugin:
```
File → Settings → Plugins → Marketplace
Search: "Kotlin" → Install → Restart IntelliJ
```

#### Issue 5: Out of Memory During Build

**Solutions:**

a) Increase IntelliJ memory:
```
Help → Edit Custom VM Options
Add or modify:
-Xmx4096m
-Xms2048m
```

b) Increase Gradle memory:
Edit `gradle.properties`:
```properties
org.gradle.jvmargs=-Xmx4096m -Xms2048m
```

c) Exclude large directories:
```
Right-click on data/ → Mark Directory as → Excluded
Right-click on build/ → Mark Directory as → Excluded
```

---

## Building Singapore Tiles

### Understanding Tiles

Valhalla uses a **tiled hierarchical data structure** for efficient routing:

```
data/valhalla_tiles/singapore/
├── 2/                    # Tile level 2 (highest detail)
│   ├── 000/
│   │   ├── 456.gph      # Individual tiles
│   │   ├── 457.gph
│   │   └── ...
│   └── 001/
│       └── ...
└── admin_data/
    ├── admins.sqlite    # Admin boundaries
    └── timezones.sqlite # Timezone data
```

### Quick Build

```bash
# Download OSM data
./scripts/regions/download-region-osm.sh singapore

# Build tiles
./scripts/regions/build-tiles.sh singapore

# Validate tiles
./scripts/regions/validate-tiles.sh singapore
```

### Manual Build Process

#### Step 1: Download OSM Data

```bash
./scripts/regions/download-region-osm.sh singapore
```

**What happens:**
- Downloads from Geofabrik (~230 MB)
- Saves to `data/osm/singapore-latest.osm.pbf`
- Verifies MD5 checksum
- Takes 5-10 minutes

#### Step 2: Build Tiles

```bash
./scripts/regions/build-tiles.sh singapore
```

**What happens:**
- Reads OSM data
- Generates routing graph tiles
- Creates admin database
- Saves to `data/valhalla_tiles/singapore/`
- Takes 10-20 minutes

**Output:**
```
✓ Tile build completed successfully
Tiles created: 147
Total size: 450 MB
```

#### Step 3: Validate Tiles

```bash
./scripts/regions/validate-tiles.sh singapore
```

**Validation checks:**
1. ✓ Tile directory exists
2. ✓ Tiles have correct format (.gph)
3. ✓ Total size > 100 MB
4. ✓ Tile hierarchy structure (2/xxx/xxx)
5. ✓ Admin database exists
6. ✓ Bounds check (Singapore coordinates)
7. ✓ Sample tile integrity

### Build Performance

| Region | OSM Size | Build Time | Tile Count | Tile Size |
|--------|----------|------------|------------|-----------|
| Singapore | 230 MB | 10-20 min | 147 tiles | 450 MB |
| Thailand | 850 MB | 30-60 min | 580 tiles | 1.8 GB |
| Malaysia | 450 MB | 20-40 min | 320 tiles | 1.1 GB |

**Factors affecting build time:**
- CPU cores (more = faster)
- RAM available (minimum 4 GB)
- Disk speed (SSD recommended)
- OSM data size

### Incremental Updates

To update tiles with new OSM data:

```bash
# 1. Download latest OSM data
./scripts/regions/download-region-osm.sh singapore

# 2. Rebuild tiles (overwrites existing)
./scripts/regions/build-tiles.sh singapore

# 3. Restart your application to load new tiles
```

---

## Testing

### Running Tests

```bash
# Run all Singapore tests
cd src/bindings/java
./gradlew test --tests "SingaporeRideHaulingTest"

# Run specific test
./gradlew test --tests "SingaporeRideHaulingTest.test 02*"

# Run with verbose output
./gradlew test --tests "SingaporeRideHaulingTest" --info
```

### Test Coverage

**11 test scenarios:**

1. **Service Status** - Verify Valhalla is running
2. **Short Route** - Raffles Place → Marina Bay (<5km)
3. **Medium Route** - Orchard Road → East Coast Park (5-15km)
4. **Long Route** - Marina Bay → Changi Airport (>15km)
5. **Expressway Route** - Jurong East → Changi Airport (via PIE/ECP)
6. **Multi-Waypoint** - Orchard → Bugis → Raffles → Marina Bay
7. **Driver Dispatch** - Matrix API with 5 drivers
8. **Motorcycle Routing** - Motorcycle-specific routing
9. **Isochrone** - 10/20/30 minute drive time zones
10. **Location API** - Nearest road lookup
11. **Performance** - 100 iterations, measure latency

### Expected Performance

| Test | Expected Latency | Pass Criteria |
|------|-----------------|---------------|
| Short route | 2-3ms | < 5ms |
| Medium route | 3-5ms | < 10ms |
| Long route | 5-8ms | < 15ms |
| Matrix (1×5) | 5-10ms | < 20ms |
| Isochrone | 8-12ms | < 25ms |

---

## Troubleshooting

### Build Issues

#### Issue 1: CMake Cache Conflicts

**Error:**
```
CMake Error: The current CMakeCache.txt directory is different
```

**Solution:**
```bash
rm -rf build
# Or with sudo if permission denied
sudo rm -rf build

# Then reconfigure
cmake -B build ...
```

#### Issue 2: C++20 Format Header Not Found

**Error:**
```
fatal error: format: No such file or directory
   17 | #include <format>
```

**Solution:** Upgrade to GCC 13 (see Step 6 in Manual Build)

#### Issue 3: Maybe-Uninitialized Errors

**Error:**
```
error: 'first_bridge_index' may be used uninitialized [-Werror=maybe-uninitialized]
```

**Solution:**
```bash
export CXXFLAGS="-Wno-error=maybe-uninitialized"
rm -rf build
cmake -B build ...
cmake --build build --target valhalla_jni -j4
```

#### Issue 4: JNI Not Found

**Error:**
```
Could NOT find JNI (missing: JAVA_AWT_LIBRARY JAVA_AWT_INCLUDE_PATH)
```

**Solution:**
```bash
sudo apt-get install -y openjdk-17-jdk
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
rm -rf build
cmake -B build ...
```

### Tile Building Issues

#### Issue 5: Tiles Not Found

**Error:**
```
Error: Singapore tiles not found!
```

**Solution:**
```bash
ls -la data/valhalla_tiles/singapore/
# If empty, rebuild tiles
./scripts/regions/build-tiles.sh singapore
```

#### Issue 6: OSM Download Fails

**Error:**
```
Error: Failed to download OSM data
```

**Solutions:**

a) Check network:
```bash
curl -I https://download.geofabrik.de/
```

b) Manual download:
```bash
wget https://download.geofabrik.de/asia/malaysia-singapore-brunei-latest.osm.pbf \
  -O data/osm/singapore-latest.osm.pbf
```

#### Issue 7: Build Tiles Fails

**Error:**
```
Error: valhalla_build_tiles failed
```

**Check logs:**
```bash
./scripts/regions/build-tiles.sh singapore 2>&1 | tee build.log
```

**Common causes:**
- Insufficient memory (need 4GB+)
- Corrupted OSM file
- Disk space full

**Solutions:**

a) Increase swap (Linux):
```bash
sudo fallocate -l 4G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
```

b) Re-download OSM data:
```bash
rm data/osm/singapore-latest.osm.pbf
./scripts/regions/download-region-osm.sh singapore
```

### Runtime Issues

#### Issue 8: Library Load Error

**Error:**
```
java.lang.UnsatisfiedLinkError: no valhalla_jni in java.library.path
```

**Solution:**

Check if library is embedded in JAR:
```bash
cd src/bindings/java
./gradlew jar
jar tf build/libs/valhalla-jni-*.jar | grep "\.so"
```

If missing:
```bash
./gradlew clean build
```

#### Issue 9: Route Not Found

**Error:**
```
Error: Location is unreachable
```

**Causes:**

a) **Coordinates outside Singapore:**
- Singapore bounds: 1.15-1.48 lat, 103.6-104.0 lon

b) **Tiles incomplete:**
```bash
./scripts/regions/validate-tiles.sh singapore
```

c) **Location on restricted road:**
- Try increasing search radius
- Use different coordinates

### Python/Docker Issues

#### Issue 10: Python valhalla Not Found

**Error:**
```
python -m valhalla: No module named valhalla
```

**Solution:**
```bash
pip install pyvalhalla
# Or
python3 -m pip install pyvalhalla
```

#### Issue 11: Docker Permission Denied

**Error:**
```
docker: permission denied
```

**Solution (Linux):**
```bash
sudo usermod -aG docker $USER
newgrp docker
# Or use sudo
sudo docker run ...
```

---

## Production Deployment

### Recommended Configuration

**For ride-hailing production:**

```json
{
  "mjolnir": {
    "tile_dir": "/var/valhalla/tiles",
    "max_cache_size": 4294967296,
    "concurrency": 8
  },
  "service_limits": {
    "auto": {
      "max_matrix_location_pairs": 10000
    }
  }
}
```

### Performance Tuning

**JVM Options:**
```bash
java -Xmx4g -Xms2g \
     -XX:+UseG1GC \
     -XX:MaxGCPauseMillis=200 \
     -jar your-app.jar
```

**Memory Management:**
- Each `Actor` instance loads tiles (~500MB for Singapore)
- Reuse `Actor` instances (singleton pattern)
- Don't create new `Actor` per request

**Example Singleton:**
```kotlin
@Service
class RoutingService {
    companion object {
        private val actor: Actor by lazy {
            Actor.createSingapore("/data/valhalla_tiles/singapore")
        }
    }

    fun route(request: String) = actor.route(request)
}
```

### Docker Deployment

**Dockerfile:**
```dockerfile
FROM openjdk:17-slim

# Copy tiles
COPY data/valhalla_tiles/singapore /var/valhalla/tiles

# Copy application
COPY build/libs/your-app.jar /app/app.jar

# Run
CMD ["java", "-jar", "/app/app.jar"]
```

### Monitoring

**Key Metrics:**
- Request latency (p50, p95, p99)
- Throughput (requests/second)
- Memory usage
- Tile cache hit rate

**Health Check:**
```kotlin
val status = actor.status("{}")
// Parse and check if service is healthy
```

---

## Next Steps

1. ✅ Complete setup using automated script
2. ✅ Run all tests successfully
3. 📖 Read [Singapore Quick Start Guide](../singapore/SINGAPORE_QUICKSTART.md)
4. 🚗 Read [Integration Guide](INTEGRATION_GUIDE.md)
5. 🌏 Add more regions (Thailand, Malaysia)
6. 📊 Setup monitoring and alerts
7. 🚀 Deploy to production

---

## Additional Resources

- **Quick Start:** [singapore/SINGAPORE_QUICKSTART.md](../singapore/SINGAPORE_QUICKSTART.md)
- **Integration:** [INTEGRATION_GUIDE.md](INTEGRATION_GUIDE.md)
- **Valhalla Docs:** https://valhalla.github.io/valhalla
- **GitHub Issues:** https://github.com/valhalla/valhalla/issues

---

**Document Version:** 1.0
**Last Updated:** February 11, 2026
**Maintainer:** Valhalla JNI Team
