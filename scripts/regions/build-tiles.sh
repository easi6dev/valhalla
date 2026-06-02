#!/bin/bash
#
# Build Valhalla Tiles from OSM Data
# Generic script that works for any region configured in regions.json
#
# Usage:
#   ./build-tiles.sh singapore
#   ./build-tiles.sh thailand
#   ./build-tiles.sh [region-name] [OPTIONS]
#
# Options:
#   --tile-dir <path>    Root directory for tile output
#                        (env: VALHALLA_TILE_DIR, default: <project-root>/data/valhalla_tiles)
#   --osm-dir <path>     Directory containing OSM .pbf files
#                        (env: OSM_DIR, default: <project-root>/data/osm)
#   --admin-dir <path>   Directory for admin SQLite database output
#                        (env: VALHALLA_ADMIN_DIR, default: <project-root>/data/admin_data)
#   --log-dir <path>     Directory for build logs
#                        (env: VALHALLA_LOG_DIR, default: <project-root>/logs)
#   --config <path>      Path to regions.json config file
#                        (env: VALHALLA_REGIONS_CONFIG)
#   --clean              Remove existing tiles before building
#   --no-elevation       Skip elevation processing (faster)
#
# Environment variables:
#   VALHALLA_TILE_DIR    Override tile output root directory
#   OSM_DIR              Override OSM input directory
#   VALHALLA_ADMIN_DIR   Override admin database directory
#   VALHALLA_LOG_DIR     Override log directory
#   VALHALLA_REGIONS_CONFIG  Override regions config file path
#

set -euo pipefail

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
# Priority: --config flag > VALHALLA_PIPELINE_CONFIG env > pipeline.<env>.conf
#           > pipeline.local.conf > defaults
# ---------------------------------------------------------------------------
load_pipeline_config() {
    local config_file="${1:-}"

    # Resolve config file path
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
        print_info "Loaded pipeline config: ${config_file}"
    else
        print_info "No pipeline config file found — using defaults"
    fi
}

