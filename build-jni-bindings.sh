#!/bin/bash

################################################################################
# Valhalla JNI Bindings Build Script for WSL
#
# This script builds the Valhalla JNI bindings (Java/Kotlin) in WSL Ubuntu.
# It compiles the native C++ JNI wrapper and packages it with Gradle.
#
# Prerequisites:
# - WSL Ubuntu 22.04
# - This script should be run from WSL
#
# Usage:
#   wsl -d Ubuntu-22.04
#   cd /mnt/c/Users/Vibin/Workspace/valhallaV3
#   chmod +x build-jni-bindings.sh
#   ./build-jni-bindings.sh
#
################################################################################

set -e  # Exit on error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Project paths
PROJECT_ROOT="/mnt/c/Users/Vibin/Workspace/valhallaV3"
JAVA_BINDINGS_DIR="${PROJECT_ROOT}/src/bindings/java"
NATIVE_LIB_DIR="${JAVA_BINDINGS_DIR}/src/main/resources/lib/linux-amd64"
BUILD_DIR="${JAVA_BINDINGS_DIR}/build"

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Valhalla JNI Bindings Build Script${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

################################################################################
# Step 1: Install System Dependencies
################################################################################
echo -e "${GREEN}Step 1: Installing system dependencies...${NC}"

if ! command -v cmake &> /dev/null; then
    echo -e "${YELLOW}CMake not found. Installing...${NC}"
    sudo apt update
    sudo apt install -y cmake
else
    echo -e "${GREEN}✓ CMake already installed${NC}"
fi

# Install all required build dependencies
echo -e "${YELLOW}Installing Valhalla build dependencies...${NC}"
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

echo -e "${GREEN}✓ System dependencies installed${NC}"
echo ""

################################################################################
# Step 2: Install and Configure Java
################################################################################
echo -e "${GREEN}Step 2: Checking Java installation...${NC}"

if ! command -v java &> /dev/null; then
    echo -e "${YELLOW}Java not found. Installing OpenJDK 17...${NC}"
    sudo apt install -y openjdk-17-jdk
else
    echo -e "${GREEN}✓ Java already installed${NC}"
    java -version
fi

# Set JAVA_HOME
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
export PATH=$JAVA_HOME/bin:$PATH

echo -e "${GREEN}✓ JAVA_HOME set to: ${JAVA_HOME}${NC}"

# Make JAVA_HOME persistent (add to ~/.bashrc if not already there)
if ! grep -q "JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64" ~/.bashrc; then
    echo "" >> ~/.bashrc
    echo "# Java configuration for Valhalla JNI" >> ~/.bashrc
    echo "export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64" >> ~/.bashrc
    echo "export PATH=\$JAVA_HOME/bin:\$PATH" >> ~/.bashrc
    echo -e "${GREEN}✓ JAVA_HOME added to ~/.bashrc${NC}"
fi

echo ""

################################################################################
# Step 3: Verify Pre-built Valhalla Library
################################################################################
echo -e "${GREEN}Step 3: Verifying pre-built Valhalla library...${NC}"

if [ ! -f "${NATIVE_LIB_DIR}/libvalhalla.so.3.6.2" ]; then
    echo -e "${RED}ERROR: Pre-built Valhalla library not found!${NC}"
    echo -e "${RED}Expected: ${NATIVE_LIB_DIR}/libvalhalla.so.3.6.2${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Found libvalhalla.so.3.6.2${NC}"

# Create symlinks for the library
cd "${NATIVE_LIB_DIR}"
sudo ln -sf libvalhalla.so.3.6.2 libvalhalla.so.3 2>/dev/null || true
sudo ln -sf libvalhalla.so.3.6.2 libvalhalla.so 2>/dev/null || true
echo -e "${GREEN}✓ Created symlinks for libvalhalla.so${NC}"

# Set library path
export LD_LIBRARY_PATH="${NATIVE_LIB_DIR}:${LD_LIBRARY_PATH}"
echo -e "${GREEN}✓ LD_LIBRARY_PATH set${NC}"
echo ""

################################################################################
# Step 4: Build Native JNI Library
################################################################################
echo -e "${GREEN}Step 4: Building native JNI library (libvalhalla_jni.so)...${NC}"

cd "${JAVA_BINDINGS_DIR}"

# Create build directory
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

# Clean previous build
echo -e "${YELLOW}Cleaning previous build...${NC}"
rm -rf *

# Configure with CMake
echo -e "${YELLOW}Configuring CMake...${NC}"
cmake .. \
  -DCMAKE_BUILD_TYPE=Release \
  -DVALHALLA_SOURCE_DIR="${PROJECT_ROOT}"

if [ $? -ne 0 ]; then
    echo -e "${RED}ERROR: CMake configuration failed!${NC}"
    exit 1
fi

echo -e "${GREEN}✓ CMake configuration successful${NC}"

# Build the JNI library
echo -e "${YELLOW}Compiling JNI library...${NC}"
cmake --build . --config Release

if [ $? -ne 0 ]; then
    echo -e "${RED}ERROR: JNI library build failed!${NC}"
    exit 1
fi

echo -e "${GREEN}✓ JNI library built successfully${NC}"

# Verify the library was created
if [ ! -f "${BUILD_DIR}/libs/native/libvalhalla_jni.so" ]; then
    echo -e "${RED}ERROR: libvalhalla_jni.so was not created!${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Found libvalhalla_jni.so${NC}"
echo ""

################################################################################
# Step 5: Copy JNI Library to Resources
################################################################################
echo -e "${GREEN}Step 5: Copying JNI library to resources...${NC}"

cp "${BUILD_DIR}/libs/native/libvalhalla_jni.so" "${NATIVE_LIB_DIR}/"

if [ $? -ne 0 ]; then
    echo -e "${RED}ERROR: Failed to copy JNI library!${NC}"
    exit 1
fi

echo -e "${GREEN}✓ JNI library copied to: ${NATIVE_LIB_DIR}/libvalhalla_jni.so${NC}"

# Verify the copied file
ls -lh "${NATIVE_LIB_DIR}/libvalhalla_jni.so"
echo ""

################################################################################
# Step 6: Build JAR with Gradle
################################################################################
echo -e "${GREEN}Step 6: Building JAR with Gradle...${NC}"

cd "${JAVA_BINDINGS_DIR}"

# Make gradlew executable
chmod +x gradlew

# Clean and build
echo -e "${YELLOW}Running Gradle clean build...${NC}"
./gradlew clean build

if [ $? -ne 0 ]; then
    echo -e "${RED}ERROR: Gradle build failed!${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Gradle build successful${NC}"
echo ""

################################################################################
# Step 7: Verify Build Artifacts
################################################################################
echo -e "${GREEN}Step 7: Verifying build artifacts...${NC}"

cd "${JAVA_BINDINGS_DIR}"

echo ""
echo -e "${BLUE}Built JAR files:${NC}"
ls -lh build/libs/*.jar

echo ""
echo -e "${BLUE}Test Results:${NC}"
if [ -f "build/reports/tests/test/index.html" ]; then
    echo -e "${GREEN}✓ Test report available at: build/reports/tests/test/index.html${NC}"
else
    echo -e "${YELLOW}⚠ No test report found${NC}"
fi

echo ""

################################################################################
# Summary
################################################################################
echo -e "${BLUE}========================================${NC}"
echo -e "${GREEN}✓ Build Complete!${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo -e "${BLUE}Built Artifacts:${NC}"
echo -e "  Main JAR:    ${JAVA_BINDINGS_DIR}/build/libs/valhalla-jni-*.jar"
echo -e "  Sources JAR: ${JAVA_BINDINGS_DIR}/build/libs/valhalla-jni-*-sources.jar"
echo -e "  Javadoc JAR: ${JAVA_BINDINGS_DIR}/build/libs/valhalla-jni-*-javadoc.jar"
echo ""
echo -e "${BLUE}Native Libraries:${NC}"
echo -e "  JNI Library: ${NATIVE_LIB_DIR}/libvalhalla_jni.so"
echo ""
echo -e "${BLUE}Next Steps:${NC}"
echo -e "  Run tests:     ./gradlew test"
echo -e "  Rebuild:       ./gradlew clean build"
echo -e "  Quick build:   ./gradlew assemble"
echo -e "  Publish local: ./gradlew publishToMavenLocal"
echo ""
