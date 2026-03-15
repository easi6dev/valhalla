#!/bin/bash
# =============================================================================
# Valhalla Tile Generation Pipeline
# =============================================================================
# Single entrypoint for the full tile generation lifecycle:
#   OSM download → tile build → admin build → validate → S3 sync → swap latest
#
# Designed to run as a weekly cron job across all environments.
#
# Usage:
#   ./run-tile-pipeline.sh <region> [OPTIONS]
#
# Options:
#   --pipeline-config <path>  Path to pipeline .conf file
#   --force-download          Re-download OSM even if file is fresh
#   --osm-max-age-days <n>    Re-download if OSM file is older than N days (default: 6)
#   --no-elevation            Skip elevation data (faster build)
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
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Retry settings
readonly MAX_DOWNLOAD_RETRIES=3
readonly DOWNLOAD_RETRY_DELAY=30   # seconds between retries
readonly MAX_BUILD_RETRIES=2
readonly BUILD_RETRY_DELAY=60

# ---------------------------------------------------------------------------
# Color codes
# ---------------------------------------------------------------------------
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
# RUN_ID and LOG_FILE are set after config is loaded (paths depend on config)
RUN_ID=""
LOG_FILE=""

_log() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

    # JSON structured log line (machine-readable)
    local json_line
    json_line="{\"ts\":\"${timestamp}\",\"level\":\"${level}\",\"run\":\"${RUN_ID:-init}\",\"region\":\"${REGION:-unknown}\",\"msg\":$(printf '%s' "${message}" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null || echo "\"${message}\"")}"

    # Write to log file if available
    if [[ -n "${LOG_FILE}" ]]; then
        echo "${json_line}" >> "${LOG_FILE}"
    fi

    # Human-readable console output
    case "${level}" in
        INFO)  echo -e "${CYAN}[$(date '+%H:%M:%S')]${NC} ${message}" ;;
        OK)    echo -e "${GREEN}[$(date '+%H:%M:%S')] ✓${NC} ${message}" ;;
        WARN)  echo -e "${YELLOW}[$(date '+%H:%M:%S')] ⚠${NC} ${message}" ;;
        ERROR) echo -e "${RED}[$(date '+%H:%M:%S')] ✗${NC} ${message}" >&2 ;;
        PHASE) echo -e "\n${BOLD}${CYAN}━━━ ${message} ━━━${NC}" ;;
        DRY)   echo -e "${YELLOW}[DRY-RUN]${NC} ${message}" ;;
    esac
}

log_info()  { _log INFO  "$1"; }
log_ok()    { _log OK    "$1"; }
log_warn()  { _log WARN  "$1"; }
log_error() { _log ERROR "$1"; }
log_phase() { _log PHASE "$1"; }
log_dry()   { _log DRY   "$1"; }

# ---------------------------------------------------------------------------
# Exit handler — always emit a final summary
# ---------------------------------------------------------------------------
PIPELINE_START_TIME=""
PIPELINE_EXIT_CODE=0
PHASE_REACHED=""

on_exit() {
    local exit_code=$?
    local end_time
    end_time="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    local duration=""
    if [[ -n "${PIPELINE_START_TIME}" ]]; then
        local start_epoch end_epoch
        start_epoch="$(date -d "${PIPELINE_START_TIME}" +%s 2>/dev/null || echo 0)"
        end_epoch="$(date +%s)"
        duration="$(( end_epoch - start_epoch ))s"
    fi

    local status="SUCCESS"
    [[ ${exit_code} -ne 0 ]] && status="FAILED"

    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}Pipeline ${status} — Run: ${RUN_ID:-unknown}${NC}"
    echo -e "  Region:      ${REGION:-unknown}"
    echo -e "  Environment: ${VALHALLA_ENV:-unknown}"
    echo -e "  Exit code:   ${exit_code}"
    echo -e "  Duration:    ${duration:-unknown}"
    echo -e "  Last phase:  ${PHASE_REACHED:-bootstrap}"
    [[ -n "${LOG_FILE}" ]] && echo -e "  Log file:    ${LOG_FILE}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    # Structured final log entry
    if [[ -n "${LOG_FILE}" ]]; then
        echo "{\"ts\":\"${end_time}\",\"level\":\"SUMMARY\",\"run\":\"${RUN_ID:-unknown}\",\"region\":\"${REGION:-unknown}\",\"status\":\"${status}\",\"exit_code\":${exit_code},\"duration\":\"${duration}\",\"phase\":\"${PHASE_REACHED:-bootstrap}\"}" >> "${LOG_FILE}"
    fi

    # Webhook notification if configured
    if [[ -n "${NOTIFY_URL:-}" ]] && command -v curl &>/dev/null; then
        local payload
        payload="{\"run\":\"${RUN_ID:-unknown}\",\"region\":\"${REGION:-unknown}\",\"env\":\"${VALHALLA_ENV:-unknown}\",\"status\":\"${status}\",\"exit_code\":${exit_code},\"duration\":\"${duration}\"}"
        curl -s -X POST "${NOTIFY_URL}" \
            -H "Content-Type: application/json" \
            -d "${payload}" \
            --max-time 10 \
            --retry 2 || log_warn "Webhook notification failed"
    fi
}
trap on_exit EXIT

