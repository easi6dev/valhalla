#!/bin/bash
#
# Test runner for Singapore ride-hailing JNI tests in WSL
# This script sets up the proper library paths and runs the Gradle tests

set -e

cd "$(dirname "$0")"

echo "=== Singapore Ride-Hailing Test Runner ==="
echo ""

# Define paths
ROOT_DIR="/mnt/c/Users/Vibin/Workspace/valhalla"
BUILD_DIR="$ROOT_DIR/build"
JNI_LIB_DIR="$BUILD_DIR/src/bindings/java/libs/native"
VALHALLA_LIB_DIR="$BUILD_DIR/src"
JAVA_DIR="$ROOT_DIR/src/bindings/java"

# Check if libraries exist
echo "=== Checking for native libraries ==="
if [ ! -f "$JNI_LIB_DIR/libvalhalla_jni.so" ]; then
    echo "ERROR: JNI library not found at: $JNI_LIB_DIR/libvalhalla_jni.so"
    echo "Please build the project first using CMake"
    exit 1
fi

if [ ! -f "$VALHALLA_LIB_DIR/libvalhalla.so" ]; then
    echo "ERROR: Valhalla library not found at: $VALHALLA_LIB_DIR/libvalhalla.so"
    echo "Please build the project first using CMake"
    exit 1
fi

echo "✓ Found libvalhalla_jni.so"
echo "✓ Found libvalhalla.so"
echo ""

# Set up library path
export LD_LIBRARY_PATH="$VALHALLA_LIB_DIR:$JNI_LIB_DIR:${LD_LIBRARY_PATH:-}"

echo "=== Library configuration ==="
echo "LD_LIBRARY_PATH=$LD_LIBRARY_PATH"
echo ""

# Change to Java directory
cd "$JAVA_DIR"

# Fix line endings if needed
sed -i 's/\r$//' gradlew 2>/dev/null || true
chmod +x gradlew

# Run tests
echo "=== Running Singapore Ride-Hailing Tests ==="
echo ""

./gradlew test \
    --tests "global.tada.valhalla.singapore.SingaporeRideHaulingTest" \
    --info \
    2>&1 | tee "$ROOT_DIR/singapore-test-results.log"

# Check results
if [ $? -eq 0 ]; then
    echo ""
    echo "=== ✓ Tests Passed ==="
else
    echo ""
    echo "=== ✗ Tests Failed ==="
    echo "See logs: $ROOT_DIR/singapore-test-results.log"
    exit 1
fi
