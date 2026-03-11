#!/bin/bash
#
# Validate Valhalla Tiles
# Checks if tiles were built correctly and are accessible
#
# Usage:
#   ./validate-tiles.sh singapore
#   ./validate-tiles.sh [region-name] [OPTIONS]
#
# Options:
#   --tile-dir <path>    Root directory for tile output
#                        (env: VALHALLA_TILE_DIR, default: <project-root>/data/valhalla_tiles)
#   --admin-dir <path>   Directory containing admin SQLite database
#                        (env: VALHALLA_ADMIN_DIR, default: <project-root>/data/admin_data)
#   --config <path>      Path to regions.json config file
#                        (env: VALHALLA_REGIONS_CONFIG)
#
# Environment variables:
#   VALHALLA_TILE_DIR    Override tile root directory
#   VALHALLA_ADMIN_DIR   Override admin database directory
#   VALHALLA_REGIONS_CONFIG  Override regions config file path
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

# ---------------------------------------------------------------------------
# Load pipeline config file
# ---------------------------------------------------------------------------
load_pipeline_config() {
    local config_file="${1:-}"

    if [[ -z "${config_file}" ]]; then
        if [[ -n "${VALHALLA_PIPELINE_CONFIG:-}" && -f "${VALHALLA_PIPELINE_CONFIG}" ]]; then
            config_file="${VALHALLA_PIPELINE_CONFIG}"
        else
            local env="${VALHALLA_ENV:-local}"
            local env_conf="${PROJECT_ROOT}/deploy/config/pipeline.${env}.conf"
            local local_conf="${PROJECT_ROOT}/deploy/config/pipeline.local.conf"
            if [[ -f "${env_conf}" ]]; then
                config_file="${env_conf}"
            elif [[ -f "${local_conf}" ]]; then
                config_file="${local_conf}"
            fi
        fi
    fi

    if [[ -n "${config_file}" && -f "${config_file}" ]]; then
        # shellcheck source=/dev/null
        source "${config_file}"
        echo -e "${YELLOW}[i]${NC} Loaded pipeline config: ${config_file}"
    fi
}

REGIONS_CONFIG=""

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

print_warning() {
    echo -e "${YELLOW}[⚠]${NC} $1"
}