# ---------------------------------------------------------------------------
# Phase tracking — used by on_exit handler
# ---------------------------------------------------------------------------
set_phase() {
    PHASE_REACHED="$1"
    log_phase "$1"
}

# ---------------------------------------------------------------------------
# Retry helper
# ---------------------------------------------------------------------------
# Usage: retry <max_attempts> <delay_seconds> <description> -- <command> [args...]
retry() {
    local max_attempts="$1"
    local delay="$2"
    local description="$3"
    shift 3
    # consume '--' separator
    if [[ "${1:-}" == "--" ]]; then shift; fi

    local attempt=1
    while true; do
        log_info "Attempt ${attempt}/${max_attempts}: ${description}"
        if "$@"; then
            return 0
        fi
        local exit_code=$?
        if [[ ${attempt} -ge ${max_attempts} ]]; then
            log_error "All ${max_attempts} attempts failed for: ${description}"
            return ${exit_code}
        fi
        log_warn "Attempt ${attempt} failed (exit ${exit_code}). Retrying in ${delay}s..."
        sleep "${delay}"
        (( attempt++ ))
    done
}

# ---------------------------------------------------------------------------
# Phase 0: Bootstrap — load config, validate deps, create run ID
# ---------------------------------------------------------------------------
bootstrap() {
    PIPELINE_START_TIME="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    RUN_ID="$(date -u '+%Y%m%d-%H%M%S')"

    log_phase "Phase 0: Bootstrap"
    log_info "Script version: ${SCRIPT_VERSION}"
    log_info "Run ID:         ${RUN_ID}"
    log_info "Region:         ${REGION}"
    log_info "Environment:    ${VALHALLA_ENV}"
    log_info "Dry run:        ${DRY_RUN}"

    # Load pipeline config
    _load_pipeline_config "${PIPELINE_CONFIG_FILE:-}"

    # Apply config-file values as defaults (CLI flags already set take precedence)
    VALHALLA_TILE_DIR="${VALHALLA_TILE_DIR:-${PROJECT_ROOT}/data/valhalla_tiles}"
    OSM_DIR="${OSM_DIR:-${PROJECT_ROOT}/data/osm}"
    VALHALLA_ADMIN_DIR="${VALHALLA_ADMIN_DIR:-${PROJECT_ROOT}/data/admin_data}"
    VALHALLA_LOG_DIR="${VALHALLA_LOG_DIR:-${PROJECT_ROOT}/logs}"
    SKIP_ELEVATION="${SKIP_ELEVATION:-false}"
    KEEP_VERSIONS="${KEEP_VERSIONS_ARG:-${KEEP_VERSIONS:-3}}"
    S3_TILE_BUCKET="${S3_TILE_BUCKET:-}"
    S3_REGION="${S3_REGION:-ap-southeast-1}"
    VALHALLA_BUILD_TILES_BIN="${VALHALLA_BUILD_TILES_BIN:-}"
    VALHALLA_DOCKER_IMAGE="${VALHALLA_DOCKER_IMAGE:-ghcr.io/valhalla/valhalla:latest}"

    # Derive versioned tile dir for this run
    VERSION_TAG="${RUN_ID}"
    VERSIONED_TILE_DIR="${VALHALLA_TILE_DIR}/${REGION}/v${VERSION_TAG}"
    LATEST_LINK="${VALHALLA_TILE_DIR}/${REGION}/latest"

    # Set up log file now that we have the log dir
    mkdir -p "${VALHALLA_LOG_DIR}"
    LOG_FILE="${VALHALLA_LOG_DIR}/pipeline-${REGION}-${RUN_ID}.log"
    log_info "Log file: ${LOG_FILE}"
    # Write opening log entry
    echo "{\"ts\":\"${PIPELINE_START_TIME}\",\"level\":\"START\",\"run\":\"${RUN_ID}\",\"region\":\"${REGION}\",\"env\":\"${VALHALLA_ENV}\",\"version\":\"${SCRIPT_VERSION}\"}" >> "${LOG_FILE}"

    # Validate region exists in regions.json
    local regions_config="${PROJECT_ROOT}/config/regions/regions.json"
    if ! jq -e ".regions.${REGION}" "${regions_config}" > /dev/null 2>&1; then
        log_error "Region '${REGION}' not found in ${regions_config}"
        log_info "Available regions:"
        jq -r '.regions | to_entries[] | "  \(.key) (\(if .value.enabled then "enabled" else "disabled" end))"' "${regions_config}"
        exit 1
    fi

    OSM_SOURCE="$(jq -r ".regions.${REGION}.osm_source" "${regions_config}")"
    OSM_FILE="${OSM_DIR}/${REGION}-latest.osm.pbf"

    log_info "OSM source:     ${OSM_SOURCE}"
    log_info "OSM file:       ${OSM_FILE}"
    log_info "Tile base dir:  ${VALHALLA_TILE_DIR}/${REGION}"
    log_info "This version:   v${VERSION_TAG}"
    log_info "Keep versions:  ${KEEP_VERSIONS}"

    # Check dependencies
    _check_deps

    log_ok "Bootstrap complete"
}

