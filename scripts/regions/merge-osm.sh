#!/bin/bash
#
# Merge multiple OSM PBF files into a single PBF for a shared tile group.
#
# A "tile group" (defined under "tile_groups" in regions.json) lets several
# logical regions share one tile set built from the COMBINED OSM data of all
# its sources — required so routing can cross boundaries (e.g. NYC <-> Newark
# NJ <-> Stamford CT all route against the nyc_tri_state group).
#
# Usage:
#   ./merge-osm.sh nyc_tri_state               # download sources + merge
#   ./merge-osm.sh nyc_tri_state --keep-parts  # keep individual PBFs after merge
#   ./merge-osm.sh nyc_tri_state --force       # re-download + re-merge even if cached
#   ./merge-osm.sh --help                      # list available tile groups
#
# Options:
#   --osm-dir <path>   Directory to store/merge OSM files (env: OSM_DIR)
#   --config <path>    Path to regions.json (env: VALHALLA_REGIONS_CONFIG)
#   --keep-parts       Keep the individual source PBFs after a successful merge
#   --force            Re-download sources and re-merge even if outputs are cached
#   -h, --help         Show this help (and list available tile groups)
#
# Dependencies: osmium-tool, jq, wget
#   (all available inside the valhalla Docker image or WSL)
#

set -euo pipefail

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

KEEP_PARTS=false
FORCE=false
OSM_DIR=""
REGIONS_CONFIG=""

# ---------------------------------------------------------------------------
# Pipeline config loader — same precedence as the other region scripts.
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

print_header()  { echo -e "${CYAN}========================================${NC}\n${CYAN}$1${NC}\n${CYAN}========================================${NC}"; }
print_success() { echo -e "${GREEN}[✓]${NC} $1"; }
print_error()   { echo -e "${RED}[✗]${NC} $1"; }
print_info()    { echo -e "${YELLOW}[i]${NC} $1"; }
print_status()  { echo -e "${CYAN}[→]${NC} $1"; }

