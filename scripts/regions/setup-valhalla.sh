#!/usr/bin/env bash

set -euo pipefail

# ============================================================================
# Valhalla Automated Setup Script
# ============================================================================
#
# This script automatically detects your system environment and sets up
# Valhalla routing engine with Singapore region support.
#
# Features:
# - Auto-detects OS (Windows/Linux/macOS)
# - Auto-detects available tools (Python/Docker)
# - Recommends best installation method
# - Downloads OSM data
# - Builds routing tiles
# - Validates installation
# - Runs tests
#
# Usage:
#   ./setup-valhalla.sh [OPTIONS]
#
# Options:
#   --method METHOD      Force installation method (python|docker)
#   --region REGION      Region to setup (default: singapore)
#   --skip-install       Skip Valhalla tools installation
#   --skip-download      Skip OSM data download
#   --skip-build         Skip tile building
#   --skip-validate      Skip tile validation
#   --skip-test          Skip JNI tests
#   --help               Show this help message
#
# Examples:
#   ./setup-valhalla.sh                    # Full automated setup
#   ./setup-valhalla.sh --method docker    # Force Docker method
#   ./setup-valhalla.sh --region thailand  # Setup Thailand
#   ./setup-valhalla.sh --skip-install     # Tools already installed
#
# ============================================================================

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default options
INSTALL_METHOD=""
REGION="singapore"
SKIP_INSTALL=false
SKIP_DOWNLOAD=false
SKIP_BUILD=false
SKIP_VALIDATE=false
SKIP_TEST=false
SKIP_ELEVATION=false

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

# ============================================================================
# Helper Functions
# ============================================================================

print_header() {
    echo ""
    echo -e "${BLUE}============================================================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}============================================================================${NC}"
    echo ""
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

print_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

show_help() {
    cat << EOF
Valhalla Automated Setup Script

Usage:
  ./setup-valhalla.sh [OPTIONS]

Options:
  --method METHOD      Force installation method (python|docker)
  --region REGION      Region to setup (default: singapore)
  --skip-install       Skip Valhalla tools installation
  --skip-download      Skip OSM data download
  --skip-build         Skip tile building
  --skip-validate      Skip tile validation
  --skip-test          Skip JNI tests
  --help               Show this help message

Installation Methods:
  python              Install via pyvalhalla (pip install pyvalhalla)
  docker              Install via Docker (docker pull valhalla)

Examples:
  # Full automated setup
  ./setup-valhalla.sh

  # Force Docker method
  ./setup-valhalla.sh --method docker

  # Setup Thailand region
  ./setup-valhalla.sh --region thailand

  # Only download and build (tools already installed)
  ./setup-valhalla.sh --skip-install

For more information, see: docs/singapore/SETUP_GUIDE.md
EOF
}

# ============================================================================
# System Detection
# ============================================================================

detect_os() {
    local os_name=""

    case "$(uname -s)" in
        Linux*)     os_name="Linux";;
        Darwin*)    os_name="macOS";;
        CYGWIN*|MINGW*|MSYS*) os_name="Windows";;
        *)          os_name="Unknown";;
    esac

    echo "$os_name"
}

check_python() {
    if command -v python3 &> /dev/null; then
        local version=$(python3 --version 2>&1 | awk '{print $2}')
        local major=$(echo "$version" | cut -d. -f1)
        local minor=$(echo "$version" | cut -d. -f2)

        if [ "$major" -ge 3 ] && [ "$minor" -ge 8 ]; then
            echo "python3"
            return 0
        fi
    fi

    if command -v python &> /dev/null; then
        local version=$(python --version 2>&1 | awk '{print $2}')
        local major=$(echo "$version" | cut -d. -f1)
        local minor=$(echo "$version" | cut -d. -f2)

        if [ "$major" -ge 3 ] && [ "$minor" -ge 8 ]; then
            echo "python"
            return 0
        fi
    fi

    return 1
}

check_docker() {
    if command -v docker &> /dev/null; then
        if docker ps &> /dev/null; then
            echo "docker"
            return 0
        fi
    fi
    return 1
}

check_valhalla_installed() {
    # Check if valhalla is already installed
    if command -v valhalla_build_tiles &> /dev/null; then
        echo "native"
        return 0
    fi

    # Check pyvalhalla
    local python_cmd=$(check_python)
    if [ $? -eq 0 ]; then
        if $python_cmd -m valhalla --version &> /dev/null; then
            echo "python"
            return 0
        fi
    fi

    # Check docker
    if check_docker &> /dev/null; then
        if docker image inspect ghcr.io/valhalla/valhalla:latest &> /dev/null; then
            echo "docker"
            return 0
        fi
    fi

    return 1
}