_load_pipeline_config() {
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
        log_info "Loaded pipeline config: ${config_file}"
    else
        log_warn "No pipeline config file found — using defaults and environment variables"
    fi
}

_check_deps() {
    log_info "Checking dependencies..."
    local missing=()

    command -v jq   &>/dev/null || missing+=("jq")
    command -v wget &>/dev/null || missing+=("wget")

    # Determine executor: binary > system PATH > Docker
    USE_DOCKER=false
    if [[ -n "${VALHALLA_BUILD_TILES_BIN}" && -x "${VALHALLA_BUILD_TILES_BIN}" ]]; then
        export PATH="$(dirname "${VALHALLA_BUILD_TILES_BIN}"):${PATH}"
        log_info "Executor: binary (${VALHALLA_BUILD_TILES_BIN})"
    elif command -v valhalla_build_tiles &>/dev/null; then
        log_info "Executor: system valhalla_build_tiles"
    elif command -v docker &>/dev/null; then
        USE_DOCKER=true
        log_info "Executor: Docker (${VALHALLA_DOCKER_IMAGE})"
    else
        missing+=("valhalla_build_tiles or docker")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required dependencies: ${missing[*]}"
        exit 1
    fi

    log_ok "All dependencies satisfied"
}

# ---------------------------------------------------------------------------
# Phase 1: OSM Check / Download
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

_download_osm() {
    local tmp_file="${OSM_FILE}.download.tmp"
    local md5_url="${OSM_SOURCE}.md5"
    local md5_file="${OSM_FILE}.md5"

    log_info "Downloading from: ${OSM_SOURCE}"

    # Check connectivity first
    if ! wget --spider --quiet --timeout=10 "${OSM_SOURCE}"; then
        log_error "Cannot reach ${OSM_SOURCE} — check network connectivity"
        return 1
    fi

    if ! wget \
        --progress=dot:giga \
        --continue \
        --tries=1 \
        --timeout=120 \
        --read-timeout=60 \
        -O "${tmp_file}" \
        "${OSM_SOURCE}" 2>&1 | tee -a "${LOG_FILE}"; then
        rm -f "${tmp_file}"
        log_error "Download failed"
        return 1
    fi

    # MD5 verification
    if wget -q -O "${md5_file}" "${md5_url}" 2>/dev/null; then
        local expected actual
        expected="$(cut -d' ' -f1 "${md5_file}")"
        actual="$(md5sum "${tmp_file}" | cut -d' ' -f1)"
        if [[ "${expected}" != "${actual}" ]]; then
            log_error "MD5 mismatch — expected: ${expected}, got: ${actual}"
            rm -f "${tmp_file}" "${md5_file}"
            return 1
        fi
        log_ok "MD5 verified: ${actual}"
        rm -f "${md5_file}"
    else
        log_warn "MD5 file not available — skipping integrity check"
    fi

    # Atomic move only after successful download + verification
    mv "${tmp_file}" "${OSM_FILE}"
    local file_size
    file_size="$(du -sh "${OSM_FILE}" | cut -f1)"
    log_ok "OSM downloaded: ${OSM_FILE} (${file_size})"
}

