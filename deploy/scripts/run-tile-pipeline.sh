#!/bin/bash
# =============================================================================
# Valhalla Tile Generation Pipeline
# =============================================================================
# Single entrypoint for the full tile generation lifecycle:
#   OSM download → tile build → admin build → validate → S3 sync → swap latest
#
# Designed to run as a weekly cron job across all environments.
#
# This is a THIN DRIVER over lib/tile-pipeline-common.sh — it provides only the
# Singapore/APAC region config and the region-specific phases (plain OSM
# download, LTA/EFS geometry mapping). The shared phase logic lives in the lib.
#
# Usage:
#   ./run-tile-pipeline.sh <region> [OPTIONS]
#
# Options:
#   --pipeline-config <path>  Path to pipeline .conf file
#   --force-download          Re-download OSM even if file is fresh
#   --osm-max-age-days <n>    Re-download if OSM file is older than N days (default: 6)
#   --no-elevation            Skip elevation data (faster build)
#   --with-elevation          Force-include elevation data (overrides conf/env)
#   --dry-run                 Print what would happen, do not execute
#   --keep-versions <n>       Number of old tile versions to keep (default: 3)
#   --notify-url <url>        Webhook URL for completion/failure notification
#   -h, --help                Show this help
#
# Environment:
#   VALHALLA_ENV              local | dev | test | staging | prod (default: local)
#   VALHALLA_PIPELINE_CONFIG  Override pipeline config file path
#
# Exit codes:
#   0  Success
#   1  Config / dependency error
#   2  OSM download failed
#   3  Tile build failed
#   4  Tile validation failed
#   5  S3 sync failed
#   6  Partial success (tiles valid, S3 failed)
# =============================================================================

set -euo pipefail
trap '' PIPE

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
readonly SCRIPT_VERSION="1.0.0"
readonly SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
readonly PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# ---------------------------------------------------------------------------
# Source the shared core, asserting a matching version so a driver and a stale
# lib copy can never silently run together.
# ---------------------------------------------------------------------------
readonly EXPECTED_LIB_VERSION="1.0.0"
# shellcheck source=lib/tile-pipeline-common.sh
source "${SCRIPT_DIR}/lib/tile-pipeline-common.sh"
if [[ "${LIB_VERSION}" != "${EXPECTED_LIB_VERSION}" ]]; then
    echo "FATAL: tile-pipeline-common.sh version ${LIB_VERSION} != expected ${EXPECTED_LIB_VERSION}" >&2
    exit 1
fi
trap on_exit EXIT

# ---------------------------------------------------------------------------
# Region config — labels + defaults consumed by the shared lib.
# ---------------------------------------------------------------------------
readonly REGION_LABEL=""                                # bootstrap phase label suffix
readonly LOG_PREFIX="pipeline"                          # log file name prefix
readonly DEFAULT_S3_REGION="ap-southeast-1"
readonly PIPELINE_LABEL="Pipeline "                     # on_exit banner prefix
readonly COMPLETION_LABEL="Pipeline completed successfully — "
readonly EFS_SKIP_NOTE=" (local dev)"

# Execution order (verbatim from the original main()) and the --skip-build subset.
readonly PHASES=(phase_osm phase_build phase_extract phase_validate
                 phase_s3_sync phase_swap_latest phase_cleanup
                 geometry_mapping phase_efs_sync)
readonly BUILD_PHASES=(phase_osm phase_build)

# Region-specific default flags.
set_region_defaults() {
    SKIP_GEOMETRY_MAPPING=false
}

# ---------------------------------------------------------------------------
# Tile-layout resolution (single-region, no groups). TILE_SUBDIR == REGION.
# ---------------------------------------------------------------------------
resolve_tile_layout() {
    local regions_config="${PROJECT_ROOT}/config/regions/regions.json"
    TILE_SUBDIR="${REGION}"
    IS_GROUP=false
    TILE_GROUP=""
    OSM_SOURCE="$(jq -r ".regions.${REGION}.osm_source" "${regions_config}")"
    OSM_FILE="${OSM_DIR}/${REGION}-latest.osm.pbf"
    log_info "OSM source:     ${OSM_SOURCE}"
}