detect_best_method() {
    local os_name=$(detect_os)
    local python_cmd=$(check_python 2>/dev/null)
    local docker_available=$(check_docker 2>/dev/null)

    print_info "Detected OS: $os_name"

    # Check what's available
    if [ $? -eq 0 ] && [ -n "$python_cmd" ]; then
        print_info "Python 3.8+ detected: $($python_cmd --version)"
    else
        print_warning "Python 3.8+ not detected"
    fi

    if [ -n "$docker_available" ]; then
        print_info "Docker detected: $(docker --version | head -1)"
    else
        print_warning "Docker not detected"
    fi

    echo ""

    # Recommend method based on OS and available tools
    case "$os_name" in
        Windows)
            if [ -n "$python_cmd" ]; then
                echo "python"
            elif [ -n "$docker_available" ]; then
                echo "docker"
            else
                echo "none"
            fi
            ;;
        Linux)
            if [ -n "$docker_available" ]; then
                echo "docker"
            elif [ -n "$python_cmd" ]; then
                echo "python"
            else
                echo "none"
            fi
            ;;
        macOS)
            if [ -n "$python_cmd" ]; then
                echo "python"
            elif [ -n "$docker_available" ]; then
                echo "docker"
            else
                echo "none"
            fi
            ;;
        *)
            echo "none"
            ;;
    esac
}

# ============================================================================
# Installation Functions
# ============================================================================

install_python_valhalla() {
    print_header "Installing Valhalla via Python (pyvalhalla)"

    local python_cmd=$(check_python)
    if [ $? -ne 0 ]; then
        print_error "Python 3.8+ not found. Please install Python first."
        print_info "Visit: https://www.python.org/downloads/"
        exit 1
    fi

    print_info "Using Python: $($python_cmd --version)"
    print_info "Installing pyvalhalla..."

    if $python_cmd -m pip install pyvalhalla; then
        print_success "pyvalhalla installed successfully"

        # Verify installation
        if $python_cmd -m valhalla --version &> /dev/null; then
            print_success "Valhalla tools verified"
            echo ""
            print_info "Installed version: $($python_cmd -m valhalla --version 2>&1)"
        else
            print_error "Installation verification failed"
            exit 1
        fi
    else
        print_error "Failed to install pyvalhalla"
        print_info "Try: pip install --upgrade pip"
        exit 1
    fi
}

install_docker_valhalla() {
    print_header "Installing Valhalla via Docker"

    if ! check_docker &> /dev/null; then
        print_error "Docker not found or not running"
        print_info "Please install Docker first: https://docs.docker.com/get-docker/"
        exit 1
    fi

    print_info "Using Docker: $(docker --version | head -1)"
    print_info "Pulling Valhalla Docker image..."

    if docker pull ghcr.io/valhalla/valhalla:latest; then
        print_success "Docker image pulled successfully"

        # Verify installation
        if docker run --rm ghcr.io/valhalla/valhalla:latest --version &> /dev/null; then
            print_success "Valhalla tools verified"
            echo ""
            print_info "Installed version: $(docker run --rm ghcr.io/valhalla/valhalla:latest --version 2>&1 | head -1)"
        else
            print_error "Installation verification failed"
            exit 1
        fi
    else
        print_error "Failed to pull Docker image"
        exit 1
    fi
}

# ============================================================================
# Setup Functions
# ============================================================================

download_osm_data() {
    print_header "Downloading OSM Data for ${REGION^}"

    local download_script="${SCRIPT_DIR}/download-region-osm.sh"

    if [ ! -f "$download_script" ]; then
        print_error "Download script not found: $download_script"
        exit 1
    fi

    print_info "Running: $download_script $REGION"

    if bash "$download_script" "$REGION"; then
        print_success "OSM data downloaded successfully"
    else
        print_error "Failed to download OSM data"
        exit 1
    fi
}

build_tiles() {
    print_header "Building Routing Tiles for ${REGION^}"

    local build_script="${SCRIPT_DIR}/build-tiles.sh"

    if [ ! -f "$build_script" ]; then
        print_error "Build script not found: $build_script"
        exit 1
    fi

    # Ask about elevation if not already specified
    if [ "$SKIP_ELEVATION" = false ]; then
        echo ""
        print_info "Elevation data provides hill/slope information for routes"
        print_info "For Singapore (mostly flat terrain), elevation is optional"
        echo ""
        print_warning "Note: Elevation processing can take 30-60+ minutes due to data downloads"
        print_info "Recommended: Skip elevation for faster builds (~15-20 min vs 60+ min)"
        echo ""
        read -p "Include elevation data in tiles? (y/N): " response
        if [[ ! "${response}" =~ ^[Yy]$ ]]; then
            SKIP_ELEVATION=true
            print_info "Elevation processing will be skipped"
        else
            print_info "Elevation processing will be included"
        fi
        echo ""
    fi

    local elevation_flag=""
    if [ "$SKIP_ELEVATION" = true ]; then
        elevation_flag="--no-elevation"
        print_info "Running: $build_script $REGION $elevation_flag"
        print_info "Estimated time: 15-20 minutes"
    else
        print_info "Running: $build_script $REGION"
        print_warning "This may take 60+ minutes (elevation data download)..."
    fi
    echo ""

    if bash "$build_script" "$REGION" $elevation_flag; then
        print_success "Tiles built successfully"
    else
        print_error "Failed to build tiles"
        exit 1
    fi
}