# ---------------------------------------------------------------------------
# Phase 2 & 3: Tile Build + Admin Build
# ---------------------------------------------------------------------------
phase_build() {
    set_phase "Phase 2: Tile Build"

    if [[ "${DRY_RUN}" == true ]]; then
        log_dry "Would build tiles: ${OSM_FILE} → ${VERSIONED_TILE_DIR}"
        return 0
    fi

    mkdir -p "${VERSIONED_TILE_DIR}"
    mkdir -p "${VALHALLA_ADMIN_DIR}"

    # Generate build config from template
    local config_template="${PROJECT_ROOT}/config/regions/${REGION}/valhalla-${REGION}.json"
    if [[ ! -f "${config_template}" ]]; then
        config_template="$(find "${PROJECT_ROOT}/config/regions" -name "valhalla-*.json" | head -1)"
    fi
    if [[ -z "${config_template}" ]]; then
        log_error "No Valhalla config template found"
        exit 3
    fi

    local build_config="${VALHALLA_LOG_DIR}/valhalla-build-${REGION}-${RUN_ID}.json"
    _generate_build_config "${config_template}" "${build_config}"

    retry "${MAX_BUILD_RETRIES}" "${BUILD_RETRY_DELAY}" "Tile build" -- \
        _run_tile_build "${build_config}"

    set_phase "Phase 3: Admin Build"
    _run_admin_build "${build_config}" || log_warn "Admin build failed (non-critical — continuing)"

    rm -f "${build_config}"
    log_ok "Build phase complete"
}

_generate_build_config() {
    local template="$1"
    local output="$2"

    cp "${template}" "${output}"

    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "s|\"tile_dir\":.*|\"tile_dir\": \"${VERSIONED_TILE_DIR}\",|g" "${output}"
        sed -i '' "s|data/admin_data|${VALHALLA_ADMIN_DIR}|g" "${output}"
    else
        sed -i "s|\"tile_dir\":.*|\"tile_dir\": \"${VERSIONED_TILE_DIR}\",|g" "${output}"
        sed -i "s|data/admin_data|${VALHALLA_ADMIN_DIR}|g" "${output}"
    fi

    if [[ "${SKIP_ELEVATION}" == true ]]; then
        jq 'del(.additional_data.elevation)' "${output}" > "${output}.tmp"
        mv "${output}.tmp" "${output}"
        log_info "Elevation processing disabled"
    fi

    log_info "Build config: ${output}"
}

_run_tile_build() {
    local build_config="$1"
    local build_log="${VALHALLA_LOG_DIR}/tile-build-${REGION}-${RUN_ID}.log"

    log_info "Starting tile build → ${VERSIONED_TILE_DIR}"
    log_info "Build log: ${build_log}"

    local start_epoch
    start_epoch="$(date +%s)"

    if [[ "${USE_DOCKER}" == true ]]; then
        _run_docker_command "${build_config}" "valhalla_build_tiles" "${build_log}"
    else
        valhalla_build_tiles \
            -c "${build_config}" \
            "${OSM_FILE}" 2>&1 | tee -a "${build_log}" | _log_stream "BUILD"
    fi

    local exit_code=${PIPESTATUS[0]:-$?}

    local elapsed=$(( $(date +%s) - start_epoch ))
    log_info "Tile build took: ${elapsed}s"

    if [[ ${exit_code} -ne 0 ]]; then
        log_error "Tile build failed (exit ${exit_code})"
        return ${exit_code}
    fi

    local tile_count
    tile_count="$(find "${VERSIONED_TILE_DIR}" -name "*.gph" 2>/dev/null | wc -l)"
    if [[ ${tile_count} -eq 0 ]]; then
        log_error "Build reported success but no .gph tiles found"
        return 3
    fi

    local tile_size
    tile_size="$(du -sh "${VERSIONED_TILE_DIR}" | cut -f1)"
    log_ok "Tiles built: ${tile_count} files, ${tile_size}"
}

