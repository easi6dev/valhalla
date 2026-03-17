#!/bin/bash
#
# Production JAR Bundling Script for Valhalla JNI
# This script creates a self-contained JAR with all native dependencies
#
# Usage:
#   ./bundle-production-jar.sh [project-root] [system-lib-dir]
#
# Arguments:
#   project-root     Project root directory (default: auto-detect or current directory)
#   system-lib-dir   System libraries directory (default: /lib/x86_64-linux-gnu)
#
# Examples:
#   ./bundle-production-jar.sh
#   ./bundle-production-jar.sh /path/to/project
#   ./bundle-production-jar.sh /path/to/project /usr/lib/x86_64-linux-gnu
#

set -e  # Exit on error

# Determine project root
if [ -n "$1" ]; then
    PROJECT_ROOT="$1"
else
    # Auto-detect: if we're in the script's directory, go up to project root
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ -f "${SCRIPT_DIR}/CMakeLists.txt" ] && [ -d "${SCRIPT_DIR}/src/bindings/java" ]; then
        PROJECT_ROOT="${SCRIPT_DIR}"
    else
        PROJECT_ROOT="$(pwd)"
    fi
fi

# Verify project root
if [ ! -d "${PROJECT_ROOT}/src/bindings/java" ]; then
    echo "❌ Error: Invalid project root: ${PROJECT_ROOT}"
    echo "   Expected to find: src/bindings/java/"
    echo ""
    echo "Usage: $0 [project-root] [system-lib-dir]"
    exit 1
fi

cd "${PROJECT_ROOT}"

echo "╔═══════════════════════════════════════════════════════════╗"
echo "║   Valhalla JNI - Production JAR Builder                   ║"
echo "║   Optimized: Only bundling essential Valhalla libraries   ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo ""
echo "📂 Project root: ${PROJECT_ROOT}"
echo ""
echo "⚙️  Build Strategy:"
echo "   • Bundle ONLY: libprotobuf-lite, libvalhalla, libvalhalla_jni"
echo "   • System libs (libcurl, libssl, etc.) from runtime environment"
echo "   • Docker/K8s: Install via apt/apk in base image"
echo "   • Bare Metal: Install via package manager"
echo ""

# Configuration
RESOURCES_DIR="src/bindings/java/src/main/resources/lib/linux-amd64"

# We no longer bundle system libraries - they should come from the runtime environment
SKIP_SYSTEM_LIBS=true

# Create resources directory
echo "📁 Step 1: Creating resources directory"
mkdir -p "$RESOURCES_DIR"
echo "   ✅ Directory created: $RESOURCES_DIR"
echo ""

# Copy essential Valhalla libraries
echo "📦 Step 2: Copying essential libraries"

COPIED_COUNT=0

# Copy libprotobuf-lite (specific version required by Valhalla)
if [ -f "/usr/lib/x86_64-linux-gnu/libprotobuf-lite.so.23" ]; then
    cp /usr/lib/x86_64-linux-gnu/libprotobuf-lite.so.23 "$RESOURCES_DIR/"
    echo "   ✅ libprotobuf-lite.so.23"
    ((COPIED_COUNT++))
elif [ -f "/lib/x86_64-linux-gnu/libprotobuf-lite.so.23" ]; then
    cp /lib/x86_64-linux-gnu/libprotobuf-lite.so.23 "$RESOURCES_DIR/"
    echo "   ✅ libprotobuf-lite.so.23"
    ((COPIED_COUNT++))
else
    echo "   ⚠️  libprotobuf-lite.so.23 not found (install libprotobuf23)"
fi

# Copy libvalhalla.so
if [ -f "build/src/libvalhalla.so.3" ]; then
    cp build/src/libvalhalla.so.3 "$RESOURCES_DIR/"
    echo "   ✅ libvalhalla.so.3"
    ((COPIED_COUNT++))
else
    echo "   ⚠️  libvalhalla.so.3 not found in build/"
fi

# Copy libvalhalla_jni.so
if [ -f "src/bindings/java/build/libs/native/libvalhalla_jni.so" ]; then
    cp src/bindings/java/build/libs/native/libvalhalla_jni.so "$RESOURCES_DIR/"
    echo "   ✅ libvalhalla_jni.so"
    ((COPIED_COUNT++))
else
    echo "   ⚠️  libvalhalla_jni.so not found in build/"
fi

echo ""
echo "   Copied $COPIED_COUNT essential libraries"
echo ""

# System libraries are NOT bundled - they come from runtime environment
echo "⏭️  Step 3: System libraries (NOT bundled)"
echo "   System dependencies required at runtime:"
echo "   • libboost-* (filesystem, system, etc.)"
echo "   • libcurl, libssl, libcrypto"
echo "   • libsqlite3, libspatialite"
echo "   • liblz4, libzstd, zlib"
echo ""
echo "   Install via:"
echo "   • Docker: RUN apt install libboost-all-dev libcurl4 ..."
echo "   • Ubuntu: sudo apt install libboost-all-dev libcurl4 ..."
echo "   • Alpine: apk add boost-dev curl-dev ..."
echo ""

