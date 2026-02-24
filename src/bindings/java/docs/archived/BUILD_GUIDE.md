# Valhalla JNI Bindings - Build Guide

Complete guide for building Valhalla Java/Kotlin JNI bindings.

---

## Table of Contents

1. [Quick Reference](#quick-reference)
2. [Prerequisites](#prerequisites)
3. [Building on Linux/WSL](#building-on-linuxwsl)
4. [Building on macOS](#building-on-macos)
5. [Building on Windows](#building-on-windows)
6. [Automated Build Script](#automated-build-script)
7. [Troubleshooting](#troubleshooting)
8. [Development Workflow](#development-workflow)

---

## Quick Reference

### One-Line Build (WSL)

```bash
wsl -d Ubuntu-22.04 -e bash -c "cd /mnt/c/Users/Vibin/Workspace/valhalla/src/bindings/java && ./gradlew clean build"
```

### Using Automated Script

```bash
wsl -d Ubuntu-22.04
cd /mnt/c/Users/Vibin/Workspace/valhalla
chmod +x src/bindings/java/build-jni-bindings.sh
cd src/bindings/java && ./src/bindings/java/build-jni-bindings.sh
```

### Common Commands

| Task | Command |
|------|---------|
| Full build | `./gradlew clean build` |
| Build without tests | `./gradlew assemble` |
| Run tests only | `./gradlew test` |
| Clean | `./gradlew clean` |
| Publish to local Maven | `./gradlew publishToMavenLocal` |
| Stop Gradle daemon | `./gradlew --stop` |

### Build Time

- **First build**: ~2-3 minutes
- **Incremental build**: ~30 seconds
- **Tests only**: ~3 seconds

---

## Prerequisites

### System Requirements

- **Operating System**: Linux, macOS, or Windows with WSL2
- **Java**: OpenJDK 17 or higher
- **CMake**: 3.15 or higher
- **C++ Compiler**: GCC 9+ or Clang with C++20 support
- **Memory**: 4GB RAM minimum (8GB recommended)

### Required Libraries

#### Linux (Ubuntu/Debian)

```bash
sudo apt update
sudo apt install -y \
  build-essential \
  cmake \
  pkg-config \
  libboost-all-dev \
  libprotobuf-dev \
  protobuf-compiler \
  libsqlite3-dev \
  libspatialite-dev \
  libgeos-dev \
  libcurl4-openssl-dev \
  zlib1g-dev \
  liblz4-dev \
  openjdk-17-jdk \
  git
```

#### macOS

```bash
brew install cmake boost protobuf sqlite3 libspatialite geos curl lz4 openjdk@17
```

#### Windows

**Use WSL2** - Native Windows builds are not recommended for JNI bindings.

Install WSL2 and Ubuntu 22.04:
```powershell
wsl --install -d Ubuntu-22.04
```

Then follow Linux instructions inside WSL.

### Pre-built Valhalla Library

You need either:

1. **Pre-built `libvalhalla.so`** (recommended for JNI development)
   - Located in `src/bindings/java/src/main/resources/lib/linux-amd64/`
   - Version 3.6.2 or higher

2. **Build Valhalla from source** (for full development)
   - See [main Valhalla build docs](https://github.com/valhalla/valhalla/blob/master/docs/docs/building.md)

---

## Building on Linux/WSL

### Step 1: Set Up Environment

```bash
# Set JAVA_HOME
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
export PATH=$JAVA_HOME/bin:$PATH

# Make permanent
echo 'export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64' >> ~/.bashrc
echo 'export PATH=$JAVA_HOME/bin:$PATH' >> ~/.bashrc
source ~/.bashrc

# Verify
java -version
echo $JAVA_HOME
```

### Step 2: Prepare Valhalla Library

If using pre-built libraries:

```bash
cd src/bindings/java/src/main/resources/lib/linux-amd64

# Create symlinks
ln -sf libvalhalla.so.3.6.2 libvalhalla.so.3
ln -sf libvalhalla.so.3.6.2 libvalhalla.so

# Set library path
export LD_LIBRARY_PATH=$(pwd):$LD_LIBRARY_PATH
```

### Step 3: Build Native JNI Library

```bash
cd src/bindings/java

# Create build directory
mkdir -p build
cd build

# Configure CMake
cmake .. \
  -DCMAKE_BUILD_TYPE=Release \
  -DVALHALLA_SOURCE_DIR=$(realpath ../../..)

# Build
cmake --build . --config Release

# Copy to resources
cp libs/native/libvalhalla_jni.so \
   ../src/main/resources/lib/linux-amd64/
```

### Step 4: Build Java/Kotlin Library

```bash
cd src/bindings/java

# Make gradlew executable
chmod +x gradlew

# Build with tests
./gradlew clean build

# Or build without tests (faster)
./gradlew assemble
```

### Step 5: Verify Build

```bash
# Check JAR files
ls -lh build/libs/

# Expected output:
# valhalla-jni-1.0.0-SNAPSHOT.jar
# valhalla-jni-1.0.0-SNAPSHOT-sources.jar
# valhalla-jni-1.0.0-SNAPSHOT-javadoc.jar

# Check native library
ls -lh src/main/resources/lib/linux-amd64/libvalhalla_jni.so
```

---

## Building on macOS

### Step 1: Install Dependencies

```bash
brew install cmake boost protobuf sqlite3 libspatialite geos curl lz4 openjdk@17
```

### Step 2: Set JAVA_HOME

```bash
export JAVA_HOME=$(/usr/libexec/java_home -v 17)
echo 'export JAVA_HOME=$(/usr/libexec/java_home -v 17)' >> ~/.zshrc
```

### Step 3: Build

Follow the same steps as Linux, but:
- Native library will be `libvalhalla_jni.dylib` instead of `.so`
- Copy to `src/main/resources/lib/darwin-amd64/` or `darwin-aarch64/`

---

## Building on Windows

### Option 1: Use WSL2 (Recommended)

```bash
# From PowerShell/CMD
wsl -d Ubuntu-22.04

# Then follow Linux instructions
cd /mnt/c/path/to/valhalla/src/bindings/java
./gradlew clean build
```

### Option 2: Skip Native Build

If you already have pre-built `.so` files:

```cmd
cd src\bindings\java
gradlew.bat assemble -x buildNative
```

**Note:** Tests will fail on Windows because they require Linux `.so` files. Run tests in WSL instead.

---

## Automated Build Script

Use the provided `src/bindings/java/build-jni-bindings.sh` script for automated builds:

### Basic Usage

```bash
# Full build with all steps
cd src/bindings/java && ./src/bindings/java/build-jni-bindings.sh

# Skip dependency installation (if already installed)
cd src/bindings/java && ./src/bindings/java/build-jni-bindings.sh --skip-deps

# Skip native build (use existing libvalhalla_jni.so)
cd src/bindings/java && ./src/bindings/java/build-jni-bindings.sh --skip-native

# Custom project path
cd src/bindings/java && ./src/bindings/java/build-jni-bindings.sh --project-root /custom/path
```

### Script Features

- ✅ Checks and installs all dependencies
- ✅ Configures Java environment
- ✅ Builds native JNI library
- ✅ Builds JAR with Gradle
- ✅ Runs all tests
- ✅ Color-coded output
- ✅ Error handling and validation
- ✅ Summary of build artifacts

### Script Output

```bash
========================================
Valhalla JNI Bindings Build Script
========================================

Step 1: Installing system dependencies...
✓ System dependencies installed

Step 2: Checking Java installation...
✓ Java already installed
✓ JAVA_HOME set to: /usr/lib/jvm/java-17-openjdk-amd64

Step 3: Verifying pre-built Valhalla library...
✓ Found libvalhalla.so.3.6.2
✓ Created symlinks for libvalhalla.so

Step 4: Building native JNI library...
✓ CMake configuration successful
✓ JNI library built successfully

Step 5: Copying JNI library to resources...
✓ JNI library copied to resources

Step 6: Building JAR with Gradle...
✓ Gradle build successful

Step 7: Verifying build artifacts...
✓ Build Complete!
```

---

## Troubleshooting

### Issue: CMake can't find Valhalla library

**Error:**
```
Valhalla library not found in .../lib/linux-amd64
```

**Solution:**
```bash
# Check library exists
ls -la src/bindings/java/src/main/resources/lib/linux-amd64/libvalhalla.so*

# Create symlinks if missing
cd src/bindings/java/src/main/resources/lib/linux-amd64
ln -sf libvalhalla.so.3.6.2 libvalhalla.so
ln -sf libvalhalla.so.3.6.2 libvalhalla.so.3
```

---

### Issue: C++20 compilation errors

**Error:**
```
error: 'std::ranges' has not been declared
error: 'std::span' in namespace 'std' does not name a template type
```

**Solution:**

Ensure `CMakeLists.txt` has C++20 enabled:
```cmake
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
```

Check compiler version:
```bash
g++ --version  # Should be GCC 9+
clang++ --version  # Should be Clang 10+
```

---

### Issue: Missing protobuf headers

**Error:**
```
fatal error: valhalla/proto/api.pb.h: No such file or directory
```

**Solution:**

Ensure Valhalla build directory exists with generated protobuf files:
```bash
# Check if files exist
ls -la build/src/valhalla/proto/api.pb.h

# If missing, you need to build Valhalla from source first
cd /path/to/valhalla
mkdir -p build
cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
cmake --build . --config Release
```

Or ensure `CMakeLists.txt` includes the build directory:
```cmake
target_include_directories(valhalla_jni PRIVATE
    ${VALHALLA_SOURCE_DIR}/build/src  # For generated protobuf headers
)
```

---

### Issue: Tests fail with UnsatisfiedLinkError

**Error:**
```
java.lang.UnsatisfiedLinkError: no valhalla_jni in java.library.path
```

**Solution:**

This happens when running tests on Windows with Linux `.so` files.

**Fix:** Always run tests in WSL/Linux:
```bash
wsl -d Ubuntu-22.04
cd /mnt/c/path/to/project/src/bindings/java
./gradlew test
```

Or skip tests on Windows:
```cmd
gradlew.bat assemble -x test
```

---

### Issue: Gradle daemon errors

**Error:**
```
A Gradle Daemon could not be reused
```

**Solution:**
```bash
./gradlew --stop
./gradlew clean build
```

---

### Issue: Out of memory during build

**Error:**
```
java.lang.OutOfMemoryError: Java heap space
```

**Solution:**

Increase Gradle memory in `gradle.properties`:
```properties
org.gradle.jvmargs=-Xmx4g -XX:MaxMetaspaceSize=512m
```

Or set environment variable:
```bash
export GRADLE_OPTS="-Xmx4g"
./gradlew clean build
```

---

## Development Workflow

### Quick Iteration Cycle

For fast development iterations:

```bash
# 1. Make code changes to Java/Kotlin files

# 2. Quick compile (no tests)
./gradlew compileKotlin

# 3. Run specific test
./gradlew test --tests "ActorTest"

# 4. Full build when ready
./gradlew build
```

### Rebuild Native Library Only

If you only changed C++ code:

```bash
cd src/bindings/java/build
cmake --build . --config Release
cp libs/native/libvalhalla_jni.so ../src/main/resources/lib/linux-amd64/
```

### Clean Everything

Complete clean including native build:

```bash
cd src/bindings/java
./gradlew clean
rm -rf build/
./gradlew clean build
```

---

## Build Artifacts

### Output Locations

| Artifact | Location |
|----------|----------|
| JNI Library (build) | `build/libs/native/libvalhalla_jni.so` |
| JNI Library (resources) | `src/main/resources/lib/linux-amd64/libvalhalla_jni.so` |
| Main JAR | `build/libs/valhalla-jni-1.0.0-SNAPSHOT.jar` |
| Sources JAR | `build/libs/valhalla-jni-1.0.0-SNAPSHOT-sources.jar` |
| Javadoc JAR | `build/libs/valhalla-jni-1.0.0-SNAPSHOT-javadoc.jar` |
| Test Reports | `build/reports/tests/test/index.html` |

### Publishing to Local Maven

```bash
./gradlew publishToMavenLocal
```

Artifacts will be in `~/.m2/repository/global/tada/valhalla/valhalla-jni/`

---

## Architecture

```
┌─────────────────────────────────────────────────────┐
│            Java/Kotlin Application                  │
│    (Your code using Actor.kt API)                   │
└──────────────────┬──────────────────────────────────┘
                   │ JNI calls
                   ▼
┌─────────────────────────────────────────────────────┐
│          valhalla-jni-1.0.0-SNAPSHOT.jar            │
│    (Kotlin classes: Actor, Config, etc.)            │
└──────────────────┬──────────────────────────────────┘
                   │ System.loadLibrary()
                   ▼
┌─────────────────────────────────────────────────────┐
│            libvalhalla_jni.so                       │
│    (C++ JNI wrapper - valhalla_jni.cc)              │
└──────────────────┬──────────────────────────────────┘
                   │ Links to
                   ▼
┌─────────────────────────────────────────────────────┐
│         libvalhalla.so.3.6.2                        │
│    (Valhalla core routing engine)                   │
└─────────────────────────────────────────────────────┘
```

---

## Additional Resources

- **Main README**: [`../README.md`](../README.md)
- **Integration Guide**: [`INTEGRATION_GUIDE.md`](INTEGRATION_GUIDE.md)
- **Multi-Region Usage**: [`../../../docs/regions/MULTI_REGION_USAGE.md`](../../../docs/regions/MULTI_REGION_USAGE.md)
- **Valhalla Documentation**: https://valhalla.github.io/valhalla/
- **JNI Specification**: https://docs.oracle.com/javase/17/docs/specs/jni/

---

## Version Information

- **Valhalla Version**: 3.6.2
- **Java Version**: 17 (LTS)
- **Gradle Version**: 8.14.4
- **CMake Version**: 3.22.1+
- **C++ Standard**: C++20
- **Kotlin Version**: 1.9.25

---

## Success Indicators

A successful build will show:
```
BUILD SUCCESSFUL in 2m 44s
10 actionable tasks: 9 executed, 1 from cache
```

All tests passing:
```
27 tests completed, 0 failed
```

JAR files created in `build/libs/`:
```
-rw-r--r-- 1 user user 156K valhalla-jni-1.0.0-SNAPSHOT.jar
-rw-r--r-- 1 user user  45K valhalla-jni-1.0.0-SNAPSHOT-sources.jar
-rw-r--r-- 1 user user  12K valhalla-jni-1.0.0-SNAPSHOT-javadoc.jar
```

---

## Performance Benchmarks

### JAR Size
- **Main JAR:** ~14 MB (includes native libraries)
- **Sources JAR:** ~14 MB
- **Javadoc JAR:** ~261 bytes

### Build Time
- **First build:** ~2-3 minutes (includes dependency download)
- **Incremental build:** ~30 seconds
- **Tests only:** ~3 seconds
- **Clean build:** ~2-3 minutes

### Runtime Performance
- **Actor creation:** ~2-3 seconds (loads Singapore tiles)
- **First route:** ~5-10 ms
- **Subsequent routes:** ~2-5 ms

### Memory Usage
- **Minimum JVM heap:** 512 MB
- **Recommended heap:** 1-2 GB
- **Tile cache (Singapore):** ~450 MB
- **Build RAM requirement:** 4 GB minimum, 8 GB recommended
