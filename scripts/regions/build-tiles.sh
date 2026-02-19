#!/bin/bash
#
# Build Valhalla Tiles from OSM Data
# Generic script that works for any region configured in regions.json
#
# Usage:
#   ./build-tiles.sh singapore
#   ./build-tiles.sh thailand
#   ./build-tiles.sh [region-name] [--clean]
#

set -e

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Script paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Configuration
REGIONS_CONFIG="${PROJECT_ROOT}/config/regions/regions.json"
CONFIG_TEMPLATE="${PROJECT_ROOT}/config/regions/singapore/valhalla-singapore.json"
LOG_DIR="${PROJECT_ROOT}/logs"

# Helper functions
print_header() {
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}$1${NC}"
    echo -e "${CYAN}========================================${NC}"
}

print_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1"
}

print_info() {
    echo -e "${YELLOW}[i]${NC} $1"
}

print_status() {
    echo -e "${CYAN}[→]${NC} $1"
}

log_and_print() {
    echo "$1" | tee -a "${BUILD_LOG}"
}

# Check dependencies
check_dependencies() {
    local missing_deps=()

    if ! command -v jq &> /dev/null; then
        missing_deps+=("jq")
    fi

    # Check for valhalla_build_tiles or Docker
    USE_DOCKER=false
    if command -v valhalla_build_tiles &> /dev/null; then
        print_info "Using native Valhalla installation"
    elif command -v docker &> /dev/null && docker image inspect ghcr.io/valhalla/valhalla:latest &> /dev/null; then
        print_info "Using Docker-based Valhalla"
        USE_DOCKER=true
    else
        missing_deps+=("valhalla_build_tiles or docker")
    fi

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        print_error "Missing dependencies: ${missing_deps[*]}"
        echo ""
        echo "Please install:"
        for dep in "${missing_deps[@]}"; do
            case $dep in
                jq)
                    echo "  - jq: sudo apt-get install jq  (or brew install jq)"
                    ;;
                "valhalla_build_tiles or docker")
                    echo "  - Valhalla tools: Follow instructions at https://github.com/valhalla/valhalla"
                    echo "    Or use Docker: docker pull ghcr.io/valhalla/valhalla:latest"
                    ;;
            esac
        done
        exit 1
    fi
}

# Get region configuration
get_region_config() {
    local region=$1

    if [[ ! -f "${REGIONS_CONFIG}" ]]; then
        print_error "Regions config not found: ${REGIONS_CONFIG}"
        exit 1
    fi

    # Check if region exists
    if ! jq -e ".regions.${region}" "${REGIONS_CONFIG}" > /dev/null 2>&1; then
        print_error "Region '${region}' not found in config"
        echo ""
        echo "Available regions:"
        jq -r '.regions | keys[]' "${REGIONS_CONFIG}" | sed 's/^/  - /'
        exit 1
    fi

    # Extract region info
    REGION_NAME=$(jq -r ".regions.${region}.name" "${REGIONS_CONFIG}")
    TILE_DIR=$(jq -r ".regions.${region}.tile_dir" "${REGIONS_CONFIG}")
    TILE_DIR="${PROJECT_ROOT}/${TILE_DIR}"
    OSM_FILE="${PROJECT_ROOT}/data/osm/${region}-latest.osm.pbf"

    print_info "Region: ${REGION_NAME}"
    print_info "Tile directory: ${TILE_DIR}"
    print_info "OSM file: ${OSM_FILE}"
}