_run_admin_build() {
    local build_config="$1"
    local admin_log="${VALHALLA_LOG_DIR}/admin-build-${REGION}-${RUN_ID}.log"

    if [[ "${USE_DOCKER}" == true ]]; then
        _run_docker_command "${build_config}" "valhalla_build_admins" "${admin_log}"
    elif command -v valhalla_build_admins &>/dev/null; then
        valhalla_build_admins \
            -c "${build_config}" \
            "${OSM_FILE}" 2>&1 | tee -a "${admin_log}" | _log_stream "ADMIN"
    else
        log_warn "valhalla_build_admins not available — skipping"
        return 0
    fi
}

_run_docker_command() {
    local build_config="$1"
    local command="$2"
    local log_file="$3"

    # Pull image if needed
    if ! docker image inspect "${VALHALLA_DOCKER_IMAGE}" &>/dev/null; then
        log_info "Pulling Docker image: ${VALHALLA_DOCKER_IMAGE}"
        docker pull "${VALHALLA_DOCKER_IMAGE}"
    fi

    local config_dir
    config_dir="$(dirname "${build_config}")"
    local docker_config="${config_dir}/valhalla-docker-${RUN_ID}.json"

    sed \
        -e "s|${VERSIONED_TILE_DIR}|/valhalla/tiles|g" \
        -e "s|${VALHALLA_ADMIN_DIR}|/valhalla/admin|g" \
        -e "s|${OSM_DIR}|/valhalla/osm|g" \
        "${build_config}" > "${docker_config}"

    docker run --rm \
        -v "${VERSIONED_TILE_DIR}:/valhalla/tiles" \
        -v "${OSM_DIR}:/valhalla/osm" \
        -v "${VALHALLA_ADMIN_DIR}:/valhalla/admin" \
        -v "${config_dir}:/valhalla/config" \
        "${VALHALLA_DOCKER_IMAGE}" \
        "${command}" \
        -c "/valhalla/config/$(basename "${docker_config}")" \
        "/valhalla/osm/${REGION}-latest.osm.pbf" \
        2>&1 | tee -a "${log_file}" | _log_stream "${command}"

    local exit_code=${PIPESTATUS[0]:-$?}
    rm -f "${docker_config}"
    return ${exit_code}
}

# Pipe filter: prefix each line with a log tag for the console
_log_stream() {
    local tag="$1"
    while IFS= read -r line; do
        echo -e "${CYAN}  [${tag}]${NC} ${line}"
    done
}