check_deps() {
    local missing=()
    command -v jq    &>/dev/null || missing+=("jq")
    command -v wget  &>/dev/null || missing+=("wget")
    command -v osmium &>/dev/null || missing+=("osmium-tool")
    if [[ ${#missing[@]} -gt 0 ]]; then
        print_error "Missing dependencies: ${missing[*]}"
        echo ""
        echo "Install:"
        echo "  jq:          sudo apt-get install jq"
        echo "  wget:        sudo apt-get install wget"
        echo "  osmium-tool: sudo apt-get install osmium-tool  (or use the valhalla Docker image / WSL)"
        exit 1
    fi
}

list_groups() {
    if [[ -f "${REGIONS_CONFIG}" ]]; then
        if jq -e '.tile_groups' "${REGIONS_CONFIG}" >/dev/null 2>&1; then
            jq -r '.tile_groups | to_entries[] | "  \(.key) - \(.value.description // "no description")"' "${REGIONS_CONFIG}"
        else
            echo "  (no tile_groups defined in ${REGIONS_CONFIG})"
        fi
    else
        echo "  (config not found: ${REGIONS_CONFIG})"
    fi
}

show_usage() {
    echo "Usage: $0 <tile-group> [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --osm-dir <path>   OSM storage/merge directory (env: OSM_DIR)"
    echo "  --config <path>    regions.json path (env: VALHALLA_REGIONS_CONFIG)"
    echo "  --keep-parts       Keep individual source PBFs after merge"
    echo "  --force            Re-download + re-merge even if cached"
    echo "  -h, --help         Show this help"
    echo ""
    echo "Available tile groups:"
    list_groups
    echo ""
    echo "Examples:"
    echo "  $0 nyc_tri_state"
    echo "  $0 nyc_tri_state --keep-parts"
    echo "  OSM_DIR=/mnt/efs/valhalla_osm $0 nyc_tri_state"
}

# ---------------------------------------------------------------------------
# Download a single source PBF (cache-aware, MD5-verified when available).
# Filename is derived from the source URL basename so multiple groups can
# coexist in the same OSM_DIR without collision.
# ---------------------------------------------------------------------------
download_source() {
    local url="$1"
    local dest="$2"

    if [[ -f "${dest}" && "${FORCE}" == false ]]; then
        print_info "Cached: $(basename "${dest}") ($(du -h "${dest}" | cut -f1)) — skipping download"
        return 0
    fi

    print_status "Downloading $(basename "${url}")"
    if ! wget --spider --quiet --timeout=10 "${url}"; then
        print_error "Cannot reach ${url}"
        return 1
    fi

    local tmp="${dest}.download.tmp"
    if ! wget --progress=dot:giga --continue --tries=3 --timeout=120 --read-timeout=60 \
            -O "${tmp}" "${url}"; then
        rm -f "${tmp}"
        print_error "Download failed: ${url}"
        return 1
    fi

    # MD5 verify when Geofabrik publishes a .md5
    local md5_url="${url}.md5"
    local md5_file="${dest}.md5"
    if wget -q -O "${md5_file}" "${md5_url}" 2>/dev/null && command -v md5sum &>/dev/null; then
        local expected actual
        expected="$(cut -d' ' -f1 "${md5_file}")"
        actual="$(md5sum "${tmp}" | cut -d' ' -f1)"
        rm -f "${md5_file}"
        if [[ "${expected}" != "${actual}" ]]; then
            print_error "MD5 mismatch for $(basename "${url}") — expected ${expected}, got ${actual}"
            rm -f "${tmp}"
            return 1
        fi
        print_success "MD5 verified: $(basename "${url}")"
    else
        rm -f "${md5_file}" 2>/dev/null || true
        print_info "No MD5 for $(basename "${url}") — skipping integrity check"
    fi

    mv "${tmp}" "${dest}"
    print_success "Downloaded: $(basename "${dest}") ($(du -h "${dest}" | cut -f1))"
}

main() {
    print_header "OSM Multi-Source Merge"

    if [[ $# -eq 0 ]]; then
        # Need config resolved for the usage listing
        REGIONS_CONFIG="${VALHALLA_REGIONS_CONFIG:-${PROJECT_ROOT}/config/regions/regions.json}"
        show_usage
        exit 1
    fi

    local group=""
    local pipeline_config_file=""

    # First positional that isn't a flag is the group name.
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --pipeline-config) pipeline_config_file="$2"; shift 2 ;;
            --osm-dir)         OSM_DIR="$2";              shift 2 ;;
            --config)          REGIONS_CONFIG="$2";       shift 2 ;;
            --keep-parts)      KEEP_PARTS=true;           shift   ;;
            --force)           FORCE=true;                shift   ;;
            -h|--help)
                REGIONS_CONFIG="${REGIONS_CONFIG:-${VALHALLA_REGIONS_CONFIG:-${PROJECT_ROOT}/config/regions/regions.json}}"
                show_usage
                exit 0
                ;;
            -*) print_error "Unknown option: $1"; exit 1 ;;
            *)  group="$1"; shift ;;
        esac
    done

    load_pipeline_config "${pipeline_config_file}"

    # CLI --osm-dir wins; else config-file OSM_DIR; else default.
    OSM_DIR="${OSM_DIR:-${PROJECT_ROOT}/data/osm}"
    REGIONS_CONFIG="${REGIONS_CONFIG:-${VALHALLA_REGIONS_CONFIG:-${PROJECT_ROOT}/config/regions/regions.json}}"

    if [[ -z "${group}" ]]; then
        print_error "No tile group specified"
        show_usage
        exit 1
    fi

    print_info "Tile group:    ${group}"
    print_info "OSM directory: ${OSM_DIR}"
    print_info "Regions config: ${REGIONS_CONFIG}"

    check_deps

    if [[ ! -f "${REGIONS_CONFIG}" ]]; then
        print_error "Regions config not found: ${REGIONS_CONFIG}"
        exit 1
    fi

    # Validate the group exists
    if ! jq -e ".tile_groups.${group}" "${REGIONS_CONFIG}" >/dev/null 2>&1; then
        print_error "Tile group '${group}' not found in ${REGIONS_CONFIG}"
        echo ""
        echo "Available tile groups:"
        list_groups
        exit 1
    fi

    local osm_file_name
    osm_file_name="$(jq -r ".tile_groups.${group}.osm_file" "${REGIONS_CONFIG}")"
    if [[ -z "${osm_file_name}" || "${osm_file_name}" == "null" ]]; then
        print_error "Tile group '${group}' has no 'osm_file' defined"
        exit 1
    fi
    local merged_output="${OSM_DIR}/${osm_file_name}"

    # Read sources into an array
    local sources=()
    while IFS= read -r line; do
        sources+=("${line}")
    done < <(jq -r ".tile_groups.${group}.osm_sources[]" "${REGIONS_CONFIG}")

    if [[ ${#sources[@]} -eq 0 ]]; then
        print_error "Tile group '${group}' has no 'osm_sources'"
        exit 1
    fi

    print_info "Sources: ${#sources[@]}"
    print_info "Merged output: ${merged_output}"

    mkdir -p "${OSM_DIR}"

    # Short-circuit: merged output already fresh and not forcing
    if [[ -f "${merged_output}" && "${FORCE}" == false ]]; then
        print_info "Merged file already exists: ${merged_output} ($(du -h "${merged_output}" | cut -f1))"
        print_info "Use --force to re-download and re-merge."
        print_success "Nothing to do."
        return 0
    fi

    # Download each source; collect local paths
    local parts=()
    for url in "${sources[@]}"; do
        local part="${OSM_DIR}/$(basename "${url}")"
        download_source "${url}" "${part}"
        parts+=("${part}")
    done

    # Merge (osmium requires 2+ inputs; a single-source group is just a copy).
    print_status "Merging ${#parts[@]} source(s) into ${osm_file_name}"
    local merge_tmp="${merged_output}.merge.tmp.osm.pbf"
    rm -f "${merge_tmp}"

    if [[ ${#parts[@]} -eq 1 ]]; then
        cp "${parts[0]}" "${merge_tmp}"
        print_info "Single source — copied (no merge needed)"
    else
        # --overwrite so a stale tmp never blocks; osmium dedups overlapping nodes/ways.
        osmium merge "${parts[@]}" -o "${merge_tmp}" --overwrite
    fi

    mv "${merge_tmp}" "${merged_output}"
    print_success "Merged OSM written: ${merged_output} ($(du -h "${merged_output}" | cut -f1))"

    # Optionally drop the individual parts to reclaim disk (EFS is not free).
    if [[ "${KEEP_PARTS}" == false ]]; then
        for part in "${parts[@]}"; do
            # Never delete the merged output even if a source basename collides.
            if [[ "${part}" != "${merged_output}" ]]; then
                rm -f "${part}"
            fi
        done
        print_info "Removed individual source PBFs (use --keep-parts to retain)"
    else
        print_info "Kept individual source PBFs (--keep-parts)"
    fi

    echo ""
    print_info "Next step: build tiles"
    echo "  ./scripts/regions/build-tiles.sh new_york --no-elevation"
    print_success "Process completed successfully"
}

main "$@"