# Build tiles
build_tiles() {
    local region=$1
    local clean_build=$2
    local skip_elevation=$3

    print_header "Building Valhalla Tiles for ${REGION_NAME}"

    # Create directories
    mkdir -p "${LOG_DIR}"
    mkdir -p "${TILE_DIR}"
    BUILD_LOG="${LOG_DIR}/tile-build-${region}-$(date +%Y%m%d-%H%M%S).log"

    # Verify OSM file exists
    if [[ ! -f "${OSM_FILE}" ]]; then
        print_error "OSM file not found: ${OSM_FILE}"
        echo ""
        echo "Please download OSM data first:"
        echo "  ./scripts/regions/download-region-osm.sh ${region}"
        exit 1
    fi

    print_success "OSM file found"
    file_size=$(du -h "${OSM_FILE}" | cut -f1)
    log_and_print "OSM file size: ${file_size}"

    # Clean existing tiles if requested
    if [[ "${clean_build}" == true ]]; then
        if [[ -d "${TILE_DIR}" ]] && [[ -n "$(ls -A "${TILE_DIR}" 2>/dev/null)" ]]; then
            print_info "Cleaning existing tiles..."
            rm -rf "${TILE_DIR:?}"/*
            print_success "Tiles cleaned"
        fi
    fi

    # Check if tiles already exist
    if [[ -n "$(ls -A "${TILE_DIR}" 2>/dev/null)" ]]; then
        print_info "Tiles already exist in ${TILE_DIR}"
        tile_count=$(find "${TILE_DIR}" -name "*.gph" 2>/dev/null | wc -l)
        print_info "Existing tile count: ${tile_count}"
        echo ""
        read -p "Rebuild tiles? This will delete existing tiles. (y/N): " response
        if [[ ! "${response}" =~ ^[Yy]$ ]]; then
            print_success "Using existing tiles"
            return 0
        fi
        rm -rf "${TILE_DIR:?}"/*
    fi

    # Create build config from template
    print_status "Creating build configuration..."
    TEMP_CONFIG="${PROJECT_ROOT}/data/valhalla-build-${region}.json"

    # Copy template and update paths
    cp "${CONFIG_TEMPLATE}" "${TEMP_CONFIG}"

    # Use sed to update paths (works on both Linux and macOS)
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        sed -i '' "s|data/valhalla_tiles/singapore|${TILE_DIR}|g" "${TEMP_CONFIG}"
        sed -i '' "s|data/admin_data|${PROJECT_ROOT}/data/admin_data|g" "${TEMP_CONFIG}"
    else
        # Linux/Windows Git Bash
        sed -i "s|data/valhalla_tiles/singapore|${TILE_DIR}|g" "${TEMP_CONFIG}"
        sed -i "s|data/admin_data|${PROJECT_ROOT}/data/admin_data|g" "${TEMP_CONFIG}"
    fi

    # Remove elevation section if --no-elevation is specified
    if [[ "${skip_elevation}" == true ]]; then
        print_info "Elevation processing disabled (--no-elevation)"
        # Use jq to remove the additional_data.elevation section
        jq 'del(.additional_data.elevation)' "${TEMP_CONFIG}" > "${TEMP_CONFIG}.tmp"
        mv "${TEMP_CONFIG}.tmp" "${TEMP_CONFIG}"
    else
        print_info "Elevation processing enabled (this may take longer)"
    fi

    print_success "Build config created: ${TEMP_CONFIG}"

    # Display build configuration
    echo ""
    log_and_print "Build Configuration:"
    log_and_print "  Region:      ${REGION_NAME}"
    log_and_print "  OSM Input:   ${OSM_FILE}"
    log_and_print "  Tile Output: ${TILE_DIR}"
    log_and_print "  Config:      ${TEMP_CONFIG}"
    log_and_print "  Log File:    ${BUILD_LOG}"
    echo ""

    # Estimate time based on file size
    print_info "Starting tile build process..."
    file_size_mb=$(du -m "${OSM_FILE}" | cut -f1)
    if [[ ${file_size_mb} -lt 100 ]]; then
        print_info "Estimated time: 5-10 minutes"
    elif [[ ${file_size_mb} -lt 500 ]]; then
        print_info "Estimated time: 10-20 minutes"
    else
        print_info "Estimated time: 20-40 minutes"
    fi
    echo ""

    START_TIME=$(date +%s)

    # Build tiles
    print_status "Building tiles (this may take a while)..."

    # Execute valhalla_build_tiles (native or Docker)
    if [[ "${USE_DOCKER}" == true ]]; then
        # For Docker, we need to adjust paths in the config file
        DOCKER_CONFIG="${PROJECT_ROOT}/data/valhalla-build-${region}-docker.json"

        # Convert all paths to Docker mount paths (/data instead of actual paths)
        sed "s|${PROJECT_ROOT}|/data|g" "${TEMP_CONFIG}" > "${DOCKER_CONFIG}"

        print_info "Docker config: ${DOCKER_CONFIG}"

        # Prepare Docker volume mount path based on platform
        DOCKER_MOUNT_PATH="${PROJECT_ROOT}"

        # On Windows (Git Bash/MSYS), convert path and use MSYS_NO_PATHCONV
        if [[ "$(uname -s)" == MINGW* ]] || [[ "$(uname -s)" == MSYS* ]] || [[ "$(uname -s)" == CYGWIN* ]]; then
            # Convert to Windows path (C:/Users/... format)
            DOCKER_MOUNT_PATH=$(cygpath -w "${PROJECT_ROOT}" 2>/dev/null || echo "${PROJECT_ROOT}")
            # Use MSYS_NO_PATHCONV to prevent Git Bash from mangling paths
            if MSYS_NO_PATHCONV=1 docker run --rm \
                -v "${DOCKER_MOUNT_PATH}:/data" \
                ghcr.io/valhalla/valhalla:latest \
                valhalla_build_tiles \
                -c "/data/data/valhalla-build-${region}-docker.json" \
                "/data/data/osm/${region}-latest.osm.pbf" 2>&1 | tee -a "${BUILD_LOG}"; then
                BUILD_SUCCESS=true
            else
                BUILD_SUCCESS=false
            fi
        else
            # Linux and macOS use paths as-is
            if docker run --rm \
                -v "${DOCKER_MOUNT_PATH}:/data" \
                ghcr.io/valhalla/valhalla:latest \
                valhalla_build_tiles \
                -c "/data/data/valhalla-build-${region}-docker.json" \
                "/data/data/osm/${region}-latest.osm.pbf" 2>&1 | tee -a "${BUILD_LOG}"; then
                BUILD_SUCCESS=true
            else
                BUILD_SUCCESS=false
            fi
        fi

        # Cleanup Docker config (but keep TEMP_CONFIG for admin build)
        rm -f "${DOCKER_CONFIG}"
    else
        if valhalla_build_tiles \
            -c "${TEMP_CONFIG}" \
            "${OSM_FILE}" 2>&1 | tee -a "${BUILD_LOG}"; then
            BUILD_SUCCESS=true
        else
            BUILD_SUCCESS=false
        fi
    fi

    if [[ "${BUILD_SUCCESS}" == true ]]; then

        END_TIME=$(date +%s)
        DURATION=$((END_TIME - START_TIME))
        MINUTES=$((DURATION / 60))
        SECONDS=$((DURATION % 60))

        print_success "Tile build completed successfully"
        log_and_print "Build time: ${MINUTES}m ${SECONDS}s"

        # Verify tiles were created
        TILE_COUNT=$(find "${TILE_DIR}" -name "*.gph" 2>/dev/null | wc -l)
        log_and_print "Tiles created: ${TILE_COUNT}"

        if [[ ${TILE_COUNT} -eq 0 ]]; then
            print_error "No tiles were created!"
            echo "Check log file: ${BUILD_LOG}"
            exit 1
        fi

        # Display statistics
        echo ""
        print_info "Tile Statistics:"
        tile_size=$(du -sh "${TILE_DIR}" | cut -f1)
        echo "  Total size: ${tile_size}"
        echo "  Tile count: ${TILE_COUNT}"

        # Build admins database
        if [[ "${USE_DOCKER}" == true ]] || command -v valhalla_build_admins &> /dev/null; then
            echo ""
            print_status "Building administrative boundaries..."
            mkdir -p "${PROJECT_ROOT}/data/admin_data"

            if [[ "${USE_DOCKER}" == true ]]; then
                # Create Docker config for admin build
                DOCKER_ADMIN_CONFIG="${PROJECT_ROOT}/data/valhalla-admin-${region}-docker.json"
                sed "s|${PROJECT_ROOT}|/data|g" "${TEMP_CONFIG}" > "${DOCKER_ADMIN_CONFIG}"

                # Windows/Linux specific Docker execution
                if [[ "$(uname -s)" == MINGW* ]] || [[ "$(uname -s)" == MSYS* ]] || [[ "$(uname -s)" == CYGWIN* ]]; then
                    if MSYS_NO_PATHCONV=1 docker run --rm \
                        -v "${DOCKER_MOUNT_PATH}:/data" \
                        ghcr.io/valhalla/valhalla:latest \
                        valhalla_build_admins \
                        -c "/data/data/valhalla-admin-${region}-docker.json" \
                        "/data/data/osm/${region}-latest.osm.pbf" 2>&1 | tee -a "${BUILD_LOG}"; then
                        print_success "Admin boundaries built"
                    else
                        print_info "Admin boundaries build failed (non-critical)"
                    fi
                else
                    if docker run --rm \
                        -v "${DOCKER_MOUNT_PATH}:/data" \
                        ghcr.io/valhalla/valhalla:latest \
                        valhalla_build_admins \
                        -c "/data/data/valhalla-admin-${region}-docker.json" \
                        "/data/data/osm/${region}-latest.osm.pbf" 2>&1 | tee -a "${BUILD_LOG}"; then
                        print_success "Admin boundaries built"
                    else
                        print_info "Admin boundaries build failed (non-critical)"
                    fi
                fi

                rm -f "${DOCKER_ADMIN_CONFIG}"
            else
                if valhalla_build_admins \
                    -c "${TEMP_CONFIG}" \
                    "${OSM_FILE}" 2>&1 | tee -a "${BUILD_LOG}"; then
                    print_success "Admin boundaries built"
                else
                    print_info "Admin boundaries build failed (non-critical)"
                fi
            fi
        fi

        # Cleanup temp config
        rm -f "${TEMP_CONFIG}"

        echo ""
        print_success "Tile build pipeline completed successfully!"
        echo ""
        print_info "Next steps:"
        echo "  1. Test the tiles:"
        echo "     ./scripts/regions/validate-tiles.sh ${region}"
        echo ""
        echo "  2. Run JNI tests:"
        echo "     cd src/bindings/java"
        echo "     ./gradlew test"
        echo ""

    else
        END_TIME=$(date +%s)
        DURATION=$((END_TIME - START_TIME))

        print_error "Tile build failed after ${DURATION}s"
        echo "Check log file: ${BUILD_LOG}"
        rm -f "${TEMP_CONFIG}"
        exit 1
    fi
}

# Show usage
show_usage() {
    echo "Usage: $0 <region-name> [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --clean         Remove existing tiles before building"
    echo "  --no-elevation  Skip elevation processing (faster, recommended for production)"
    echo ""
    echo "Available regions:"
    if [[ -f "${REGIONS_CONFIG}" ]]; then
        jq -r '.regions | to_entries[] | "  \(.key) - \(.value.name)"' "${REGIONS_CONFIG}"
    fi
    echo ""
    echo "Examples:"
    echo "  $0 singapore"
    echo "  $0 singapore --clean"
    echo "  $0 singapore --no-elevation"
    echo "  $0 singapore --clean --no-elevation"
    echo "  $0 thailand"
    echo ""
}

# Main execution
main() {
    print_header "Valhalla Tile Builder"

    # Parse arguments
    if [[ $# -eq 0 ]]; then
        show_usage
        exit 1
    fi

    local region=$1
    local clean_build=false
    local skip_elevation=false

    # Parse optional arguments
    shift
    while [[ $# -gt 0 ]]; do
        case $1 in
            --clean)
                clean_build=true
                shift
                ;;
            --no-elevation)
                skip_elevation=true
                shift
                ;;
            *)
                print_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done

    # Check dependencies
    check_dependencies

    # Get region config
    get_region_config "${region}"

    # Build tiles
    build_tiles "${region}" "${clean_build}" "${skip_elevation}"

    print_success "Process completed successfully"
}

# Run main
main "$@"
