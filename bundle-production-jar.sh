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
echo "║   Creating self-contained JAR with all dependencies       ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo ""
echo "📂 Project root: ${PROJECT_ROOT}"
echo ""

# Configuration
RESOURCES_DIR="src/bindings/java/src/main/resources/lib/linux-amd64"
SYSTEM_LIB_DIR="${2:-/lib/x86_64-linux-gnu}"

# Verify system library directory
if [ ! -d "${SYSTEM_LIB_DIR}" ]; then
    echo "⚠️  Warning: System library directory not found: ${SYSTEM_LIB_DIR}"
    echo "   Will skip system library bundling"
    SKIP_SYSTEM_LIBS=true
else
    SKIP_SYSTEM_LIBS=false
    echo "📚 System libraries: ${SYSTEM_LIB_DIR}"
    echo ""
fi

# Create resources directory
echo "📁 Step 1: Creating resources directory"
mkdir -p "$RESOURCES_DIR"
echo "   ✅ Directory created: $RESOURCES_DIR"
echo ""

# Copy Valhalla libraries
echo "📦 Step 2: Copying Valhalla libraries"

if [ -f "build/src/libvalhalla.so.3" ]; then
    cp build/src/libvalhalla.so.3 "$RESOURCES_DIR/"
    echo "   ✅ libvalhalla.so.3"
else
    echo "   ⚠️  libvalhalla.so.3 not found in build/"
fi

if [ -f "build/src/bindings/java/libs/native/libvalhalla_jni.so" ]; then
    cp build/src/bindings/java/libs/native/libvalhalla_jni.so "$RESOURCES_DIR/"
    echo "   ✅ libvalhalla_jni.so"
else
    echo "   ⚠️  libvalhalla_jni.so not found in build/"
fi
echo ""

# Function to copy library with error handling
copy_lib() {
    local lib_name=$1
    local lib_path="${SYSTEM_LIB_DIR}/${lib_name}"

    if [ -f "$lib_path" ]; then
        cp "$lib_path" "$RESOURCES_DIR/"
        echo "   ✅ $lib_name"
        return 0
    else
        echo "   ⚠️  $lib_name NOT FOUND (skipping)"
        return 1
    fi
}

# Only copy system libraries if directory exists
if [ "$SKIP_SYSTEM_LIBS" = false ]; then
    # Layer 1: Base system libraries
    echo "📚 Step 3: Copying Layer 1 - Base system libraries"
    copy_lib "libffi.so.8"
    copy_lib "libresolv.so.2"
    copy_lib "libkeyutils.so.1"
    copy_lib "libtasn1.so.6"
    copy_lib "libcom_err.so.2"
    copy_lib "libz.so.1"
    copy_lib "liblz4.so.1"
    copy_lib "libgmp.so.10"
    copy_lib "libunistring.so.2"
    copy_lib "libbrotlicommon.so.1"
    echo ""

    # Layer 2: Mid-level libraries
    echo "📚 Step 4: Copying Layer 2 - Mid-level libraries"
    copy_lib "libnettle.so.8"
    copy_lib "libhogweed.so.6"
    copy_lib "libp11-kit.so.0"
    copy_lib "libkrb5support.so.0"
    copy_lib "libk5crypto.so.3"
    copy_lib "libbrotlidec.so.1"
    copy_lib "libzstd.so.1"
    copy_lib "libidn2.so.0"
    echo ""

    # Layer 3: Crypto and authentication
    echo "🔐 Step 5: Copying Layer 3 - Crypto & authentication"
    copy_lib "libgnutls.so.30"
    copy_lib "libkrb5.so.3"
    copy_lib "libcrypto.so.3"
    copy_lib "libssl.so.3"
    echo ""

    # Layer 4: Protocol libraries
    echo "🌐 Step 6: Copying Layer 4 - Protocol libraries"
    copy_lib "libsasl2.so.2"
    copy_lib "libgssapi_krb5.so.2"
    copy_lib "liblber-2.5.so.0"
    copy_lib "libldap-2.5.so.0"
    copy_lib "libnghttp2.so.14"
    copy_lib "libpsl.so.5"
    copy_lib "libssh.so.4"
    copy_lib "librtmp.so.1"
    echo ""

    # Layer 5: High-level libraries
    echo "📡 Step 7: Copying Layer 5 - High-level libraries"
    copy_lib "libprotobuf-lite.so.23"
    copy_lib "libcurl.so.4"
    echo ""
else
    echo "⏭️  Steps 3-7: Skipped system library bundling"
    echo ""
fi

# Summary
echo "📊 Step 8: Bundle Summary"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
TOTAL_LIBS=$(ls "$RESOURCES_DIR" 2>/dev/null | wc -l)
TOTAL_SIZE=$(du -sh "$RESOURCES_DIR" 2>/dev/null | cut -f1 || echo "0")
echo "   Total libraries bundled: $TOTAL_LIBS"
echo "   Total size: $TOTAL_SIZE"
echo ""
echo "   Libraries:"
ls -1 "$RESOURCES_DIR" 2>/dev/null | sed 's/^/     • /' || echo "     (none)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Build JAR
echo "🔨 Step 9: Building production JAR"
cd src/bindings/java

if [ ! -f "gradlew" ]; then
    echo "   ❌ gradlew not found in src/bindings/java"
    exit 1
fi

chmod +x gradlew
./gradlew clean build -x buildNative

if [ $? -eq 0 ]; then
    echo "   ✅ JAR build successful"
else
    echo "   ❌ JAR build failed"
    exit 1
fi
echo ""

# Verify JAR
echo "🔍 Step 10: Verifying JAR contents"
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
if [ "${SKIP_TESTS:-false}" != "true" ]; then
    echo "🧪 Step 11: Running integration tests"
    ./gradlew test -x buildNative

    if [ $? -eq 0 ]; then
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
        echo "🚀 Deployment:"
        echo "   This JAR can be deployed to any Linux x86_64 system"
        if [ "$SKIP_SYSTEM_LIBS" = false ]; then
            echo "   without installing system dependencies."
        else
            echo "   (system dependencies required)"
        fi
        echo ""
        echo "📝 Usage:"
        echo "   java -jar $(basename $JAR_FILE)"
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
    echo "⏭️  Step 11: Skipped tests (SKIP_TESTS=true)"
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
