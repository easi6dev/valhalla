#!/bin/bash
#
# Generic OSM Data Downloader for Multiple Regions
# Downloads OSM extracts from Geofabrik based on region configuration
#
# Usage:
#   ./download-region-osm.sh singapore
#   ./download-region-osm.sh thailand
#   ./download-region-osm.sh [region-name] [OPTIONS]
#
# Options:
#   --osm-dir <path>     Directory to store downloaded OSM files
#                        (env: OSM_DIR, default: <project-root>/data/osm)
#   --config <path>      Path to regions.json config file
#                        (env: VALHALLA_REGIONS_CONFIG, default: <project-root>/config/regions/regions.json)
#   -y, --yes            Skip re-download confirmation prompt
#
# Environment variables:
#   OSM_DIR              Override OSM download directory
#   VALHALLA_REGIONS_CONFIG  Override regions config file path
#

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Flags
AUTO_YES=false

# ---------------------------------------------------------------------------
# Load pipeline config file
# Priority: --pipeline-config flag > VALHALLA_PIPELINE_CONFIG env
#           > pipeline.<VALHALLA_ENV>.conf > pipeline.local.conf > defaults
# ---------------------------------------------------------------------------
load_pipeline_config() {
    local config_file="${1:-}"

    if [[ -z "${config_file}" ]]; then
        if [[ -n "${VALHALLA_PIPELINE_CONFIG:-}" && -f "${VALHALLA_PIPELINE_CONFIG}" ]]; then
            config_file="${VALHALLA_PIPELINE_CONFIG}"
        else
            local env="${VALHALLA_ENV:-local}"
            local env_conf="${PROJECT_ROOT}/config/pipeline/pipeline.${env}.conf"
            local local_conf="${PROJECT_ROOT}/config/pipeline/pipeline.local.conf"
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
    else
        echo -e "${YELLOW}[i]${NC} No pipeline config file found — using defaults"
    fi
}

# Configuration paths — populated after load_pipeline_config is called in main
REGIONS_CONFIG=""
DATA_DIR=""

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

# Check if jq is installed
check_jq() {
    if ! command -v jq &> /dev/null; then
        print_error "jq is not installed. Please install jq to parse JSON."
        echo ""
        echo "Installation:"
        echo "  Ubuntu/Debian: sudo apt-get install jq"
        echo "  macOS:         brew install jq"
        echo "  Windows:       choco install jq  (or download from https://stedolan.github.io/jq/)"
        exit 1
    fi
}

# Parse region from config
get_region_info() {
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

    # Extract region information
    REGION_NAME=$(jq -r ".regions.${region}.name" "${REGIONS_CONFIG}")
    OSM_SOURCE=$(jq -r ".regions.${region}.osm_source" "${REGIONS_CONFIG}")
    REGION_ENABLED=$(jq -r ".regions.${region}.enabled" "${REGIONS_CONFIG}")

    print_info "Region: ${REGION_NAME}"
    print_info "Enabled: ${REGION_ENABLED}"
    print_info "Source: ${OSM_SOURCE}"
}