# Validate tiles
validate_tiles() {
    local region=$1

    print_header "Validating Valhalla Tiles for ${region}"

    # Check jq
    if ! command -v jq &> /dev/null; then
        print_error "jq is required. Please install it."
        exit 1
    fi

    # Get region config
    if [[ ! -f "${REGIONS_CONFIG}" ]]; then
        print_error "Regions config not found: ${REGIONS_CONFIG}"
        exit 1
    fi

    if ! jq -e ".regions.${region}" "${REGIONS_CONFIG}" > /dev/null 2>&1; then
        print_error "Region '${region}' not found"
        exit 1
    fi

    REGION_NAME=$(jq -r ".regions.${region}.name" "${REGIONS_CONFIG}")
    REGION_TILE_SUBDIR=$(jq -r ".regions.${region}.tile_dir" "${REGIONS_CONFIG}")
    TILE_DIR="${TILE_DIR_ROOT}/${REGION_TILE_SUBDIR}"

    echo ""
    print_info "Region: ${REGION_NAME}"
    print_info "Tile dir root: ${TILE_DIR_ROOT}"
    print_info "Tile directory: ${TILE_DIR}"
    echo ""

    # Test 1: Check if tile directory exists
    print_info "Test 1: Checking tile directory..."
    if [[ -d "${TILE_DIR}" ]]; then
        print_success "Tile directory exists"
    else
        print_error "Tile directory not found: ${TILE_DIR}"
        exit 1
    fi

    # Test 2: Check if tiles exist
    print_info "Test 2: Checking for tile files..."
    TILE_COUNT=$(find "${TILE_DIR}" -name "*.gph" 2>/dev/null | wc -l)

    if [[ ${TILE_COUNT} -gt 0 ]]; then
        print_success "Found ${TILE_COUNT} tile files"
    else
        print_error "No tile files (.gph) found"
        echo "  Please build tiles first:"
        echo "  ./scripts/regions/build-tiles.sh ${region}"
        exit 1
    fi

    # Test 3: Check tile size
    print_info "Test 3: Checking tile size..."
    TILE_SIZE=$(du -sh "${TILE_DIR}" 2>/dev/null | cut -f1)
    TILE_SIZE_MB=$(du -m "${TILE_DIR}" 2>/dev/null | cut -f1)

    if [[ ${TILE_SIZE_MB} -gt 10 ]]; then
        print_success "Total tile size: ${TILE_SIZE}"
    else
        print_warning "Tile size seems small: ${TILE_SIZE}"
        print_warning "Expected at least 10 MB for most regions"
    fi

    # Test 4: Check tile hierarchy
    print_info "Test 4: Checking tile hierarchy..."
    LEVEL_DIRS=$(find "${TILE_DIR}" -maxdepth 1 -type d -name "[0-9]" | wc -l)

    if [[ ${LEVEL_DIRS} -gt 0 ]]; then
        print_success "Found ${LEVEL_DIRS} tile level directories"
        echo "  Levels found:"
        find "${TILE_DIR}" -maxdepth 1 -type d -name "[0-9]" | while read -r dir; do
            level=$(basename "$dir")
            count=$(find "$dir" -name "*.gph" | wc -l)
            echo "    Level ${level}: ${count} tiles"
        done
    else
        print_warning "No standard level directories (0/, 1/, 2/) found"
    fi

    # Test 5: Check admin data
    print_info "Test 5: Checking admin data..."
    ADMIN_DB="${ADMIN_DIR}/admins.sqlite"

    if [[ -f "${ADMIN_DB}" ]]; then
        admin_size=$(du -h "${ADMIN_DB}" | cut -f1)
        print_success "Admin database found (${admin_size})"
    else
        print_warning "Admin database not found (optional)"
        print_info "  Expected: ${ADMIN_DB}"
        print_info "  Set VALHALLA_ADMIN_DIR or use --admin-dir to override"
    fi

    # Test 6: Check region bounds
    print_info "Test 6: Checking region coverage..."
    MIN_LAT=$(jq -r ".regions.${region}.bounds.min_lat" "${REGIONS_CONFIG}")
    MAX_LAT=$(jq -r ".regions.${region}.bounds.max_lat" "${REGIONS_CONFIG}")
    MIN_LON=$(jq -r ".regions.${region}.bounds.min_lon" "${REGIONS_CONFIG}")
    MAX_LON=$(jq -r ".regions.${region}.bounds.max_lon" "${REGIONS_CONFIG}")

    print_info "  Latitude:  ${MIN_LAT} to ${MAX_LAT}"
    print_info "  Longitude: ${MIN_LON} to ${MAX_LON}"

    # Test 7: Sample tile file check
    print_info "Test 7: Checking sample tile integrity..."
    SAMPLE_TILE=$(find "${TILE_DIR}" -name "*.gph" | head -1)

    if [[ -n "${SAMPLE_TILE}" ]]; then
        if [[ -r "${SAMPLE_TILE}" ]]; then
            tile_size=$(du -h "${SAMPLE_TILE}" | cut -f1)
            print_success "Sample tile is readable (${tile_size})"
        else
            print_error "Sample tile is not readable: ${SAMPLE_TILE}"
            exit 1
        fi
    fi

    # Summary
    echo ""
    print_header "Validation Summary"
    echo ""
    echo "Region:     ${REGION_NAME}"
    echo "Tile dir:   ${TILE_DIR}"
    echo "Tile count: ${TILE_COUNT}"
    echo "Total size: ${TILE_SIZE}"
    echo "Levels:     ${LEVEL_DIRS}"
    echo ""
    print_success "All validation tests passed!"
    echo ""

    # Next steps
    print_info "Next steps:"
    echo ""
    echo "1. Test with Java/Kotlin JNI:"
    echo "   cd src/bindings/java"
    echo "   VALHALLA_TILE_DIR=${TILE_DIR_ROOT} ./gradlew test"
    echo ""
    echo "2. Or use valhalla_service (if installed):"
    echo "   VALHALLA_TILE_DIR=${TILE_DIR_ROOT} valhalla_service <config-file>"
    echo ""
}

# Show usage
show_usage() {
    echo "Usage: $0 <region-name> [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --tile-dir <path>   Tile root directory (env: VALHALLA_TILE_DIR)"
    echo "  --admin-dir <path>  Admin DB directory (env: VALHALLA_ADMIN_DIR)"
    echo "  --config <path>     Regions config file (env: VALHALLA_REGIONS_CONFIG)"
    echo "  -h, --help          Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 singapore"
    echo "  $0 thailand --tile-dir /mnt/tiles"
    echo "  VALHALLA_TILE_DIR=/var/valhalla/tiles $0 singapore"
    echo ""
}

# Main
main() {
    if [[ $# -eq 0 ]]; then
        show_usage
        exit 1
    fi

    local region=$1
    shift
    local pipeline_config_file=""
    local tile_dir_override=""
    local admin_dir_override=""
    local regions_config_override=""

    # Parse optional arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --pipeline-config)
                pipeline_config_file="$2"
                shift 2
                ;;
            --tile-dir)
                tile_dir_override="$2"
                shift 2
                ;;
            --admin-dir)
                admin_dir_override="$2"
                shift 2
                ;;
            --config)
                regions_config_override="$2"
                shift 2
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                print_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done

    # Load pipeline config first
    load_pipeline_config "${pipeline_config_file}"

    # CLI flags override config file values
    TILE_DIR_ROOT="${tile_dir_override:-${VALHALLA_TILE_DIR:-${PROJECT_ROOT}/data/valhalla_tiles}}"
    ADMIN_DIR="${admin_dir_override:-${VALHALLA_ADMIN_DIR:-${PROJECT_ROOT}/data/admin_data}}"
    REGIONS_CONFIG="${regions_config_override:-${VALHALLA_REGIONS_CONFIG:-${PROJECT_ROOT}/config/regions/regions.json}}"

    validate_tiles "${region}"
}

main "$@"