# ---------------------------------------------------------------------------
# Phase 4: Validate
# ---------------------------------------------------------------------------
phase_validate() {
    set_phase "Phase 4: Validate"

    if [[ "${DRY_RUN}" == true ]]; then
        log_dry "Would validate tiles in ${VERSIONED_TILE_DIR}"
        return 0
    fi

    local errors=0

    # Check 1: Directory exists
    if [[ -d "${VERSIONED_TILE_DIR}" ]]; then
        log_ok "Tile directory exists"
    else
        log_error "Tile directory missing: ${VERSIONED_TILE_DIR}"
        (( errors++ ))
    fi

    # Check 2: Tile files exist
    local tile_count
    tile_count="$(find "${VERSIONED_TILE_DIR}" -name "*.gph" 2>/dev/null | wc -l)"
    if [[ ${tile_count} -gt 0 ]]; then
        log_ok "Tile count: ${tile_count}"
    else
        log_error "No .gph tile files found"
        (( errors++ ))
    fi

    # Check 3: Minimum size
    local tile_mb
    tile_mb="$(du -sm "${VERSIONED_TILE_DIR}" 2>/dev/null | cut -f1)"
    if [[ ${tile_mb} -gt 10 ]]; then
        log_ok "Tile size: $(du -sh "${VERSIONED_TILE_DIR}" | cut -f1)"
    else
        log_error "Tiles too small: ${tile_mb} MB (expected > 10 MB)"
        (( errors++ ))
    fi

    # Check 4: Hierarchy levels
    local level_count
    level_count="$(find "${VERSIONED_TILE_DIR}" -maxdepth 1 -type d -name "[0-9]" | wc -l)"
    if [[ ${level_count} -gt 0 ]]; then
        log_ok "Tile hierarchy: ${level_count} level directories"
        find "${VERSIONED_TILE_DIR}" -maxdepth 1 -type d -name "[0-9]" | sort | while read -r dir; do
            local lvl_count
            lvl_count="$(find "${dir}" -name "*.gph" | wc -l)"
            log_info "  Level $(basename "${dir}"): ${lvl_count} tiles"
        done
    else
        log_warn "No level directories found (0/, 1/, 2/)"
    fi

    # Check 5: Admin DB
    if [[ -f "${VALHALLA_ADMIN_DIR}/admins.sqlite" ]]; then
        local admin_size
        admin_size="$(du -sh "${VALHALLA_ADMIN_DIR}/admins.sqlite" | cut -f1)"
        log_ok "Admin DB: ${admin_size}"
    else
        log_warn "Admin DB not found (non-critical)"
    fi

    # Check 6: Sample tile readable
    local sample
    sample="$(find "${VERSIONED_TILE_DIR}" -name "*.gph" -print -quit)"
    if [[ -n "${sample}" && -r "${sample}" ]]; then
        log_ok "Sample tile readable: $(basename "${sample}")"
    else
        log_error "Sample tile not readable"
        (( errors++ ))
    fi

    if [[ ${errors} -gt 0 ]]; then
        log_error "Validation failed with ${errors} error(s)"
        exit 4
    fi

    log_ok "Validation passed"
}

# ---------------------------------------------------------------------------
# Phase 5: S3 Sync (non-local environments only)
# ---------------------------------------------------------------------------
phase_s3_sync() {
    set_phase "Phase 5: S3 Sync"

    if [[ -z "${S3_TILE_BUCKET}" ]]; then
        log_info "S3_TILE_BUCKET not set — skipping S3 sync"
        return 0
    fi

    if ! command -v aws &>/dev/null; then
        log_warn "aws CLI not found — skipping S3 sync (exit 6)"
        PIPELINE_EXIT_CODE=6
        return 0
    fi

    if [[ "${DRY_RUN}" == true ]]; then
        log_dry "Would sync: ${VERSIONED_TILE_DIR} → ${S3_TILE_BUCKET}/${REGION}/v${VERSION_TAG}/"
        return 0
    fi

    local s3_versioned="${S3_TILE_BUCKET}/${REGION}/v${VERSION_TAG}"
    local s3_latest="${S3_TILE_BUCKET}/${REGION}/latest"

    log_info "Uploading tiles to: ${s3_versioned}"

    if ! aws s3 sync \
        "${VERSIONED_TILE_DIR}/" \
        "${s3_versioned}/" \
        --region "${S3_REGION}" \
        --no-progress \
        2>&1 | tee -a "${LOG_FILE}" | _log_stream "S3"; then
        log_error "S3 upload failed"
        exit 5
    fi

    log_ok "S3 upload complete: ${s3_versioned}"

    # Write a 'latest' pointer file in S3
    echo "v${VERSION_TAG}" | aws s3 cp - "${S3_TILE_BUCKET}/${REGION}/latest.txt" \
        --region "${S3_REGION}" \
        --content-type "text/plain" \
        2>&1 || log_warn "Failed to update S3 latest pointer"

    log_ok "S3 latest pointer updated: v${VERSION_TAG}"
}

# ---------------------------------------------------------------------------
# Phase 6: Swap Latest (local symlink — atomic)
# ---------------------------------------------------------------------------
phase_swap_latest() {
    set_phase "Phase 6: Swap Latest"

    if [[ "${DRY_RUN}" == true ]]; then
        log_dry "Would swap symlink: ${LATEST_LINK} → v${VERSION_TAG}"
        return 0
    fi

    local previous_version=""
    if [[ -L "${LATEST_LINK}" ]]; then
        previous_version="$(readlink "${LATEST_LINK}")"
        log_info "Previous latest: ${previous_version}"
    fi

    # ln -sfn is atomic on Linux (single syscall rename)
    ln -sfn "v${VERSION_TAG}" "${LATEST_LINK}"
    log_ok "Latest symlink updated: ${LATEST_LINK} → v${VERSION_TAG}"

    if [[ -n "${previous_version}" ]]; then
        log_info "Rollback available: ln -sfn ${previous_version} ${LATEST_LINK}"
    fi
}

