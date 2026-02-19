#!/bin/bash
#
# Generic OSM Data Downloader for Multiple Regions
# Downloads OSM extracts from Geofabrik based on region configuration
#
# Usage:
#   ./download-region-osm.sh singapore
#   ./download-region-osm.sh thailand
#   ./download-region-osm.sh [region-name]
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
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

# Configuration paths
REGIONS_CONFIG="${PROJECT_ROOT}/config/regions/singapore/regions.json"
DATA_DIR="${PROJECT_ROOT}/data/osm"

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

        # Get file size and modification time
        if [[ -f "${output_file}" ]]; then
            file_size=$(du -h "${output_file}" | cut -f1)
            file_date=$(date -r "${output_file}" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || stat -c %y "${output_file}" 2>/dev/null | cut -d' ' -f1-2)
            print_info "Size: ${file_size}, Last modified: ${file_date}"
        fi

        echo ""
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

    # Download OSM data
    print_status "Downloading from Geofabrik..."
    print_info "This may take 5-30 minutes depending on region size and connection speed"
    echo ""

    cd "${DATA_DIR}"

    if wget --progress=bar:force:noscroll \
           --continue \
           --tries=3 \
           --timeout=60 \
           --read-timeout=30 \
           -O "${region}-latest.osm.pbf" \
           "${OSM_SOURCE}"; then
        print_success "Download complete"
    else
        print_error "Download failed"
        rm -f "${region}-latest.osm.pbf"
        exit 1
    fi

    # Download MD5 checksum
    print_status "Downloading MD5 checksum..."
    if wget -q -O "${region}-latest.osm.pbf.md5" "${md5_url}" 2>/dev/null; then

        # Verify checksum
        print_status "Verifying file integrity..."

        if command -v md5sum &> /dev/null; then
            # Extract just the hash from the md5 file (format: hash  filename)
            expected_md5=$(cut -d' ' -f1 "${region}-latest.osm.pbf.md5")
            actual_md5=$(md5sum "${region}-latest.osm.pbf" | cut -d' ' -f1)

            if [[ "${expected_md5}" == "${actual_md5}" ]]; then
                print_success "MD5 checksum verified"
                rm -f "${region}-latest.osm.pbf.md5"
            else
                print_error "MD5 checksum verification failed!"
                print_error "Expected: ${expected_md5}"
                print_error "Got:      ${actual_md5}"
                exit 1
            fi
        else
            print_info "md5sum not available, skipping verification"
            rm -f "${region}-latest.osm.pbf.md5"
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
    echo "  ./scripts/singapore/build-tiles.sh ${region}"
}

# Show usage
show_usage() {
    echo "Usage: $0 <region-name>"
    echo ""
    echo "Available regions from config:"
    if [[ -f "${REGIONS_CONFIG}" ]]; then
        jq -r '.regions | to_entries[] | "  \(.key) - \(.value.name) (\(if .value.enabled then "enabled" else "disabled" end))"' "${REGIONS_CONFIG}"
    else
        echo "  (Config file not found)"
    fi
    echo ""
    echo "Examples:"
    echo "  $0 singapore"
    echo "  $0 thailand"
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