# ---------------------------------------------------------------------------
# Phase 1: OSM Check / Download (single Geofabrik extract, cache-aware)
# ---------------------------------------------------------------------------
phase_osm() {
    set_phase "Phase 1: OSM Check / Download"

    mkdir -p "${OSM_DIR}"

    # Check if OSM file exists and is fresh enough
    if [[ -f "${OSM_FILE}" ]] && [[ "${FORCE_DOWNLOAD}" == false ]]; then
        local file_age_days
        local file_mtime
        file_mtime="$(stat -c %Y "${OSM_FILE}" 2>/dev/null || stat -f %m "${OSM_FILE}" 2>/dev/null || echo 0)"
        local now_epoch
        now_epoch="$(date +%s)"
        file_age_days=$(( (now_epoch - file_mtime) / 86400 ))

        log_info "OSM file exists. Age: ${file_age_days} day(s). Max age: ${OSM_MAX_AGE_DAYS} day(s)."

        if [[ ${file_age_days} -lt ${OSM_MAX_AGE_DAYS} ]]; then
            local file_size
            file_size="$(du -sh "${OSM_FILE}" | cut -f1)"
            log_ok "OSM file is fresh (${file_size}). Skipping download."
            return 0
        else
            log_info "OSM file is stale (${file_age_days}d old). Re-downloading."
        fi
    elif [[ "${FORCE_DOWNLOAD}" == true ]]; then
        log_info "Force download requested."
    else
        log_info "OSM file not found. Downloading."
    fi

    if [[ "${DRY_RUN}" == true ]]; then
        log_dry "Would download: ${OSM_SOURCE} → ${OSM_FILE}"
        return 0
    fi

    retry "${MAX_DOWNLOAD_RETRIES}" "${DOWNLOAD_RETRY_DELAY}" "OSM download" -- \
        _download_osm

    log_ok "OSM phase complete"
}

