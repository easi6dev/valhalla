# Valhalla JNI Bindings Build Guide

Complete step-by-step guide for building Valhalla JNI bindings in WSL.

## Prerequisites

- **Operating System**: Windows with WSL2 (Ubuntu 22.04)
- **Pre-built Libraries**: `libvalhalla.so.3.6.2` and dependencies in `src/bindings/java/src/main/resources/lib/linux-amd64/`

---

## Quick Start

If you just want to build everything quickly:

```bash
# Enter WSL
wsl -d Ubuntu-22.04

# Navigate to project
cd /mnt/c/Users/Vibin/Workspace/valhallaV3

# Make script executable
chmod +x build-jni-bindings.sh

# Run the build script
./build-jni-bindings.sh
```

---

## Manual Build Steps

If you prefer to run commands manually or need to troubleshoot:

### Step 1: Enter WSL Environment

```bash
# From Windows terminal or PowerShell
wsl -d Ubuntu-22.04
```

### Step 2: Install System Dependencies

```bash
# Update package list
sudo apt update

# Install build tools and dependencies
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
  git
```

**Note**: `libprime-server-dev` is not available in Ubuntu repos but is not required for JNI bindings.

### Step 3: Install and Configure Java

```bash
# Install OpenJDK 17
sudo apt install -y openjdk-17-jdk

# Verify installation
java -version

# Set JAVA_HOME environment variable
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
export PATH=$JAVA_HOME/bin:$PATH

# Make it permanent by adding to ~/.bashrc
echo 'export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64' >> ~/.bashrc
echo 'export PATH=$JAVA_HOME/bin:$PATH' >> ~/.bashrc

# Reload bashrc
source ~/.bashrc
```

### Step 4: Prepare Valhalla Library

```bash
# Navigate to the native library directory
cd /mnt/c/Users/Vibin/Workspace/valhallaV3/src/bindings/java/src/main/resources/lib/linux-amd64

# Create symlinks for the Valhalla library
sudo ln -sf libvalhalla.so.3.6.2 libvalhalla.so.3
sudo ln -sf libvalhalla.so.3.6.2 libvalhalla.so

# Verify symlinks
ls -la libvalhalla.so*

# Set library path
export LD_LIBRARY_PATH=/mnt/c/Users/Vibin/Workspace/valhallaV3/src/bindings/java/src/main/resources/lib/linux-amd64:$LD_LIBRARY_PATH
```

### Step 5: Update CMakeLists.txt

The `CMakeLists.txt` has been modified to:
- Use C++20 standard (required for Valhalla 3.6.2)
- Support standalone builds with pre-built libraries
- Include protobuf generated headers

Key changes made to `src/bindings/java/CMakeLists.txt`:

```cmake
# Set C++ standard to C++20
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Include protobuf generated headers
target_include_directories(valhalla_jni PRIVATE
    ${VALHALLA_SOURCE_DIR}/build/src  # For generated protobuf headers
    # ... other includes
)

# Support for pre-built library linking
if(TARGET valhalla)
    target_link_libraries(valhalla_jni PRIVATE valhalla)
else()
    find_library(VALHALLA_LIBRARY NAMES valhalla
                 PATHS ${CMAKE_CURRENT_SOURCE_DIR}/src/main/resources/lib/linux-amd64
                 NO_DEFAULT_PATH)
    target_link_libraries(valhalla_jni PRIVATE ${VALHALLA_LIBRARY})
endif()
```

### Step 6: Build Native JNI Library

```bash
# Navigate to Java bindings directory
cd /mnt/c/Users/Vibin/Workspace/valhallaV3/src/bindings/java

# Create and enter build directory
mkdir -p build
cd build

# Clean previous build (if any)
rm -rf *

# Configure with CMake
cmake .. \
  -DCMAKE_BUILD_TYPE=Release \
  -DVALHALLA_SOURCE_DIR=/mnt/c/Users/Vibin/Workspace/valhallaV3

# Build the JNI library
cmake --build . --config Release

# Verify the library was created
ls -lh libs/native/libvalhalla_jni.so
```

**Expected output**: `libvalhalla_jni.so` created in `build/libs/native/`

### Step 7: Copy JNI Library to Resources

```bash
# Copy the built library to resources directory
cp /mnt/c/Users/Vibin/Workspace/valhallaV3/src/bindings/java/build/libs/native/libvalhalla_jni.so \
   /mnt/c/Users/Vibin/Workspace/valhallaV3/src/bindings/java/src/main/resources/lib/linux-amd64/

# Verify it was copied
ls -lh /mnt/c/Users/Vibin/Workspace/valhallaV3/src/bindings/java/src/main/resources/lib/linux-amd64/libvalhalla_jni.so
```

### Step 8: Build JAR with Gradle

```bash
# Navigate to Java bindings directory
cd /mnt/c/Users/Vibin/Workspace/valhallaV3/src/bindings/java

# Make gradlew executable (if not already)
chmod +x gradlew

# Clean and build with tests
./gradlew clean build

# Or build without tests (faster)
./gradlew clean assemble
```