# ---------------------------------------------------------------------------
# Phase 7: Cleanup old versions
# ---------------------------------------------------------------------------
phase_cleanup() {
    set_phase "Phase 7: Cleanup Old Versions"

    local tile_base="${VALHALLA_TILE_DIR}/${REGION}"
    local versions
    # List versioned dirs sorted oldest-first, excluding 'latest' symlink
    mapfile -t versions < <(
        find "${tile_base}" -maxdepth 1 -type d -name "v[0-9]*" \
        | sort
    )

    local total=${#versions[@]}
    local to_remove=$(( total - KEEP_VERSIONS ))

    if [[ ${to_remove} -le 0 ]]; then
        log_info "Versions present: ${total} (keeping ${KEEP_VERSIONS}) — nothing to remove"
        return 0
    fi

    log_info "Versions present: ${total}. Removing ${to_remove} oldest."

    for (( i=0; i<to_remove; i++ )); do
        local old_dir="${versions[$i]}"
        if [[ "${DRY_RUN}" == true ]]; then
            log_dry "Would remove: ${old_dir}"
        else
            log_info "Removing old version: $(basename "${old_dir}")"
            rm -rf "${old_dir}"
            log_ok "Removed: $(basename "${old_dir}")"
        fi
    done
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
  --skip-build              Skip OSM download and tile build; validate existing 'latest' tiles
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

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    if [[ $# -eq 0 ]]; then
        show_usage
        exit 1
    fi

    # Positional: region
    REGION="$1"
    shift

    # Defaults
    VALHALLA_ENV="${VALHALLA_ENV:-local}"
    PIPELINE_CONFIG_FILE=""
    FORCE_DOWNLOAD=false
    OSM_MAX_AGE_DAYS=6
    DRY_RUN=false
    SKIP_BUILD=false
    KEEP_VERSIONS_ARG=""
    NOTIFY_URL="${NOTIFY_URL:-}"
    SKIP_ELEVATION_ARG=""

    # Parse flags
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --pipeline-config)  PIPELINE_CONFIG_FILE="$2"; shift 2 ;;
            --force-download)   FORCE_DOWNLOAD=true;        shift   ;;
            --osm-max-age-days) OSM_MAX_AGE_DAYS="$2";     shift 2 ;;
            --no-elevation)     SKIP_ELEVATION_ARG=true;   shift   ;;
            --skip-build)       SKIP_BUILD=true;            shift   ;;
            --keep-versions)    KEEP_VERSIONS_ARG="$2";    shift 2 ;;
            --dry-run)          DRY_RUN=true;               shift   ;;
            --notify-url)       NOTIFY_URL="$2";            shift 2 ;;
            -h|--help)          show_usage; exit 0 ;;
            *) log_error "Unknown option: $1"; show_usage; exit 1 ;;
        esac
    done

    # CLI --no-elevation overrides config file value
    [[ -n "${SKIP_ELEVATION_ARG}" ]] && SKIP_ELEVATION=true

    # Run pipeline phases
    bootstrap
    if [[ "${SKIP_BUILD}" == true ]]; then
        local existing_latest="${VALHALLA_TILE_DIR}/${REGION}/latest"
        if [[ ! -e "${existing_latest}" ]]; then
            log_error "--skip-build requires an existing 'latest' symlink at: ${existing_latest}"
            exit 1
        fi
        VERSIONED_TILE_DIR="$(readlink -f "${existing_latest}")"
        VERSION_TAG="$(basename "${VERSIONED_TILE_DIR}")"
        log_info "Skipping build — using existing tiles: ${VERSIONED_TILE_DIR}"
    else
        phase_osm
        phase_build
    fi
    phase_validate
    phase_s3_sync
    phase_swap_latest
    phase_cleanup

    log_ok "Pipeline completed successfully — v${VERSION_TAG}"
    exit ${PIPELINE_EXIT_CODE}
}

main "$@"