# Defaults (overridden by config file or CLI flags)
REGIONS_CONFIG="${VALHALLA_REGIONS_CONFIG:-${PROJECT_ROOT}/config/regions/regions.json}"
TILE_DIR_ROOT="${VALHALLA_TILE_DIR:-${PROJECT_ROOT}/data/valhalla_tiles}"
OSM_DIR="${OSM_DIR:-${PROJECT_ROOT}/data/osm}"
ADMIN_DIR="${VALHALLA_ADMIN_DIR:-${PROJECT_ROOT}/data/admin_data}"
LOG_DIR="${VALHALLA_LOG_DIR:-${PROJECT_ROOT}/logs}"

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

    # Check for valhalla_build_tiles binary (config file path, PATH, or Docker fallback)
    USE_DOCKER=false
    local bin="${VALHALLA_BUILD_TILES_BIN:-}"
    # Global so build_tiles() can reference it when constructing docker commands.
    # Override per-cluster via VALHALLA_DOCKER_IMAGE (e.g. US cluster ECR registry).
    DOCKER_IMAGE="${VALHALLA_DOCKER_IMAGE:-633107344074.dkr.ecr.ap-southeast-1.amazonaws.com/valhalla:development}"
    if [[ -n "${bin}" && -x "${bin}" ]]; then
        print_info "Using Valhalla binary: ${bin}"
        # Make it available as valhalla_build_tiles for the rest of the script
        export PATH="$(dirname "${bin}"):${PATH}"
    elif command -v valhalla_build_tiles &> /dev/null; then
        print_info "Using native Valhalla installation (system PATH)"
    elif command -v docker &> /dev/null; then
        if ! docker image inspect "${DOCKER_IMAGE}" &> /dev/null; then
            print_info "Pulling Docker image: ${DOCKER_IMAGE}"
            docker pull "${DOCKER_IMAGE}"
        fi
        print_info "Using Docker-based Valhalla (${DOCKER_IMAGE})"
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

    # Tile subdir resolution: a region either has its own tile_dir
    # (Singapore-style) or a tile_group (shared tiles). For a group, the subdir
    # and the merged OSM filename come from the tile_groups block.
    local tile_group
    tile_group=$(jq -r ".regions.${region}.tile_group // empty" "${REGIONS_CONFIG}")
    if [[ -n "${tile_group}" ]]; then
        REGION_TILE_SUBDIR=$(jq -r ".tile_groups.${tile_group}.tile_dir" "${REGIONS_CONFIG}")
        if [[ -z "${REGION_TILE_SUBDIR}" || "${REGION_TILE_SUBDIR}" == "null" ]]; then
            print_error "Region '${region}' references tile_group '${tile_group}' but it has no tile_dir in tile_groups"
            exit 1
        fi
        # Group regions read the merged OSM file produced by merge-osm.sh.
        local group_osm_file
        group_osm_file=$(jq -r ".tile_groups.${tile_group}.osm_file // empty" "${REGIONS_CONFIG}")
        OSM_FILE="${OSM_DIR}/${group_osm_file:-${tile_group}-latest.osm.pbf}"
        print_info "Tile group:     ${tile_group} (shared tiles)"
    else
        REGION_TILE_SUBDIR=$(jq -r ".regions.${region}.tile_dir" "${REGIONS_CONFIG}")
        # OSM input: honor an explicit osm_file override, else <region>-latest.osm.pbf
        local region_osm_file
        region_osm_file=$(jq -r ".regions.${region}.osm_file // empty" "${REGIONS_CONFIG}")
        OSM_FILE="${OSM_DIR}/${region_osm_file:-${region}-latest.osm.pbf}"
    fi

    # Tile output: TILE_DIR_ROOT (from env/flag) + resolved subdir
    TILE_DIR="${TILE_DIR_ROOT}/${REGION_TILE_SUBDIR}"

    # Config template: look for region-specific template, fall back to generic
    local region_template="${PROJECT_ROOT}/config/regions/${region}/valhalla-${region}.json"
    local generic_template="${PROJECT_ROOT}/config/regions/valhalla-template.json"
    if [[ -f "${region_template}" ]]; then
        CONFIG_TEMPLATE="${region_template}"
    elif [[ -f "${generic_template}" ]]; then
        CONFIG_TEMPLATE="${generic_template}"
    else
        # Fall back to first available template in config/regions/
        CONFIG_TEMPLATE=$(find "${PROJECT_ROOT}/config/regions" -name "valhalla-*.json" | head -1)
        if [[ -z "${CONFIG_TEMPLATE}" ]]; then
            print_error "No Valhalla config template found in ${PROJECT_ROOT}/config/regions/"
            print_error "Expected: ${region_template}"
            exit 1
        fi
        print_info "No region-specific template found; using: ${CONFIG_TEMPLATE}"
    fi

    print_info "Region:         ${REGION_NAME}"
    print_info "Tile directory: ${TILE_DIR}"
    print_info "OSM file:       ${OSM_FILE}"
    print_info "Config template: ${CONFIG_TEMPLATE}"
    print_info "Admin dir:      ${ADMIN_DIR}"
    print_info "Log dir:        ${LOG_DIR}"
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
    mkdir -p "${ADMIN_DIR}"
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
        # In CI/Docker/cron there is no TTY — never block on a prompt. Default to
        # using the existing tiles (the run-tile-pipeline.sh wrapper handles
        # versioned rebuilds; --clean forces a fresh build here).
        if [[ ! -t 0 ]]; then
            print_info "Non-interactive (no TTY) — using existing tiles. Pass --clean to force rebuild."
            return 0
        fi
        read -p "Rebuild tiles? This will delete existing tiles. (y/N): " response
        if [[ ! "${response}" =~ ^[Yy]$ ]]; then
            print_success "Using existing tiles"
            return 0
        fi
        rm -rf "${TILE_DIR:?}"/*
    fi

    # Create build config from template
    print_status "Creating build configuration..."
    # Write temp config to log dir (guaranteed writable, outside project tree)
    TEMP_CONFIG="${LOG_DIR}/valhalla-build-${region}-$(date +%Y%m%d-%H%M%S).json"

    # Copy template and substitute all path placeholders with resolved absolute paths
    cp "${CONFIG_TEMPLATE}" "${TEMP_CONFIG}"

    # Use sed to update paths (works on both Linux and macOS)
    # Replace tile_dir value (any path ending in the region subdir or generic placeholder)
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS requires empty string after -i
        sed -i '' "s|\"tile_dir\":.*|\"tile_dir\": \"${TILE_DIR}\",|g" "${TEMP_CONFIG}"
        sed -i '' "s|data/admin_data|${ADMIN_DIR}|g" "${TEMP_CONFIG}"
        # Replace any remaining PROJECT_ROOT-relative paths
        sed -i '' "s|${PROJECT_ROOT}/data/valhalla_tiles[^\"]*|${TILE_DIR}|g" "${TEMP_CONFIG}"
    else
        # Linux / Windows Git Bash
        sed -i "s|\"tile_dir\":.*|\"tile_dir\": \"${TILE_DIR}\",|g" "${TEMP_CONFIG}"
        sed -i "s|data/admin_data|${ADMIN_DIR}|g" "${TEMP_CONFIG}"
        sed -i "s|${PROJECT_ROOT}/data/valhalla_tiles[^\"]*|${TILE_DIR}|g" "${TEMP_CONFIG}"
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
        # Docker strategy: mount three separate host directories into the container
        #   /valhalla/tiles  ← TILE_DIR
        #   /valhalla/osm    ← OSM_DIR
        #   /valhalla/admin  ← ADMIN_DIR
        #   /valhalla/config ← directory containing TEMP_CONFIG
        TEMP_CONFIG_DIR="$(dirname "${TEMP_CONFIG}")"

        # Build a Docker-internal version of the config with /valhalla/* paths
        DOCKER_CONFIG="${TEMP_CONFIG_DIR}/valhalla-build-${region}-docker.json"
        sed \
            -e "s|${TILE_DIR}|/valhalla/tiles|g" \
            -e "s|${ADMIN_DIR}|/valhalla/admin|g" \
            -e "s|${OSM_DIR}|/valhalla/osm|g" \
            "${TEMP_CONFIG}" > "${DOCKER_CONFIG}"

        print_info "Docker config: ${DOCKER_CONFIG}"

        # Resolve host paths for -v mounts (Windows Git Bash needs cygpath)
        resolve_docker_path() {
            if [[ "$(uname -s)" == MINGW* ]] || [[ "$(uname -s)" == MSYS* ]] || [[ "$(uname -s)" == CYGWIN* ]]; then
                cygpath -w "$1" 2>/dev/null || echo "$1"
            else
                echo "$1"
            fi
        }

        DOCKER_TILE_PATH=$(resolve_docker_path "${TILE_DIR}")
        DOCKER_OSM_PATH=$(resolve_docker_path "${OSM_DIR}")
        DOCKER_ADMIN_PATH=$(resolve_docker_path "${ADMIN_DIR}")
        DOCKER_CFG_PATH=$(resolve_docker_path "${TEMP_CONFIG_DIR}")

        DOCKER_RUN_CMD=(docker run --rm
            -v "${DOCKER_TILE_PATH}:/valhalla/tiles"
            -v "${DOCKER_OSM_PATH}:/valhalla/osm"
            -v "${DOCKER_ADMIN_PATH}:/valhalla/admin"
            -v "${DOCKER_CFG_PATH}:/valhalla/config"
            "${DOCKER_IMAGE}"
            valhalla_build_tiles
            -c "/valhalla/config/$(basename "${DOCKER_CONFIG}")"
            "/valhalla/osm/$(basename "${OSM_FILE}")"
        )

        if [[ "$(uname -s)" == MINGW* ]] || [[ "$(uname -s)" == MSYS* ]] || [[ "$(uname -s)" == CYGWIN* ]]; then
            if MSYS_NO_PATHCONV=1 "${DOCKER_RUN_CMD[@]}" 2>&1 | tee -a "${BUILD_LOG}"; then
                BUILD_SUCCESS=true
            else
                BUILD_SUCCESS=false
            fi
        else
            if "${DOCKER_RUN_CMD[@]}" 2>&1 | tee -a "${BUILD_LOG}"; then
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
            # ADMIN_DIR already created at start of build_tiles

            if [[ "${USE_DOCKER}" == true ]]; then
                # Reuse the same Docker-internal paths as tile build
                DOCKER_ADMIN_CONFIG="${TEMP_CONFIG_DIR}/valhalla-admin-${region}-docker.json"
                sed \
                    -e "s|${TILE_DIR}|/valhalla/tiles|g" \
                    -e "s|${ADMIN_DIR}|/valhalla/admin|g" \
                    -e "s|${OSM_DIR}|/valhalla/osm|g" \
                    "${TEMP_CONFIG}" > "${DOCKER_ADMIN_CONFIG}"

                DOCKER_ADMIN_RUN_CMD=(docker run --rm
                    -v "${DOCKER_TILE_PATH}:/valhalla/tiles"
                    -v "${DOCKER_OSM_PATH}:/valhalla/osm"
                    -v "${DOCKER_ADMIN_PATH}:/valhalla/admin"
                    -v "${DOCKER_CFG_PATH}:/valhalla/config"
                    "${DOCKER_IMAGE}"
                    valhalla_build_admins
                    -c "/valhalla/config/$(basename "${DOCKER_ADMIN_CONFIG}")"
                    "/valhalla/osm/$(basename "${OSM_FILE}")"
                )

                if [[ "$(uname -s)" == MINGW* ]] || [[ "$(uname -s)" == MSYS* ]] || [[ "$(uname -s)" == CYGWIN* ]]; then
                    if MSYS_NO_PATHCONV=1 "${DOCKER_ADMIN_RUN_CMD[@]}" 2>&1 | tee -a "${BUILD_LOG}"; then
                        print_success "Admin boundaries built"
                    else
                        print_info "Admin boundaries build failed (non-critical)"
                    fi
                else
                    if "${DOCKER_ADMIN_RUN_CMD[@]}" 2>&1 | tee -a "${BUILD_LOG}"; then
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

        # Build tile extract (.tar with embedded index.bin)
        # valhalla_build_extract packs the tile_dir into a single mmap-able tar
        # and writes index.bin as the FIRST member (fixed-width {offset, tile_id,
        # size} records). That lets the routing engine init tile_extract_t in
        # milliseconds without scanning the whole tar, and removes the singleton
        # constraint on runtime tileset reloading (valhalla/valhalla#3117, PR
        # #3281). A plain `tar` would NOT write this index. Set
        # BUILD_EXTRACT=false (env/config) to skip.
        if [[ "${BUILD_EXTRACT:-true}" == true ]]; then
            echo ""
            print_status "Building tile extract (.tar with index.bin)..."
            TILE_EXTRACT="${TILE_DIR}/${region}.tar"

            if [[ "${USE_DOCKER}" == true ]]; then
                # Reuse the tiles mount; build the tar in-place inside /valhalla/tiles.
                DOCKER_EXTRACT_RUN_CMD=(docker run --rm
                    -v "${DOCKER_TILE_PATH}:/valhalla/tiles"
                    "${DOCKER_IMAGE}"
                    valhalla_build_extract
                    --inline-config "{\"mjolnir\":{\"tile_dir\":\"/valhalla/tiles\",\"tile_extract\":\"/valhalla/tiles/${region}.tar\"}}"
                    --overwrite -v
                )
                if [[ "$(uname -s)" == MINGW* ]] || [[ "$(uname -s)" == MSYS* ]] || [[ "$(uname -s)" == CYGWIN* ]]; then
                    MSYS_NO_PATHCONV=1 "${DOCKER_EXTRACT_RUN_CMD[@]}" 2>&1 | tee -a "${BUILD_LOG}" || true
                else
                    "${DOCKER_EXTRACT_RUN_CMD[@]}" 2>&1 | tee -a "${BUILD_LOG}" || true
                fi
            else
                # Native: prefer the in-tree python script so it matches this checkout.
                EXTRACT_SCRIPT="${PROJECT_ROOT}/scripts/valhalla_build_extract"
                if [[ -x "${EXTRACT_SCRIPT}" ]]; then
                    EXTRACT_RUNNER=(python3 "${EXTRACT_SCRIPT}")
                elif command -v valhalla_build_extract &> /dev/null; then
                    EXTRACT_RUNNER=(valhalla_build_extract)
                else
                    EXTRACT_RUNNER=()
                    print_info "valhalla_build_extract not found — skipping extract (non-critical)"
                fi
                if [[ ${#EXTRACT_RUNNER[@]} -gt 0 ]]; then
                    "${EXTRACT_RUNNER[@]}" \
                        --inline-config "{\"mjolnir\":{\"tile_dir\":\"${TILE_DIR}\",\"tile_extract\":\"${TILE_EXTRACT}\"}}" \
                        --overwrite -v 2>&1 | tee -a "${BUILD_LOG}" || true
                fi
            fi

            # Verify index.bin is the first member — the whole point of the step.
            if [[ -f "${TILE_EXTRACT}" ]]; then
                if [[ "$(tar tf "${TILE_EXTRACT}" 2>/dev/null | head -1)" == "index.bin" ]]; then
                    print_success "Tile extract built: ${TILE_EXTRACT} ($(du -sh "${TILE_EXTRACT}" | cut -f1), index.bin present)"
                else
                    print_error "Tile extract built but index.bin is not the first member"
                fi
            else
                print_info "Tile extract was not created (non-critical)"
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
    echo "  --tile-dir <path>    Tile output root directory (env: VALHALLA_TILE_DIR)"
    echo "  --osm-dir <path>     OSM input directory (env: OSM_DIR)"
    echo "  --admin-dir <path>   Admin DB output directory (env: VALHALLA_ADMIN_DIR)"
    echo "  --log-dir <path>     Log directory (env: VALHALLA_LOG_DIR)"
    echo "  --config <path>      Regions config file (env: VALHALLA_REGIONS_CONFIG)"
    echo "  --clean              Remove existing tiles before building"
    echo "  --no-elevation       Skip elevation processing (faster)"
    echo "  -h, --help           Show this help"
    echo ""
    echo "Available regions:"
    if [[ -f "${REGIONS_CONFIG}" ]]; then
        jq -r '.regions | to_entries[] | "  \(.key) - \(.value.name)"' "${REGIONS_CONFIG}"
    fi
    echo ""
    echo "Examples:"
    echo "  $0 singapore"
    echo "  $0 singapore --clean --no-elevation"
    echo "  $0 thailand --tile-dir /mnt/tiles --osm-dir /mnt/osm"
    echo "  VALHALLA_TILE_DIR=/var/valhalla/tiles OSM_DIR=/data/osm $0 singapore"
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
    local pipeline_config_file=""

    # Parse optional arguments
    shift
    while [[ $# -gt 0 ]]; do
        case $1 in
            --pipeline-config)
                pipeline_config_file="$2"
                shift 2
                ;;
            --tile-dir)
                TILE_DIR_ROOT="$2"
                shift 2
                ;;
            --osm-dir)
                OSM_DIR="$2"
                shift 2
                ;;
            --admin-dir)
                ADMIN_DIR="$2"
                shift 2
                ;;
            --log-dir)
                LOG_DIR="$2"
                shift 2
                ;;
            --config)
                REGIONS_CONFIG="$2"
                shift 2
                ;;
            --clean)
                clean_build=true
                shift
                ;;
            --no-elevation)
                skip_elevation=true
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

    # Load pipeline config (after CLI parsing so --pipeline-config is resolved)
    load_pipeline_config "${pipeline_config_file}"

    # Re-apply defaults after config load (CLI flags always win over config file)
    TILE_DIR_ROOT="${TILE_DIR_ROOT:-${VALHALLA_TILE_DIR:-${PROJECT_ROOT}/data/valhalla_tiles}}"
    OSM_DIR="${OSM_DIR:-${PROJECT_ROOT}/data/osm}"
    ADMIN_DIR="${ADMIN_DIR:-${VALHALLA_ADMIN_DIR:-${PROJECT_ROOT}/data/admin_data}}"
    LOG_DIR="${LOG_DIR:-${VALHALLA_LOG_DIR:-${PROJECT_ROOT}/logs}}"
    REGIONS_CONFIG="${REGIONS_CONFIG:-${VALHALLA_REGIONS_CONFIG:-${PROJECT_ROOT}/config/regions/regions.json}}"

    # Docker volume mounts require absolute paths. `realpath -m` resolves without
    # requiring the path to exist yet (dirs are created later). Skip if realpath
    # is unavailable (rare); the dirs are mkdir'd before use regardless.
    if command -v realpath &>/dev/null; then
        TILE_DIR_ROOT="$(realpath -m "${TILE_DIR_ROOT}")"
        OSM_DIR="$(realpath -m "${OSM_DIR}")"
        ADMIN_DIR="$(realpath -m "${ADMIN_DIR}")"
        LOG_DIR="$(realpath -m "${LOG_DIR}")"
    fi

    # Config file SKIP_ELEVATION / CLEAN_BUILD (only if not set via CLI flag)
    if [[ "${skip_elevation}" == false && "${SKIP_ELEVATION:-false}" == true ]]; then
        skip_elevation=true
    fi
    if [[ "${clean_build}" == false && "${CLEAN_BUILD:-false}" == true ]]; then
        clean_build=true
    fi

    print_info "Tile dir root: ${TILE_DIR_ROOT}"
    print_info "OSM dir:       ${OSM_DIR}"
    print_info "Admin dir:     ${ADMIN_DIR}"
    print_info "Log dir:       ${LOG_DIR}"
    print_info "Regions config: ${REGIONS_CONFIG}"

    # Check dependencies
    check_dependencies

    # Get region config (also resolves TILE_DIR, OSM_FILE, CONFIG_TEMPLATE)
    get_region_config "${region}"

    # Build tiles
    build_tiles "${region}" "${clean_build}" "${skip_elevation}"

    print_success "Process completed successfully"
}

# Run main
main "$@"