**Expected output**: `BUILD SUCCESSFUL`

### Step 9: Verify Build Artifacts

```bash
# List built JAR files
ls -lh build/libs/

# Expected files:
# - valhalla-jni-1.0.0-SNAPSHOT.jar (main JAR)
# - valhalla-jni-1.0.0-SNAPSHOT-sources.jar
# - valhalla-jni-1.0.0-SNAPSHOT-javadoc.jar
```

---

## Common Commands

### Run Tests Only
```bash
cd /mnt/c/Users/Vibin/Workspace/valhallaV3/src/bindings/java
./gradlew test
```

### Rebuild Everything
```bash
cd /mnt/c/Users/Vibin/Workspace/valhallaV3/src/bindings/java
./gradlew clean build
```

### Quick Build (No Tests)
```bash
cd /mnt/c/Users/Vibin/Workspace/valhallaV3/src/bindings/java
./gradlew assemble
```

### Publish to Local Maven Repository
```bash
cd /mnt/c/Users/Vibin/Workspace/valhallaV3/src/bindings/java
./gradlew publishToMavenLocal
```

---

## Troubleshooting

### Issue: CMake can't find Valhalla library

**Solution**: Verify the library exists and symlinks are created:
```bash
ls -la /mnt/c/Users/Vibin/Workspace/valhallaV3/src/bindings/java/src/main/resources/lib/linux-amd64/libvalhalla.so*
```

### Issue: C++20 compilation errors (std::ranges, std::span)

**Solution**: Ensure CMakeLists.txt has C++20 enabled:
```cmake
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
```

### Issue: Missing protobuf headers (api.pb.h)

**Solution**: Ensure the build directory include path is set:
```cmake
target_include_directories(valhalla_jni PRIVATE
    ${VALHALLA_SOURCE_DIR}/build/src
)
```

### Issue: Tests fail with UnsatisfiedLinkError

**Solution**: This happens when running tests on Windows. Always run Gradle builds in WSL:
```bash
wsl -d Ubuntu-22.04
cd /mnt/c/Users/Vibin/Workspace/valhallaV3/src/bindings/java
./gradlew test
```

### Issue: Gradle daemon errors

**Solution**: Stop all Gradle daemons and rebuild:
```bash
./gradlew --stop
./gradlew clean build
```

---

## Build Output Locations

| Artifact | Location |
|----------|----------|
| JNI Library (native) | `build/libs/native/libvalhalla_jni.so` |
| JNI Library (resources) | `src/main/resources/lib/linux-amd64/libvalhalla_jni.so` |
| Main JAR | `build/libs/valhalla-jni-1.0.0-SNAPSHOT.jar` |
| Sources JAR | `build/libs/valhalla-jni-1.0.0-SNAPSHOT-sources.jar` |
| Javadoc JAR | `build/libs/valhalla-jni-1.0.0-SNAPSHOT-javadoc.jar` |
| Test Reports | `build/reports/tests/test/index.html` |

---

## Key Files Modified

### `src/bindings/java/CMakeLists.txt`

Modified to support:
1. C++20 standard
2. Standalone builds with pre-built libraries
3. Protobuf generated headers from build directory
4. Proper include paths for all Valhalla headers

---

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                  Java/Kotlin Code                   │
│    (Actor.kt, Config classes, etc.)                 │
└──────────────────┬──────────────────────────────────┘
                   │ JNI calls
                   ▼
┌─────────────────────────────────────────────────────┐
│            libvalhalla_jni.so                       │
│    (C++ JNI wrapper - valhalla_jni.cc)              │
└──────────────────┬──────────────────────────────────┘
                   │ Links to
                   ▼
┌─────────────────────────────────────────────────────┐
│         libvalhalla.so.3.6.2                        │
│    (Pre-built Valhalla core library)                │
└─────────────────────────────────────────────────────┘
```

---

## Why WSL?

The native libraries (`.so` files) are Linux binaries and must be built in a Linux environment. While you can build the JAR on Windows (with `-x buildNative`), running tests requires the actual `.so` files to be loadable, which only works on Linux.

**Windows**: Build JAR only (skip native build and tests)
```bash
gradlew.bat assemble -x buildNative
```

**WSL/Linux**: Build everything including native libraries and run tests
```bash
./gradlew clean build
```

---

## Notes

- **Valhalla Version**: 3.6.2 (requires C++20)
- **Java Version**: 17 (LTS)
- **Gradle Version**: 8.14.4
- **CMake Version**: 3.22.1+
- **Build Time**: ~2-3 minutes on first build, ~30 seconds on incremental builds

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
valhalla-jni-1.0.0-SNAPSHOT.jar
valhalla-jni-1.0.0-SNAPSHOT-sources.jar
valhalla-jni-1.0.0-SNAPSHOT-javadoc.jar
```