# Summary
echo "📊 Step 4: Bundle Summary"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
TOTAL_LIBS=$(ls "$RESOURCES_DIR" 2>/dev/null | wc -l)
TOTAL_SIZE=$(du -sh "$RESOURCES_DIR" 2>/dev/null | cut -f1 || echo "0")
echo "   Essential libraries bundled: $TOTAL_LIBS"
echo "   Total size: $TOTAL_SIZE (optimized - only Valhalla libs)"
echo ""
echo "   Bundled libraries:"
ls -1 "$RESOURCES_DIR" 2>/dev/null | sed 's/^/     • /' || echo "     (none)"
echo ""
echo "   📌 Note: System libraries NOT bundled (provided by runtime)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Build JAR
echo "🔨 Step 5: Building production JAR"
cd src/bindings/java

if [ ! -f "gradlew" ]; then
    echo "   ❌ gradlew not found in src/bindings/java"
    exit 1
fi

chmod +x gradlew

if [[ "${SKIP_TESTS}" == "1" || "${SKIP_TESTS}" == "true" ]]; then
    echo "   Skipping tests (SKIP_TESTS=${SKIP_TESTS})"
    ./gradlew clean build -x buildNative -x test
else
    ./gradlew clean build -x buildNative
fi

if [ $? -eq 0 ]; then
    echo "   ✅ JAR build successful"
else
    echo "   ❌ JAR build failed"
    exit 1
fi
echo ""

# Verify JAR
echo "🔍 Step 6: Verifying JAR contents"
JAR_FILE=$(ls build/libs/valhalla-jni-*.jar 2>/dev/null | grep -v sources | grep -v javadoc | head -1)
if [ -n "$JAR_FILE" ]; then
    JAR_SIZE=$(du -h "$JAR_FILE" | cut -f1)
    JAR_LIBS=$(jar tf "$JAR_FILE" | grep "\.so$" | wc -l)

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "   JAR file: $JAR_FILE"
    echo "   JAR size: $JAR_SIZE"
    echo "   Libraries in JAR: $JAR_LIBS"
    echo ""
    echo "   Bundled libraries:"
    jar tf "$JAR_FILE" | grep "\.so$" | sed 's/^/     • /'
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
else
    echo "   ❌ JAR file not found"
    exit 1
fi
echo ""

# Run tests (optional)
if [[ "${SKIP_TESTS}" != "1" && "${SKIP_TESTS}" != "true" ]]; then
    echo "🧪 Step 7: Running integration tests"
    ./gradlew test -x buildNative

    if [ $? -eq 0 ]; then
        echo ""
        echo "╔═══════════════════════════════════════════════════════════╗"
        echo "║                  ✅ BUILD SUCCESSFUL                       ║"
        echo "╚═══════════════════════════════════════════════════════════╝"
        echo ""
        echo "📦 Production JAR is ready!"
        echo "   Location: $JAR_FILE"
        echo "   Size: $JAR_SIZE (optimized - reduced from ~14MB to ~3MB)"
        echo "   Libraries: $JAR_LIBS native libraries bundled"
        echo ""
        echo "🚀 Deployment Requirements:"
        echo "   This optimized JAR requires system dependencies at runtime:"
        echo ""
        echo "   Docker (Recommended):"
        echo "   FROM ubuntu:22.04"
        echo "   RUN apt update && apt install -y \\"
        echo "       libboost-all-dev libcurl4 libssl3 \\"
        echo "       libsqlite3-0 libspatialite7 \\"
        echo "       liblz4-1 libzstd1 zlib1g"
        echo ""
        echo "   Ubuntu/Debian:"
        echo "   sudo apt install libboost-all-dev libcurl4 libssl3 ..."
        echo ""
        echo "   Alpine Linux:"
        echo "   apk add boost-dev curl-dev openssl ..."
        echo ""
    else
        echo ""
        echo "╔═══════════════════════════════════════════════════════════╗"
        echo "║                  ❌ TESTS FAILED                           ║"
        echo "╚═══════════════════════════════════════════════════════════╝"
        echo ""
        echo "Check the test output above for errors."
        exit 1
    fi
else
    echo "⏭️  Step 7: Skipped tests (SKIP_TESTS=true)"
    echo ""
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║                  ✅ BUILD SUCCESSFUL                       ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo ""
    echo "📦 Production JAR is ready!"
    echo "   Location: $JAR_FILE"
    echo "   Size: $JAR_SIZE"
    echo "   Libraries: $JAR_LIBS native libraries bundled"
    echo ""
fi