# ---------------------------------------------------------------------------
# Geometry Mapping (LTA → Valhalla edge resolution)
# ---------------------------------------------------------------------------
# Runs against the just-swapped 'latest' tiles. Required for the Python
# traffic cron to translate LTA speed-band linkIds into Valhalla
# (tile_id, edge_index) pairs at runtime. Job exit semantics:
#   0 → mapping succeeded; pipeline continues
#   1 → mapping below acceptance threshold; pipeline warns and continues
#   2 → mapping failed (config error, Actor failure, malformed snapshot); pipeline fails
#   3 → no LTA snapshot yet (cron hasn't produced one); pipeline warns and continues
# ---------------------------------------------------------------------------
geometry_mapping() {
    set_phase "Geometry Mapping"

    if [[ "${SKIP_GEOMETRY_MAPPING}" == true ]]; then
        log_info "Skipping geometry mapping (--skip-geometry-mapping)"
        return 0
    fi

    if [[ "${DRY_RUN}" == true ]]; then
        log_dry "Would invoke GeometryMappingJob against ${LATEST_LINK}"
        return 0
    fi

    # Resolve the JNI JAR — prefer the prod path baked into the Docker image,
    # fall back to the local-dev gradle output.
    local jar=""
    if [[ -f "/app/valhalla-jni.jar" ]]; then
        jar="/app/valhalla-jni.jar"
    else
        # Filter out -sources.jar and -javadoc.jar — Gradle's java{} block
        # produces them via withSourcesJar()/withJavadocJar(); only the main
        # JAR has the compiled classes. Mirrors docker/Dockerfile.prod.
        jar="$(ls "${PROJECT_ROOT}/src/bindings/java/build/libs/valhalla-jni-"*.jar 2>/dev/null \
            | grep -v sources | grep -v javadoc | head -1)"
    fi

    if [[ -z "${jar}" || ! -f "${jar}" ]]; then
        log_error "valhalla-jni JAR not found (checked /app/valhalla-jni.jar and ${PROJECT_ROOT}/src/bindings/java/build/libs/)"
        return 2
    fi

    log_info "Using JAR: ${jar}"
    log_info "Tile dir:  $(readlink -f "${LATEST_LINK}")"

    # Snapshots are READ from EFS (written by the tada-traffic-data-builder cron),
    # and cache outputs are WRITTEN to EFS (consumed by the same cron on its next
    # tick). EFS lives at /mnt/efs/valhalla_tiles per the K8s volumeMount on both
    # pods. ${VALHALLA_TILE_DIR} in this pod is /var/valhalla/tiles (local) —
    # used only by the C++ engine to read the freshly-built tiles — do NOT
    # conflate it with the EFS path. VALHALLA_EFS_DIR is overridable for local
    # dev where EFS doesn't exist.
    local efs_region_dir="${VALHALLA_EFS_DIR:-/mnt/efs/valhalla_tiles}/${REGION}"
    local efs_cache_dir="${efs_region_dir}/cache"
    local efs_snapshots_dir="${efs_region_dir}/snapshots/speed_bands"
    mkdir -p "${efs_cache_dir}"

    local job_exit_code=0
    VALHALLA_TILE_DIR="${LATEST_LINK}" \
    VALHALLA_SNAPSHOTS_DIR="${efs_snapshots_dir}" \
    GEOMETRY_MAPPING_CACHE_PATH="${efs_cache_dir}/geometry_mapping.json" \
    GEOMETRY_MAPPING_REPORT_PATH="${efs_cache_dir}/geometry_mapping_report.txt" \
    GEOMETRY_MAPPING_JSON_REPORT_PATH="${efs_cache_dir}/geometry_mapping_report.json" \
        java -cp "${jar}:/app/lib/*" global.tada.valhalla.traffic.sg.GeometryMappingJob \
        || job_exit_code=$?

    case "${job_exit_code}" in
        0) log_ok "Geometry mapping completed (acceptance criteria met)" ;;
        1) log_warn "Geometry mapping below acceptance threshold (job exit 1) — pipeline continues" ;;
        3) log_warn "No LTA speed-bands snapshot yet (job exit 3) — geometry mapping skipped; the tada-valhalla-traffic cron will produce it. Pipeline continues" ;;
        *) log_error "Geometry mapping failed (job exit ${job_exit_code})"; return 2 ;;
    esac

    return 0
}

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
show_usage() {
    cat <<EOF
Usage: $(basename "$0") <region> [OPTIONS]

Options:
  --pipeline-config <path>  Path to pipeline .conf file
  --force-download          Re-download OSM even if fresh
  --osm-max-age-days <n>    Max OSM file age before re-download (default: 6)
  --no-elevation            Skip elevation data
  --with-elevation          Force-include elevation data (overrides conf/env)
  --skip-build              Skip OSM download and tile build; validate existing 'latest' tiles
  --skip-geometry-mapping   Skip the geometry-mapping job after tile swap
  --no-extract              Skip building the .tar tile extract (index.bin)
  --keep-versions <n>       Old tile versions to retain (default: 3)
  --dry-run                 Print actions without executing
  --notify-url <url>        POST webhook on completion/failure
  -h, --help                Show this help

Environments (VALHALLA_ENV):
  local     Uses pipeline.local.conf + binary from build/
  dev       Uses pipeline.dev.conf + Docker
  test      Uses pipeline.test.conf + Docker (always clean)
  staging   Uses pipeline.staging.conf + Docker + S3
  prod      Uses pipeline.prod.conf + Docker + S3 + elevation

Examples:
  # Local dev — use auto-detected config
  ./run-tile-pipeline.sh singapore

  # Force fresh OSM download
  ./run-tile-pipeline.sh singapore --force-download

  # Staging — uses pipeline.staging.conf automatically
  VALHALLA_ENV=staging ./run-tile-pipeline.sh singapore

  # Production dry-run
  VALHALLA_ENV=prod ./run-tile-pipeline.sh singapore --dry-run

  # Custom config path (CI/CD)
  ./run-tile-pipeline.sh singapore --pipeline-config /etc/valhalla/pipeline.conf

  # Cron job example (every Tuesday 02:00 SGT = Monday 18:00 UTC):
  # 0 18 * * 1 cd /opt/valhalla && VALHALLA_ENV=prod ./deploy/scripts/run-tile-pipeline.sh singapore >> /var/log/valhalla/cron.log 2>&1

EOF
}

run_pipeline "$@"