validate_tiles() {
    print_header "Validating Tiles for ${REGION^}"

    local validate_script="${SCRIPT_DIR}/validate-tiles.sh"

    if [ ! -f "$validate_script" ]; then
        print_error "Validate script not found: $validate_script"
        exit 1
    fi

    print_info "Running: $validate_script $REGION"

    if bash "$validate_script" "$REGION"; then
        print_success "Tile validation passed"
    else
        print_error "Tile validation failed"
        exit 1
    fi
}

run_tests() {
    print_header "Running JNI Tests"

    local java_dir="${ROOT_DIR}/src/bindings/java"

    if [ ! -d "$java_dir" ]; then
        print_error "Java bindings directory not found: $java_dir"
        exit 1
    fi

    cd "$java_dir"

    print_info "Running: ./gradlew test --tests \"SingaporeRideHaulingTest\""
    echo ""

    if [ "$(uname -s)" = "Linux" ] || [ "$(uname -s)" = "Darwin" ]; then
        ./gradlew test --tests "SingaporeRideHaulingTest"
    else
        # Windows with Git Bash
        ./gradlew.bat test --tests "SingaporeRideHaulingTest" || ./gradlew test --tests "SingaporeRideHaulingTest"
    fi

    local exit_code=$?

    cd - > /dev/null

    if [ $exit_code -eq 0 ]; then
        print_success "All tests passed"
    else
        print_error "Some tests failed"
        exit 1
    fi
}

# ============================================================================
# Main Script
# ============================================================================

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --method)
                INSTALL_METHOD="$2"
                shift 2
                ;;
            --region)
                REGION="$2"
                shift 2
                ;;
            --skip-install)
                SKIP_INSTALL=true
                shift
                ;;
            --skip-download)
                SKIP_DOWNLOAD=true
                shift
                ;;
            --skip-build)
                SKIP_BUILD=true
                shift
                ;;
            --skip-validate)
                SKIP_VALIDATE=true
                shift
                ;;
            --skip-test)
                SKIP_TEST=true
                shift
                ;;
            --help)
                show_help
                exit 0
                ;;
            *)
                print_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

main() {
    parse_args "$@"

    print_header "Valhalla Automated Setup"

    print_info "Region: ${REGION^}"
    print_info "Root directory: $ROOT_DIR"
    echo ""

    # Check if already installed
    if [ "$SKIP_INSTALL" = false ]; then
        local installed_method=$(check_valhalla_installed)

        if [ $? -eq 0 ]; then
            print_success "Valhalla is already installed (method: $installed_method)"
            SKIP_INSTALL=true
        else
            # Determine installation method
            if [ -z "$INSTALL_METHOD" ]; then
                print_info "Auto-detecting best installation method..."
                echo ""
                INSTALL_METHOD=$(detect_best_method)

                if [ "$INSTALL_METHOD" = "none" ]; then
                    print_error "No suitable installation method found"
                    echo ""
                    print_info "Please install one of the following:"
                    print_info "  - Python 3.8+ (recommended for Windows/macOS)"
                    print_info "  - Docker (recommended for Linux)"
                    echo ""
                    print_info "Then run this script again"
                    exit 1
                fi

                print_success "Recommended method: ${INSTALL_METHOD}"
                echo ""
            fi

            # Install Valhalla
            case "$INSTALL_METHOD" in
                python)
                    install_python_valhalla
                    ;;
                docker)
                    install_docker_valhalla
                    ;;
                *)
                    print_error "Invalid installation method: $INSTALL_METHOD"
                    print_info "Valid methods: python, docker"
                    exit 1
                    ;;
            esac
        fi
    else
        print_info "Skipping installation (--skip-install)"
    fi

    # Download OSM data
    if [ "$SKIP_DOWNLOAD" = false ]; then
        download_osm_data
    else
        print_info "Skipping OSM download (--skip-download)"
    fi

    # Build tiles
    if [ "$SKIP_BUILD" = false ]; then
        build_tiles
    else
        print_info "Skipping tile building (--skip-build)"
    fi

    # Validate tiles
    if [ "$SKIP_VALIDATE" = false ]; then
        validate_tiles
    else
        print_info "Skipping tile validation (--skip-validate)"
    fi

    # Run tests
    if [ "$SKIP_TEST" = false ]; then
        run_tests
    else
        print_info "Skipping tests (--skip-test)"
    fi

    # Final summary
    print_header "Setup Complete! 🎉"

    print_success "Valhalla is ready to use"
    echo ""
    print_info "Quick start with JNI:"
    echo ""
    echo "  import global.tada.valhalla.Actor"
    echo ""
    echo "  val actor = Actor.createSingapore()"
    echo "  val result = actor.route(requestJson)"
    echo "  actor.close()"
    echo ""
    print_info "For more information, see:"
    print_info "  - docs/singapore/SINGAPORE_QUICKSTART.md"
    print_info "  - docs/singapore/SETUP_GUIDE.md"
    echo ""
}

# Run main function
main "$@"
