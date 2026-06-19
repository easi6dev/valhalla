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
# Reject tile-builder images that risk a tile/JAR version skew → SIGBUS.
# The tile builder's libvalhalla MUST match the libvalhalla.so.3 bundled in the
# JNI JAR. Two image patterns are forbidden because their version drifts away
# from the JAR independently:
#   1. ghcr.io/valhalla/valhalla:latest  — floating UPSTREAM tag (the original
#      SIGBUS cause). Not built from this repo at all.
#   2. our ECR repo with a BARE env tag (…/valhalla:development|production|
#      staging|test) — NOT produced by build-valhalla-image.yml, which only
#      pushes <branch>-latest and <branch>-<sha>. A bare tag is orphaned/manual
#      and can point at a different commit than the published JAR.
# The maintained, JAR-coupled tags are <branch>-latest or <branch>-<sha>
# (publish-jni-jar.yml extracts the JAR from <branch>-latest).
# A binary executor (VALHALLA_BUILD_TILES_BIN) or an empty image are NOT rejected
# here — _check_deps handles the empty-image-with-docker case.
# ---------------------------------------------------------------------------
_reject_unsafe_docker_image() {
    local image="$1"
    [[ -z "${image}" ]] && return 0

    if [[ "${image}" == ghcr.io/valhalla/valhalla:* ]]; then
        log_error "VALHALLA_DOCKER_IMAGE is a floating UPSTREAM image: '${image}'."
        log_error "Tiles MUST be built from THIS repo (docker/Dockerfile.prod / Dockerfile.tilebuilder) to match the JAR's libvalhalla.so.3 — upstream drifts → SIGBUS in AutoCost::Allowed."
        log_error "Use the CI-built ECR tag instead (e.g. <branch>-latest), set in pipeline.${VALHALLA_ENV}.conf."
        exit 1
    fi

    # Bare ECR env tag with no -latest / -<sha> suffix → not CI-maintained.
    if [[ "${image}" =~ /valhalla:(development|production|staging|test|prod-us|stage-us)$ ]]; then
        local bare_tag="${image##*:}"
        log_error "VALHALLA_DOCKER_IMAGE uses the BARE tag '${bare_tag}' (${image})."
        log_error "build-valhalla-image.yml only publishes '<branch>-latest' and '<branch>-<sha>'. A bare tag is orphaned/manual and may point at a DIFFERENT commit than the published JAR → SIGBUS in AutoCost::Allowed."
        log_error "Pin to the maintained tag, e.g. '${image}-latest' (the JAR is published from <branch>-latest), in pipeline.${VALHALLA_ENV}.conf."
        exit 1
    fi
}

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
    # Normalize: strip trailing slash, then ensure s3:// prefix
    if [[ -n "${S3_TILE_BUCKET}" ]]; then
        S3_TILE_BUCKET="${S3_TILE_BUCKET%/}"
        [[ "${S3_TILE_BUCKET}" != s3://* ]] && S3_TILE_BUCKET="s3://${S3_TILE_BUCKET}"
    fi
    S3_REGION="${S3_REGION:-ap-southeast-1}"
    VALHALLA_BUILD_TILES_BIN="${VALHALLA_BUILD_TILES_BIN:-}"
    # NO floating-upstream fallback. The tile builder MUST be a binary/image built
    # from THIS repo so the tile layout matches the libvalhalla.so.3 in the JNI
    # JAR; a version skew causes SIGBUS in costing (AutoCost::Allowed) on every
    # route. Leave blank only if a from-source valhalla_build_tiles is on PATH or
    # VALHALLA_BUILD_TILES_BIN is set.
    VALHALLA_DOCKER_IMAGE="${VALHALLA_DOCKER_IMAGE:-}"
    _reject_unsafe_docker_image "${VALHALLA_DOCKER_IMAGE}"

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
        if [[ -z "${VALHALLA_DOCKER_IMAGE}" ]]; then
            log_error "No tile builder configured: VALHALLA_BUILD_TILES_BIN is unset, no system valhalla_build_tiles on PATH, and VALHALLA_DOCKER_IMAGE is blank."
            log_error "Set VALHALLA_DOCKER_IMAGE to a from-source image (docker/Dockerfile.tilebuilder, e.g. an ECR tag) in pipeline.${VALHALLA_ENV}.conf — NOT ghcr.io/valhalla/valhalla:latest."
            exit 1
        fi
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
# Phase 2 & 3: Admin Build + Tile Build (admins must precede tiles)
# ---------------------------------------------------------------------------
phase_build() {
    set_phase "Phase 2: Admin Build"

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

    # Admin DB must exist BEFORE tile build: valhalla_build_tiles reads
    # admins.sqlite during its Enhance stage to stamp country/state onto each
    # edge. Running it after the tile build (as before) produced the DB but
    # never consumed it — tiles shipped without admin data. Non-critical: a
    # missing admin DB only degrades admin-scoped routing, so we continue.
    _run_admin_build "${build_config}" || log_warn "Admin build failed (non-critical — continuing)"

    set_phase "Phase 3: Tile Build"
    retry "${MAX_BUILD_RETRIES}" "${BUILD_RETRY_DELAY}" "Tile build" -- \
        _run_tile_build "${build_config}"

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
    else
        jq --arg dir "${VERSIONED_TILE_DIR}" '.additional_data.elevation = $dir' "${output}" > "${output}.tmp"
        mv "${output}.tmp" "${output}"
        log_info "Elevation dir: ${VERSIONED_TILE_DIR}"
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
# Phase 3.5: Build tile extract (.tar with embedded index.bin)
# ---------------------------------------------------------------------------
# Packs the versioned tile dir into a single mmap-able tar via
# scripts/valhalla_build_extract. That script writes an index.bin as the FIRST
# member of the tar (fixed-width {offset, tile_id, size} records), which lets
# tile_extract_t initialize in milliseconds without scanning the whole archive
# and removes the singleton constraint on runtime tileset reloading
# (valhalla/valhalla#3117, PR #3281). A plain `tar` would NOT write this index.
# The tar is built before validate/S3 so it is versioned, uploaded, and swapped
# alongside the tiles.
# ---------------------------------------------------------------------------
phase_extract() {
    set_phase "Phase 3.5: Build Tile Extract"

    TILE_EXTRACT="${VERSIONED_TILE_DIR}/${REGION}.tar"

    if [[ "${BUILD_EXTRACT}" == false ]]; then
        log_info "Tile extract disabled (--no-extract) — skipping"
        TILE_EXTRACT=""
        return 0
    fi

    if [[ "${DRY_RUN}" == true ]]; then
        log_dry "Would build tile extract: ${VERSIONED_TILE_DIR} → ${TILE_EXTRACT}"
        return 0
    fi

    local extract_log="${VALHALLA_LOG_DIR}/extract-${REGION}-${RUN_ID}.log"
    log_info "Building tile extract → ${TILE_EXTRACT}"
    log_info "Extract log: ${extract_log}"

    if [[ "${USE_DOCKER}" == true ]]; then
        # Run the bundled python script inside the image. tile_dir → mounted
        # tiles, tile_extract → same mount so the .tar lands in the host dir.
        docker run --rm \
            -v "${VERSIONED_TILE_DIR}:/valhalla/tiles" \
            "${VALHALLA_DOCKER_IMAGE}" \
            valhalla_build_extract \
            --inline-config "{\"mjolnir\":{\"tile_dir\":\"/valhalla/tiles\",\"tile_extract\":\"/valhalla/tiles/${REGION}.tar\"}}" \
            --overwrite -v \
            2>&1 | tee -a "${extract_log}" | _log_stream "EXTRACT"
        local extract_exit=${PIPESTATUS[0]:-$?}
    else
        # Native: prefer the in-tree script so it matches this checkout.
        local extract_script="${PROJECT_ROOT}/scripts/valhalla_build_extract"
        local runner=()
        if [[ -x "${extract_script}" ]]; then
            runner=(python3 "${extract_script}")
        elif command -v valhalla_build_extract &>/dev/null; then
            runner=(valhalla_build_extract)
        else
            log_error "valhalla_build_extract not found (checked ${extract_script} and PATH)"
            return 3
        fi
        "${runner[@]}" \
            --inline-config "{\"mjolnir\":{\"tile_dir\":\"${VERSIONED_TILE_DIR}\",\"tile_extract\":\"${TILE_EXTRACT}\"}}" \
            --overwrite -v \
            2>&1 | tee -a "${extract_log}" | _log_stream "EXTRACT"
        local extract_exit=${PIPESTATUS[0]:-$?}
    fi

    if [[ ${extract_exit} -ne 0 ]]; then
        log_error "Tile extract build failed (exit ${extract_exit})"
        return 3
    fi

    if [[ ! -f "${TILE_EXTRACT}" ]]; then
        log_error "Extract reported success but ${TILE_EXTRACT} is missing"
        return 3
    fi

    # Verify index.bin is the FIRST member — this is the whole point of the step.
    # `tar tf | head -1` is unsafe here: head closes the pipe after one line, tar
    # keeps writing and hits EPIPE; since `trap '' PIPE` ignores SIGPIPE, tar exits
    # 2, and `set -o pipefail` + the command substitution would abort the whole
    # script (exit 2) BEFORE this check runs — even on a valid extract. `|| true`
    # swallows tar's EPIPE exit; the index.bin comparison is the real check.
    local first_member
    first_member="$( { tar tf "${TILE_EXTRACT}" 2>/dev/null || true; } | head -n1 )"
    if [[ "${first_member}" == "index.bin" ]]; then
        log_ok "Tile extract built with index.bin: $(du -sh "${TILE_EXTRACT}" | cut -f1)"
    else
        log_error "Tile extract missing index.bin as first member (found: '${first_member}')"
        return 3
    fi
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

    # Check 7: Tile extract present with index.bin (skipped if --no-extract)
    if [[ "${BUILD_EXTRACT}" == true ]]; then
        if [[ -f "${TILE_EXTRACT}" ]]; then
            # `|| true` swallows tar's EPIPE exit (head closes the pipe early;
            # SIGPIPE is trapped, so tar exits 2 and would abort under pipefail).
            local first_member
            first_member="$( { tar tf "${TILE_EXTRACT}" 2>/dev/null || true; } | head -n1 )"
            if [[ "${first_member}" == "index.bin" ]]; then
                log_ok "Tile extract: $(du -sh "${TILE_EXTRACT}" | cut -f1) (index.bin present)"
            else
                log_error "Tile extract missing index.bin (first member: '${first_member}')"
                (( errors++ ))
            fi
        else
            log_error "Tile extract missing: ${TILE_EXTRACT}"
            (( errors++ ))
        fi
    fi

    if [[ ${errors} -gt 0 ]]; then
        log_error "Validation failed with ${errors} error(s)"
        exit 4
    fi

    log_ok "Validation passed"
}

# ---------------------------------------------------------------------------
# Phase 4.5: Tar Extract — pack tiles into tiles.tar for mmap (tile_extract)
# ---------------------------------------------------------------------------
# Creates tiles.tar alongside the existing 0/,1/,2/ directories so Valhalla
# can load tiles via MAP_SHARED mmap. With tile_extract configured alongside
# tile_dir, the OS shares physical pages across all Actor pool instances —
# pool memory cost becomes ~1× tile data instead of N× (one per Actor).
# tile_dir remains in the config as a fallback if the tar is absent.
# ---------------------------------------------------------------------------
phase_tar_extract() {
    set_phase "Phase 4.5: Tar Extract"

    local tar_path="${VERSIONED_TILE_DIR}/tiles.tar"

    if [[ "${DRY_RUN}" == true ]]; then
        log_dry "Would build tar extract: ${tar_path}"
        return 0
    fi

    # In --skip-build mode VERSIONED_TILE_DIR points to the live 'latest' directory.
    # Overwriting tiles.tar there would truncate a file that running Valhalla actors
    # may have mmap'd (MAP_SHARED). Skip if the tar already exists; delete it first
    # if you explicitly want to rebuild.
    if [[ "${SKIP_BUILD}" == true ]] && [[ -s "${tar_path}" ]]; then
        log_info "Skipping tar extract (--skip-build, tiles.tar already exists at ${tar_path})"
        return 0
    fi

    # Prefer valhalla_build_extract — writes index.bin as the first member so
    # Valhalla uses the fast indexed load path at startup. Without index.bin
    # Valhalla falls back to a full tar scan (still works, but slower and
    # prints a startup WARN).
    local extract_config="${VALHALLA_LOG_DIR}/valhalla-extract-${REGION}-${RUN_ID}.json"
    local extract_log="${VALHALLA_LOG_DIR}/valhalla-extract-${REGION}-${RUN_ID}.log"
    jq -n \
        --arg td "${VERSIONED_TILE_DIR}" \
        --arg te "${tar_path}" \
        '{"mjolnir":{"tile_dir":$td,"tile_extract":$te}}' > "${extract_config}"

    if [[ "${USE_DOCKER}" == true ]]; then
        # Docker path — valhalla_build_extract is always available in the image.
        # Cannot use _run_docker_command here because it unconditionally appends
        # the OSM .pbf positional which valhalla_build_extract does not accept.
        log_info "Building tile extract with index (Docker: valhalla_build_extract)..."
        local config_dir
        config_dir="$(dirname "${extract_config}")"
        local docker_config="${config_dir}/valhalla-docker-extract-${RUN_ID}.json"
        sed \
            -e "s|${VERSIONED_TILE_DIR}|/valhalla/tiles|g" \
            "${extract_config}" > "${docker_config}"
        docker run --rm \
            -v "${VERSIONED_TILE_DIR}:/valhalla/tiles" \
            -v "${config_dir}:/valhalla/config" \
            "${VALHALLA_DOCKER_IMAGE}" \
            valhalla_build_extract \
            -c "/valhalla/config/$(basename "${docker_config}")" \
            --overwrite \
            2>&1 | tee -a "${extract_log}" | _log_stream "valhalla_build_extract"
        rm -f "${docker_config}"
    elif command -v valhalla_build_extract &>/dev/null || [[ -x "${VALHALLA_BUILD_TILES_BIN%tiles}extract" ]]; then
        local extract_bin
        extract_bin="$(command -v valhalla_build_extract 2>/dev/null || echo "${VALHALLA_BUILD_TILES_BIN%tiles}extract")"
        log_info "Building tile extract with index (${extract_bin})..."
        "${extract_bin}" -c "${extract_config}" --overwrite 2>&1 | tee -a "${extract_log}"
    else
        # Fallback: plain tar — functional but no index.bin; Valhalla will WARN
        # at startup about degraded performance for tile loading.
        log_warn "valhalla_build_extract not found — falling back to plain tar (no index.bin)"
        ( cd "${VERSIONED_TILE_DIR}" && tar cf tiles.tar 0 1 2 ) \
            2>&1 | tee -a "${VALHALLA_LOG_DIR}/tar-extract-${REGION}-${RUN_ID}.log"
    fi
    rm -f "${extract_config}"

    if [[ ! -s "${tar_path}" ]]; then
        log_error "tiles.tar was not produced at ${tar_path}"
        exit 4
    fi

    log_ok "Tile extract ready: ${tar_path} ($(du -sh "${tar_path}" | cut -f1))"
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
# Phase 6.5: EFS Tile Sync
# ---------------------------------------------------------------------------
# Mirrors the just-built tiles to EFS so the tada-traffic-data-builder cron
# (running in a separate pod) can mmap the .gph files at
# ${VALHALLA_EFS_DIR}/${REGION}/latest. Without this, that cron's call to
# read_directed_edge_count silently hits FileNotFoundError, returns 0 for
# every tile, and the cron emits a syntactically-valid but empty traffic.tar
# (32-byte headers, no per-edge entries).
#
# Runs AFTER geometry_mapping so the EFS swap only happens when both the
# tiles and the matching mapping.json are ready — readers see the old
# {tiles, mapping} pair consistently until the symlink flips.
#
# Skipped when VALHALLA_EFS_DIR is unset/absent — local dev path.
# ---------------------------------------------------------------------------
phase_efs_sync() {
    set_phase "Phase 6.5: EFS Tile Sync"

    local efs_dir="${VALHALLA_EFS_DIR:-/mnt/efs/valhalla_tiles}"
    if [[ ! -d "${efs_dir}" ]]; then
        log_info "EFS dir not present at ${efs_dir} — skipping EFS sync (local dev)"
        return 0
    fi

    if [[ "${DRY_RUN}" == true ]]; then
        log_dry "Would copy: ${VERSIONED_TILE_DIR} → ${efs_dir}/${REGION}/v${VERSION_TAG}"
        log_dry "Would update: ${efs_dir}/${REGION}/latest → v${VERSION_TAG}"
        return 0
    fi

    local efs_region_dir="${efs_dir}/${REGION}"
    local efs_versioned_dir="${efs_region_dir}/v${VERSION_TAG}"
    local efs_latest_link="${efs_region_dir}/latest"
    local efs_partial_dir="${efs_versioned_dir}.partial"

    mkdir -p "${efs_region_dir}"

    log_info "Copying tiles to EFS: ${efs_versioned_dir}"
    local start_epoch
    start_epoch="$(date +%s)"

    # Copy to .partial first; rename on success. Prevents a partial copy
    # from being observable via the latest symlink if cp dies mid-run.
    rm -rf "${efs_partial_dir}"
    if ! cp -r "${VERSIONED_TILE_DIR}" "${efs_partial_dir}"; then
        log_error "EFS copy failed: ${VERSIONED_TILE_DIR} → ${efs_partial_dir}"
        rm -rf "${efs_partial_dir}"
        return 5
    fi
    mv -T "${efs_partial_dir}" "${efs_versioned_dir}"

    local elapsed=$(( $(date +%s) - start_epoch ))
    local size
    size="$(du -sh "${efs_versioned_dir}" | cut -f1)"
    log_ok "EFS copy complete: ${size} in ${elapsed}s"

    # Atomic symlink swap. Readers see either the old version or the new,
    # never a half-state. Two preconditions ln -sfn alone doesn't handle:
    #
    # 1. If ${efs_latest_link} pre-exists as a real DIRECTORY (e.g. created
    #    by region bootstrap before this script ever ran), `ln -sfn target
    #    dir` does NOT replace it — it silently creates `dir/target` inside,
    #    producing a useless self-referencing symlink. We must rmdir the
    #    (presumed-empty) placeholder first.
    # 2. If it pre-exists as a symlink to the same target, ln -sfn is a
    #    no-op; harmless.
    if [[ -d "${efs_latest_link}" && ! -L "${efs_latest_link}" ]]; then
        if [[ -n "$(ls -A "${efs_latest_link}" 2>/dev/null)" ]]; then
            log_error "EFS latest exists as a non-empty directory: ${efs_latest_link}. Manual cleanup required."
            return 5
        fi
        log_info "Removing pre-existing empty directory at ${efs_latest_link} (bootstrap placeholder)"
        rmdir "${efs_latest_link}"
    fi
    ln -sfn "v${VERSION_TAG}" "${efs_latest_link}"
    log_ok "EFS latest symlink updated: ${efs_latest_link} → v${VERSION_TAG}"

    # Prune old EFS versions — keep last N. Same retention as local cleanup.
    local versions
    mapfile -t versions < <(
        find "${efs_region_dir}" -maxdepth 1 -type d -name "v[0-9]*" \
        | sort
    )
    local total=${#versions[@]}
    local to_remove=$(( total - KEEP_VERSIONS ))
    if [[ ${to_remove} -gt 0 ]]; then
        log_info "EFS versions: ${total} (keeping ${KEEP_VERSIONS}); removing ${to_remove} oldest"
        for (( i=0; i<to_remove; i++ )); do
            local old="${versions[$i]}"
            log_info "Removing old EFS version: $(basename "${old}")"
            rm -rf "${old}"
        done
    else
        log_info "EFS versions: ${total} (keeping ${KEEP_VERSIONS}) — nothing to prune"
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
    SKIP_GEOMETRY_MAPPING=false
    BUILD_EXTRACT=true
    TILE_EXTRACT=""
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
            --with-elevation)   SKIP_ELEVATION_ARG=false;  shift   ;;
            --skip-build)       SKIP_BUILD=true;            shift   ;;
            --skip-geometry-mapping) SKIP_GEOMETRY_MAPPING=true; shift ;;
            --no-extract)       BUILD_EXTRACT=false;        shift   ;;
            --keep-versions)    KEEP_VERSIONS_ARG="$2";    shift 2 ;;
            --dry-run)          DRY_RUN=true;               shift   ;;
            --notify-url)       NOTIFY_URL="$2";            shift 2 ;;
            -h|--help)          show_usage; exit 0 ;;
            *) log_error "Unknown option: $1"; show_usage; exit 1 ;;
        esac
    done

    # SKIP_ELEVATION precedence: CLI flag (--no-elevation/--with-elevation) >
    # env var > conf file. bootstrap()'s _load_pipeline_config sources the conf,
    # which sets SKIP_ELEVATION and would otherwise clobber both the flag and an
    # env override. Capture any pre-bootstrap env value here, then re-assert the
    # correct precedence AFTER bootstrap (below).
    local skip_elev_env="${SKIP_ELEVATION:-}"

    # Run pipeline phases
    bootstrap

    # Re-apply precedence now that the conf has been sourced. SKIP_ELEVATION_ARG
    # is "true" for --no-elevation, "false" for --with-elevation, "" if neither.
    if [[ -n "${SKIP_ELEVATION_ARG}" ]]; then
        SKIP_ELEVATION="${SKIP_ELEVATION_ARG}"    # explicit CLI flag always wins
    elif [[ -n "${skip_elev_env}" ]]; then
        SKIP_ELEVATION="${skip_elev_env}"         # explicit env beats conf
    fi
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
    phase_extract
    phase_validate
    phase_tar_extract
    phase_s3_sync
    phase_swap_latest
    phase_cleanup
    geometry_mapping
    phase_efs_sync

    log_ok "Pipeline completed successfully — v${VERSION_TAG}"
    exit ${PIPELINE_EXIT_CODE}
}

main "$@"