# Download OSM data
download_osm() {
    local region=$1
    local output_file="${DATA_DIR}/${region}-latest.osm.pbf"
    local md5_url="${OSM_SOURCE}.md5"

    print_header "Downloading OSM Data for ${REGION_NAME}"

    # Create data directory
    mkdir -p "${DATA_DIR}"

    # Check if file already exists
    if [[ -f "${output_file}" ]]; then
        print_info "OSM file already exists: ${output_file}"

        file_size=$(du -h "${output_file}" | cut -f1)
        file_date=$(date -r "${output_file}" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || stat -c %y "${output_file}" 2>/dev/null | cut -d' ' -f1-2)
        print_info "Size: ${file_size}, Last modified: ${file_date}"

        echo ""
        if [[ "${AUTO_YES}" == true ]]; then
            print_info "Re-download skipped (--yes flag set)"
            print_success "Using existing file"
            return 0
        fi

        read -p "Do you want to re-download? (y/N): " response
        if [[ ! "${response}" =~ ^[Yy]$ ]]; then
            print_success "Using existing file"
            return 0
        fi

        print_info "Removing existing file..."
        rm -f "${output_file}"
    fi

    # Check internet connectivity
    print_status "Checking internet connectivity..."
    if ! wget --spider --quiet --timeout=5 "${OSM_SOURCE}"; then
        print_error "Cannot reach ${OSM_SOURCE}"
        print_error "Please check your internet connection"
        exit 1
    fi
    print_success "Internet connection OK"

    # Download OSM data (use absolute -O path — no cd required)
    print_status "Downloading from Geofabrik..."
    print_info "This may take 5-30 minutes depending on region size and connection speed"
    echo ""

    local md5_file="${DATA_DIR}/${region}-latest.osm.pbf.md5"

    if wget --progress=bar:force:noscroll \
           --continue \
           --tries=3 \
           --timeout=60 \
           --read-timeout=30 \
           -O "${output_file}" \
           "${OSM_SOURCE}"; then
        print_success "Download complete"
    else
        print_error "Download failed"
        rm -f "${output_file}"
        exit 1
    fi

    # Download MD5 checksum
    print_status "Downloading MD5 checksum..."
    if wget -q -O "${md5_file}" "${md5_url}" 2>/dev/null; then

        # Verify checksum
        print_status "Verifying file integrity..."

        if command -v md5sum &> /dev/null; then
            # Extract just the hash from the md5 file (format: hash  filename)
            expected_md5=$(cut -d' ' -f1 "${md5_file}")
            actual_md5=$(md5sum "${output_file}" | cut -d' ' -f1)

            if [[ "${expected_md5}" == "${actual_md5}" ]]; then
                print_success "MD5 checksum verified"
                rm -f "${md5_file}"
            else
                print_error "MD5 checksum verification failed!"
                print_error "Expected: ${expected_md5}"
                print_error "Got:      ${actual_md5}"
                exit 1
            fi
        else
            print_info "md5sum not available, skipping verification"
            rm -f "${md5_file}"
        fi
    else
        print_info "MD5 file not available, skipping verification"
    fi

    # Display file info
    echo ""
    print_success "OSM data downloaded successfully"
    echo ""
    file_size=$(du -h "${output_file}" | cut -f1)
    echo "  File: ${output_file}"
    echo "  Size: ${file_size}"
    echo ""

    # Show next steps
    print_info "Next step: Build Valhalla tiles"
    echo "  cd ${PROJECT_ROOT}"
    echo "  ./scripts/regions/build-tiles.sh ${region}"
}

# Show usage
show_usage() {
    echo "Usage: $0 <region-name> [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --osm-dir <path>   Directory to store OSM files (env: OSM_DIR)"
    echo "  --config <path>    Path to regions.json (env: VALHALLA_REGIONS_CONFIG)"
    echo "  -y, --yes          Skip re-download prompt"
    echo "  -h, --help         Show this help"
    echo ""
    echo "Available regions from config:"
    if [[ -f "${REGIONS_CONFIG}" ]]; then
        jq -r '.regions | to_entries[] | "  \(.key) - \(.value.name) (\(if .value.enabled then "enabled" else "disabled" end))"' "${REGIONS_CONFIG}"
    else
        echo "  (Config file not found: ${REGIONS_CONFIG})"
    fi
    echo ""
    echo "Examples:"
    echo "  $0 singapore"
    echo "  $0 thailand --osm-dir /data/osm"
    echo "  OSM_DIR=/mnt/data/osm $0 singapore"
    echo ""
}

# Main execution
main() {
    print_header "OSM Data Downloader"

    # Check arguments
    if [[ $# -eq 0 ]]; then
        show_usage
        exit 1
    fi

    local region=$1
    shift
    local pipeline_config_file=""

    # Parse optional arguments (region is already consumed above)
    while [[ $# -gt 0 ]]; do
        case $1 in
            --pipeline-config)
                pipeline_config_file="$2"
                shift 2
                ;;
            --osm-dir)
                DATA_DIR="$2"
                shift 2
                ;;
            --config)
                REGIONS_CONFIG="$2"
                shift 2
                ;;
            -y|--yes)
                AUTO_YES=true
                shift
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

    # Load pipeline config (CLI --osm-dir / --config flags override it below)
    load_pipeline_config "${pipeline_config_file}"

    # Resolve final values: CLI flag > config file value > default
    DATA_DIR="${DATA_DIR:-${OSM_DIR:-${PROJECT_ROOT}/data/osm}}"
    REGIONS_CONFIG="${REGIONS_CONFIG:-${VALHALLA_REGIONS_CONFIG:-${PROJECT_ROOT}/config/regions/regions.json}}"

    print_info "OSM directory: ${DATA_DIR}"
    print_info "Regions config: ${REGIONS_CONFIG}"

    # Check dependencies
    check_jq

    # Get region info
    get_region_info "${region}"

    # Download OSM data
    download_osm "${region}"

    print_success "Process completed successfully"
}

# Run main function
main "$@"
