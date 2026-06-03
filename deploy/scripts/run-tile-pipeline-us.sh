#!/bin/bash
# =============================================================================
# Valhalla Tile Generation Pipeline — US CLUSTER (any region or tile group)
# =============================================================================
# Dedicated entrypoint for the US server cluster. Kept SEPARATE from
# run-tile-pipeline.sh (Singapore/APAC) on purpose: the US cluster has its own
# EFS mount and its own S3 bucket (us-east-1). Isolating the two pipelines means
# a change for one region can never break the other's weekly production build.
#
# Lifecycle:
#   OSM acquire → tile build → admin build → tile extract → validate → S3 sync
#   → swap latest → cleanup → (geometry mapping)
#
# Tiles are written DIRECTLY to VALHALLA_TILE_DIR (set to the shared EFS mount in
# prod/stage). Phase 6 (swap latest symlink) is what makes a new version live for
# every reader on that EFS — there is no separate copy-to-EFS step. S3 (Phase 5)
# is an archive. This mirrors the Singapore pipeline exactly.
#
# REGION RESOLUTION (region-agnostic — driven entirely by regions.json):
# The single <region> argument is a key under .regions in regions.json. Its
# on-disk tile layout (the "subdir") is resolved automatically:
#
#   • Grouped region  — region has  "tile_group": "<group>"  → tiles live under
#     <group>'s tile_dir; OSM is MERGED from the group's osm_sources. Every
#     member region of the group builds/serves ONE shared tile set, so routing
#     crosses state lines. Example: new_york / new_jersey / connecticut all map
#     to the "nyc_tri_state" group → tiles under .../nyc_tri_state/.
#
#   • Single region   — region has its own "tile_dir" and "osm_source" (no
#     tile_group) → tiles under that tile_dir; OSM is a single Geofabrik extract.
#     Same shape as Singapore on the SG pipeline. Example: a "florida" region
#     with tile_dir="florida" → tiles under .../florida/.
#
# ADDING A NEW US REGION is therefore a regions.json edit only — NO change to
# this script. Add either:
#   (a) a single region with "tile_dir" + "osm_source", or
#   (b) a member region with "tile_group", plus a .tile_groups.<group> entry
#       carrying "tile_dir" + "osm_sources[]" + "osm_file".
# Then run:  VALHALLA_ENV=prod-us ./run-tile-pipeline-us.sh <new_region>
# (Optionally add config/regions/<region>/valhalla-<region>.json for a custom
#  build template; otherwise the group/any template is used as a fallback.)
#
# Usage:
#   ./run-tile-pipeline-us.sh <region> [OPTIONS]      # region = a US region key
#
# Options:
#   --pipeline-config <path>  Path to pipeline .conf file
#   --force-download          Re-download + re-merge OSM even if fresh
#   --osm-max-age-days <n>    Re-merge if merged OSM is older than N days (default: 6)
#   --no-elevation            Skip elevation data (faster build)
#   --skip-build              Skip OSM + tile build; operate on existing 'latest'
#   --skip-geometry-mapping   Skip the geometry-mapping job (default: skipped for US)
#   --with-geometry-mapping   Force-run the geometry-mapping job
#   --no-extract              Skip building the .tar tile extract (index.bin)
#   --keep-versions <n>       Old tile versions to retain (default: 3)
#   --dry-run                 Print actions without executing
#   --notify-url <url>        POST webhook on completion/failure
#   -h, --help                Show this help
#
# Environment:
#   VALHALLA_ENV              local | dev | test | stage-us | prod-us (default: local)
#   VALHALLA_PIPELINE_CONFIG  Override pipeline config file path
#
# Exit codes:
#   0 Success | 1 Config/dep error | 2 OSM merge failed | 3 Tile build failed
#   4 Validation failed | 5 S3 sync failed | 6 Partial (tiles valid, S3 failed)
# =============================================================================

set -euo pipefail
trap '' PIPE

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
readonly SCRIPT_VERSION="1.0.0-us"
readonly SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
readonly PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Retry settings
readonly MAX_DOWNLOAD_RETRIES=3
readonly DOWNLOAD_RETRY_DELAY=30
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
RUN_ID=""
LOG_FILE=""

_log() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

    local json_line
    json_line="{\"ts\":\"${timestamp}\",\"level\":\"${level}\",\"run\":\"${RUN_ID:-init}\",\"region\":\"${REGION:-unknown}\",\"msg\":$(printf '%s' "${message}" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null || echo "\"${message}\"")}"

    if [[ -n "${LOG_FILE}" ]]; then
        echo "${json_line}" >> "${LOG_FILE}"
    fi

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
    echo -e "${BOLD}US Pipeline ${status} — Run: ${RUN_ID:-unknown}${NC}"
    echo -e "  Region:      ${REGION:-unknown}"
    echo -e "  Tile group:  ${TILE_GROUP:-none}"
    echo -e "  Environment: ${VALHALLA_ENV:-unknown}"
    echo -e "  Exit code:   ${exit_code}"
    echo -e "  Duration:    ${duration:-unknown}"
    echo -e "  Last phase:  ${PHASE_REACHED:-bootstrap}"
    [[ -n "${LOG_FILE}" ]] && echo -e "  Log file:    ${LOG_FILE}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    if [[ -n "${LOG_FILE}" ]]; then
        echo "{\"ts\":\"${end_time}\",\"level\":\"SUMMARY\",\"run\":\"${RUN_ID:-unknown}\",\"region\":\"${REGION:-unknown}\",\"group\":\"${TILE_GROUP:-}\",\"status\":\"${status}\",\"exit_code\":${exit_code},\"duration\":\"${duration}\",\"phase\":\"${PHASE_REACHED:-bootstrap}\"}" >> "${LOG_FILE}"
    fi

    if [[ -n "${NOTIFY_URL:-}" ]] && command -v curl &>/dev/null; then
        local payload
        payload="{\"run\":\"${RUN_ID:-unknown}\",\"region\":\"${REGION:-unknown}\",\"group\":\"${TILE_GROUP:-}\",\"env\":\"${VALHALLA_ENV:-unknown}\",\"status\":\"${status}\",\"exit_code\":${exit_code},\"duration\":\"${duration}\"}"
        curl -s -X POST "${NOTIFY_URL}" \
            -H "Content-Type: application/json" \
            -d "${payload}" \
            --max-time 10 \
            --retry 2 || log_warn "Webhook notification failed"
    fi
}
trap on_exit EXIT

set_phase() {
    PHASE_REACHED="$1"
    log_phase "$1"
}

# ---------------------------------------------------------------------------
# Retry helper
# ---------------------------------------------------------------------------
retry() {
    local max_attempts="$1"
    local delay="$2"
    local description="$3"
    shift 3
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
# Phase 0: Bootstrap — load config, resolve tile group, validate deps
# ---------------------------------------------------------------------------
bootstrap() {
    PIPELINE_START_TIME="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    RUN_ID="$(date -u '+%Y%m%d-%H%M%S')"

    log_phase "Phase 0: Bootstrap (US)"
    log_info "Script version: ${SCRIPT_VERSION}"
    log_info "Run ID:         ${RUN_ID}"
    log_info "Region:         ${REGION}"
    log_info "Environment:    ${VALHALLA_ENV}"
    log_info "Dry run:        ${DRY_RUN}"

    _load_pipeline_config "${PIPELINE_CONFIG_FILE:-}"

    # Apply config-file values as defaults (CLI flags already set take precedence)
    VALHALLA_TILE_DIR="${VALHALLA_TILE_DIR:-${PROJECT_ROOT}/data/valhalla_tiles}"
    OSM_DIR="${OSM_DIR:-${PROJECT_ROOT}/data/osm}"
    VALHALLA_ADMIN_DIR="${VALHALLA_ADMIN_DIR:-${PROJECT_ROOT}/data/admin_data}"
    VALHALLA_LOG_DIR="${VALHALLA_LOG_DIR:-${PROJECT_ROOT}/logs}"
    SKIP_ELEVATION="${SKIP_ELEVATION:-false}"
    KEEP_VERSIONS="${KEEP_VERSIONS_ARG:-${KEEP_VERSIONS:-3}}"
    S3_TILE_BUCKET="${S3_TILE_BUCKET:-}"
    if [[ -n "${S3_TILE_BUCKET}" ]]; then
        S3_TILE_BUCKET="${S3_TILE_BUCKET%/}"
        [[ "${S3_TILE_BUCKET}" != s3://* ]] && S3_TILE_BUCKET="s3://${S3_TILE_BUCKET}"
    fi
    # US cluster default S3 region (override in pipeline.*-us.conf).
    S3_REGION="${S3_REGION:-us-east-1}"
    VALHALLA_BUILD_TILES_BIN="${VALHALLA_BUILD_TILES_BIN:-}"
    VALHALLA_DOCKER_IMAGE="${VALHALLA_DOCKER_IMAGE:-ghcr.io/valhalla/valhalla:latest}"

    VERSION_TAG="${RUN_ID}"

    mkdir -p "${VALHALLA_LOG_DIR}"
    LOG_FILE="${VALHALLA_LOG_DIR}/pipeline-us-${REGION}-${RUN_ID}.log"
    log_info "Log file: ${LOG_FILE}"
    echo "{\"ts\":\"${PIPELINE_START_TIME}\",\"level\":\"START\",\"run\":\"${RUN_ID}\",\"region\":\"${REGION}\",\"env\":\"${VALHALLA_ENV}\",\"version\":\"${SCRIPT_VERSION}\"}" >> "${LOG_FILE}"

    # Validate region exists
    local regions_config="${PROJECT_ROOT}/config/regions/regions.json"
    if ! jq -e ".regions.${REGION}" "${regions_config}" > /dev/null 2>&1; then
        log_error "Region '${REGION}' not found in ${regions_config}"
        log_info "Available regions:"
        jq -r '.regions | to_entries[] | "  \(.key) (\(if .value.enabled then "enabled" else "disabled" end))"' "${regions_config}"
        exit 1
    fi

    # -----------------------------------------------------------------------
    # Resolve tile layout. US regions normally belong to a tile_group (shared,
    # multi-source-merged tiles). A US region with its own tile_dir / osm_source
    # (single-state) is also supported as a fallback.
    # -----------------------------------------------------------------------
    TILE_GROUP="$(jq -r ".regions.${REGION}.tile_group // empty" "${regions_config}")"
    if [[ -n "${TILE_GROUP}" ]]; then
        IS_GROUP=true
        TILE_SUBDIR="$(jq -r ".tile_groups.${TILE_GROUP}.tile_dir" "${regions_config}")"
        if [[ -z "${TILE_SUBDIR}" || "${TILE_SUBDIR}" == "null" ]]; then
            log_error "Region '${REGION}' references tile_group '${TILE_GROUP}' but it has no tile_dir under tile_groups"
            exit 1
        fi
        local group_osm_file
        group_osm_file="$(jq -r ".tile_groups.${TILE_GROUP}.osm_file // empty" "${regions_config}")"
        OSM_FILE="${OSM_DIR}/${group_osm_file:-${TILE_GROUP}-latest.osm.pbf}"
        OSM_SOURCE=""
        log_info "Tile group:     ${TILE_GROUP} (shared tiles; OSM merged from sources)"
    else
        IS_GROUP=false
        TILE_SUBDIR="$(jq -r ".regions.${REGION}.tile_dir" "${regions_config}")"
        OSM_SOURCE="$(jq -r ".regions.${REGION}.osm_source" "${regions_config}")"
        local region_osm_file
        region_osm_file="$(jq -r ".regions.${REGION}.osm_file // empty" "${regions_config}")"
        OSM_FILE="${OSM_DIR}/${region_osm_file:-${REGION}-latest.osm.pbf}"
        log_info "OSM source:     ${OSM_SOURCE}"
    fi

    # Tile dirs are named after the SUBDIR (group or region) — all regions in a
    # group share one physical tile dir + extract.
    VERSIONED_TILE_DIR="${VALHALLA_TILE_DIR}/${TILE_SUBDIR}/v${VERSION_TAG}"
    LATEST_LINK="${VALHALLA_TILE_DIR}/${TILE_SUBDIR}/latest"

    log_info "OSM file:       ${OSM_FILE}"
    log_info "Tile base dir:  ${VALHALLA_TILE_DIR}/${TILE_SUBDIR}"
    log_info "This version:   v${VERSION_TAG}"
    log_info "Keep versions:  ${KEEP_VERSIONS}"
    log_info "S3 region:      ${S3_REGION}"

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

    # Dry-run never downloads, merges, or builds — don't gate it on build tools
    # (osmium / docker / valhalla_build_tiles) that the host may not have.
    if [[ "${DRY_RUN}" == true ]]; then
        USE_DOCKER=false
        command -v jq &>/dev/null || { log_error "Missing required dependency: jq"; exit 1; }
        log_info "Dry-run — skipping build-tool dependency checks"
        return 0
    fi

    local missing=()

    command -v jq   &>/dev/null || missing+=("jq")
    command -v wget &>/dev/null || missing+=("wget")
    # osmium is only required for the multi-source merge (group regions).
    if [[ "${IS_GROUP}" == true ]]; then
        command -v osmium &>/dev/null || missing+=("osmium-tool")
    fi

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
# Phase 1: OSM Acquire — merge group sources (or single-state download)
# ---------------------------------------------------------------------------
phase_osm() {
    set_phase "Phase 1: OSM Acquire / Merge"

    mkdir -p "${OSM_DIR}"

    if [[ "${IS_GROUP}" == true ]]; then
        _acquire_group_osm
        return $?
    fi

    # Single-state US region: plain download (cache-aware), mirrors the SG flow.
    if [[ -f "${OSM_FILE}" ]] && [[ "${FORCE_DOWNLOAD}" == false ]]; then
        local file_mtime now_epoch file_age_days
        file_mtime="$(stat -c %Y "${OSM_FILE}" 2>/dev/null || stat -f %m "${OSM_FILE}" 2>/dev/null || echo 0)"
        now_epoch="$(date +%s)"
        file_age_days=$(( (now_epoch - file_mtime) / 86400 ))
        log_info "OSM file exists. Age: ${file_age_days}d. Max age: ${OSM_MAX_AGE_DAYS}d."
        if [[ ${file_age_days} -lt ${OSM_MAX_AGE_DAYS} ]]; then
            log_ok "OSM file is fresh ($(du -sh "${OSM_FILE}" | cut -f1)). Skipping download."
            return 0
        fi
        log_info "OSM file is stale — re-downloading."
    fi

    if [[ "${DRY_RUN}" == true ]]; then
        log_dry "Would download: ${OSM_SOURCE} → ${OSM_FILE}"
        return 0
    fi

    retry "${MAX_DOWNLOAD_RETRIES}" "${DOWNLOAD_RETRY_DELAY}" "OSM download" -- _download_osm
    log_ok "OSM phase complete"
}

# Merge the tile group's osm_sources[] via merge-osm.sh (single source of truth
# for download + osmium merge). Honors --force-download.
_acquire_group_osm() {
    local merge_script="${PROJECT_ROOT}/scripts/regions/merge-osm.sh"
    if [[ ! -f "${merge_script}" ]]; then
        log_error "Group region requires ${merge_script} (not found)"
        return 2
    fi

    local merge_args=("${TILE_GROUP}" --osm-dir "${OSM_DIR}" --config "${PROJECT_ROOT}/config/regions/regions.json")
    [[ "${FORCE_DOWNLOAD}" == true ]] && merge_args+=(--force)

    if [[ "${DRY_RUN}" == true ]]; then
        log_dry "Would merge OSM for group '${TILE_GROUP}': bash ${merge_script} ${merge_args[*]} → ${OSM_FILE}"
        return 0
    fi

    log_info "Merging OSM sources for group '${TILE_GROUP}' → ${OSM_FILE}"
    bash "${merge_script}" "${merge_args[@]}" 2>&1 | tee -a "${LOG_FILE}" | _log_stream "MERGE"
    local merge_exit=${PIPESTATUS[0]:-$?}
    if [[ ${merge_exit} -ne 0 ]]; then
        log_error "OSM merge failed (exit ${merge_exit})"
        return 2
    fi
    if [[ ! -f "${OSM_FILE}" ]]; then
        log_error "Merge reported success but ${OSM_FILE} is missing"
        return 2
    fi
    log_ok "OSM phase complete (merged: $(du -sh "${OSM_FILE}" | cut -f1))"
}

_download_osm() {
    local tmp_file="${OSM_FILE}.download.tmp"
    local md5_url="${OSM_SOURCE}.md5"
    local md5_file="${OSM_FILE}.md5"

    log_info "Downloading from: ${OSM_SOURCE}"
    if ! wget --spider --quiet --timeout=10 "${OSM_SOURCE}"; then
        log_error "Cannot reach ${OSM_SOURCE} — check network connectivity"
        return 1
    fi

    if ! wget --progress=dot:giga --continue --tries=1 --timeout=120 --read-timeout=60 \
        -O "${tmp_file}" "${OSM_SOURCE}" 2>&1 | tee -a "${LOG_FILE}"; then
        rm -f "${tmp_file}"
        log_error "Download failed"
        return 1
    fi

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

    mv "${tmp_file}" "${OSM_FILE}"
    log_ok "OSM downloaded: ${OSM_FILE} ($(du -sh "${OSM_FILE}" | cut -f1))"
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

    # Build config template: prefer the region-named template, fall back to the
    # tile group's name (e.g. valhalla-new_york.json serves the nyc_tri_state
    # group), then any available template.
    local config_template="${PROJECT_ROOT}/config/regions/${REGION}/valhalla-${REGION}.json"
    if [[ ! -f "${config_template}" && -n "${TILE_GROUP}" ]]; then
        # Try a template living under any region that maps to this group.
        local group_template
        group_template="$(find "${PROJECT_ROOT}/config/regions" -name "valhalla-*.json" \
            -exec grep -l "${TILE_SUBDIR}" {} \; 2>/dev/null | head -1)"
        [[ -n "${group_template}" ]] && config_template="${group_template}"
    fi
    if [[ ! -f "${config_template}" ]]; then
        config_template="$(find "${PROJECT_ROOT}/config/regions" -name "valhalla-*.json" | head -1)"
    fi
    if [[ -z "${config_template}" || ! -f "${config_template}" ]]; then
        log_error "No Valhalla config template found"
        exit 3
    fi
    log_info "Build template: ${config_template}"

    local build_config="${VALHALLA_LOG_DIR}/valhalla-build-${TILE_SUBDIR}-${RUN_ID}.json"
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
    local build_log="${VALHALLA_LOG_DIR}/tile-build-${TILE_SUBDIR}-${RUN_ID}.log"

    log_info "Starting tile build → ${VERSIONED_TILE_DIR}"
    log_info "Build log: ${build_log}"

    local start_epoch
    start_epoch="$(date +%s)"

    if [[ "${USE_DOCKER}" == true ]]; then
        _run_docker_command "${build_config}" "valhalla_build_tiles" "${build_log}"
    else
        valhalla_build_tiles -c "${build_config}" "${OSM_FILE}" 2>&1 | tee -a "${build_log}" | _log_stream "BUILD"
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

    log_ok "Tiles built: ${tile_count} files, $(du -sh "${VERSIONED_TILE_DIR}" | cut -f1)"
}

_run_admin_build() {
    local build_config="$1"
    local admin_log="${VALHALLA_LOG_DIR}/admin-build-${TILE_SUBDIR}-${RUN_ID}.log"

    if [[ "${USE_DOCKER}" == true ]]; then
        _run_docker_command "${build_config}" "valhalla_build_admins" "${admin_log}"
    elif command -v valhalla_build_admins &>/dev/null; then
        valhalla_build_admins -c "${build_config}" "${OSM_FILE}" 2>&1 | tee -a "${admin_log}" | _log_stream "ADMIN"
    else
        log_warn "valhalla_build_admins not available — skipping"
        return 0
    fi
}

_run_docker_command() {
    local build_config="$1"
    local command="$2"
    local log_file="$3"

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
        "/valhalla/osm/$(basename "${OSM_FILE}")" \
        2>&1 | tee -a "${log_file}" | _log_stream "${command}"

    local exit_code=${PIPESTATUS[0]:-$?}
    rm -f "${docker_config}"
    return ${exit_code}
}

_log_stream() {
    local tag="$1"
    while IFS= read -r line; do
        echo -e "${CYAN}  [${tag}]${NC} ${line}"
    done
}

# ---------------------------------------------------------------------------
# Phase 3.5: Build tile extract (.tar with embedded index.bin)
# The tar is named after the tile SUBDIR so RegionConfigFactory resolves it at
# <subdir>/latest/<subdir>.tar (shared by all regions in the group).
# ---------------------------------------------------------------------------
phase_extract() {
    set_phase "Phase 3.5: Build Tile Extract"

    TILE_EXTRACT="${VERSIONED_TILE_DIR}/${TILE_SUBDIR}.tar"

    if [[ "${BUILD_EXTRACT}" == false ]]; then
        log_info "Tile extract disabled (--no-extract) — skipping"
        TILE_EXTRACT=""
        return 0
    fi

    if [[ "${DRY_RUN}" == true ]]; then
        log_dry "Would build tile extract: ${VERSIONED_TILE_DIR} → ${TILE_EXTRACT}"
        return 0
    fi

    local extract_log="${VALHALLA_LOG_DIR}/extract-${TILE_SUBDIR}-${RUN_ID}.log"
    log_info "Building tile extract → ${TILE_EXTRACT}"
    log_info "Extract log: ${extract_log}"

    if [[ "${USE_DOCKER}" == true ]]; then
        docker run --rm \
            -v "${VERSIONED_TILE_DIR}:/valhalla/tiles" \
            "${VALHALLA_DOCKER_IMAGE}" \
            valhalla_build_extract \
            --inline-config "{\"mjolnir\":{\"tile_dir\":\"/valhalla/tiles\",\"tile_extract\":\"/valhalla/tiles/${TILE_SUBDIR}.tar\"}}" \
            --overwrite -v \
            2>&1 | tee -a "${extract_log}" | _log_stream "EXTRACT"
        local extract_exit=${PIPESTATUS[0]:-$?}
    else
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

    # Read only the first tar member. `tar tf | head -1` is unsafe here: head
    # closes the pipe after one line, tar keeps writing and hits EPIPE; since
    # `trap '' PIPE` ignores SIGPIPE, tar exits 2, and `set -o pipefail` + the
    # command substitution would abort the whole script (exit 2) BEFORE this
    # check runs — even on a perfectly valid extract. `|| true` swallows tar's
    # EPIPE exit inside the subshell; the index.bin comparison is the real check.
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

    if [[ -d "${VERSIONED_TILE_DIR}" ]]; then
        log_ok "Tile directory exists"
    else
        log_error "Tile directory missing: ${VERSIONED_TILE_DIR}"
        (( errors++ ))
    fi

    local tile_count
    tile_count="$(find "${VERSIONED_TILE_DIR}" -name "*.gph" 2>/dev/null | wc -l)"
    if [[ ${tile_count} -gt 0 ]]; then
        log_ok "Tile count: ${tile_count}"
    else
        log_error "No .gph tile files found"
        (( errors++ ))
    fi

    local tile_mb
    tile_mb="$(du -sm "${VERSIONED_TILE_DIR}" 2>/dev/null | cut -f1)"
    if [[ ${tile_mb} -gt 10 ]]; then
        log_ok "Tile size: $(du -sh "${VERSIONED_TILE_DIR}" | cut -f1)"
    else
        log_error "Tiles too small: ${tile_mb} MB (expected > 10 MB)"
        (( errors++ ))
    fi

    local level_count
    level_count="$(find "${VERSIONED_TILE_DIR}" -maxdepth 1 -type d -name "[0-9]" | wc -l)"
    if [[ ${level_count} -gt 0 ]]; then
        log_ok "Tile hierarchy: ${level_count} level directories"
    else
        log_warn "No level directories found (0/, 1/, 2/)"
    fi

    if [[ -f "${VALHALLA_ADMIN_DIR}/admins.sqlite" ]]; then
        log_ok "Admin DB: $(du -sh "${VALHALLA_ADMIN_DIR}/admins.sqlite" | cut -f1)"
    else
        log_warn "Admin DB not found (non-critical)"
    fi

    local sample
    sample="$(find "${VERSIONED_TILE_DIR}" -name "*.gph" -print -quit)"
    if [[ -n "${sample}" && -r "${sample}" ]]; then
        log_ok "Sample tile readable: $(basename "${sample}")"
    else
        log_error "Sample tile not readable"
        (( errors++ ))
    fi

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
# Phase 5: S3 Sync — US bucket (keyed by tile SUBDIR so the group has one path)
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
        log_dry "Would sync: ${VERSIONED_TILE_DIR} → ${S3_TILE_BUCKET}/${TILE_SUBDIR}/v${VERSION_TAG}/ (region ${S3_REGION})"
        return 0
    fi

    local s3_versioned="${S3_TILE_BUCKET}/${TILE_SUBDIR}/v${VERSION_TAG}"

    log_info "Uploading tiles to: ${s3_versioned}"
    if ! aws s3 sync "${VERSIONED_TILE_DIR}/" "${s3_versioned}/" \
        --region "${S3_REGION}" --no-progress \
        2>&1 | tee -a "${LOG_FILE}" | _log_stream "S3"; then
        log_error "S3 upload failed"
        exit 5
    fi
    log_ok "S3 upload complete: ${s3_versioned}"

    echo "v${VERSION_TAG}" | aws s3 cp - "${S3_TILE_BUCKET}/${TILE_SUBDIR}/latest.txt" \
        --region "${S3_REGION}" --content-type "text/plain" \
        2>&1 || log_warn "Failed to update S3 latest pointer"

    log_ok "S3 latest pointer updated: v${VERSION_TAG}"
}

# ---------------------------------------------------------------------------
# Phase 6: Swap Latest (atomic symlink)
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

    ln -sfn "v${VERSION_TAG}" "${LATEST_LINK}"
    log_ok "Latest symlink updated: ${LATEST_LINK} → v${VERSION_TAG}"

    if [[ -n "${previous_version}" ]]; then
        log_info "Rollback available: ln -sfn ${previous_version} ${LATEST_LINK}"
    fi
}

# ---------------------------------------------------------------------------
# Geometry Mapping (optional for US — disabled by default)
# ---------------------------------------------------------------------------
# The SG GeometryMappingJob resolves LTA speed-band linkIds; it is SG-specific.
# US regions do not have an LTA feed, so this phase is skipped by default.
# Pass --with-geometry-mapping to force it (e.g. if a US traffic provider is
# wired up later). Keyed on TILE_SUBDIR so a group shares one cache.
# ---------------------------------------------------------------------------
geometry_mapping() {
    set_phase "Geometry Mapping"

    if [[ "${SKIP_GEOMETRY_MAPPING}" == true ]]; then
        log_info "Skipping geometry mapping (default for US; use --with-geometry-mapping to enable)"
        return 0
    fi

    if [[ "${DRY_RUN}" == true ]]; then
        log_dry "Would invoke GeometryMappingJob against ${LATEST_LINK}"
        return 0
    fi

    local jar=""
    if [[ -f "/app/valhalla-jni.jar" ]]; then
        jar="/app/valhalla-jni.jar"
    else
        jar="$(ls "${PROJECT_ROOT}/src/bindings/java/build/libs/valhalla-jni-"*.jar 2>/dev/null \
            | grep -v sources | grep -v javadoc | head -1)"
    fi

    if [[ -z "${jar}" || ! -f "${jar}" ]]; then
        log_error "valhalla-jni JAR not found (checked /app/valhalla-jni.jar and ${PROJECT_ROOT}/src/bindings/java/build/libs/)"
        return 2
    fi

    log_info "Using JAR: ${jar}"
    log_info "Tile dir:  $(readlink -f "${LATEST_LINK}")"

    local cache_dir="${VALHALLA_TILE_DIR}/${TILE_SUBDIR}/cache"
    mkdir -p "${cache_dir}"

    local job_exit_code=0
    VALHALLA_TILE_DIR="${LATEST_LINK}" \
    GEOMETRY_MAPPING_CACHE_PATH="${cache_dir}/geometry_mapping.json" \
    GEOMETRY_MAPPING_REPORT_PATH="${cache_dir}/geometry_mapping_report.txt" \
    GEOMETRY_MAPPING_JSON_REPORT_PATH="${cache_dir}/geometry_mapping_report.json" \
        java -cp "${jar}:/app/lib/*" global.tada.valhalla.traffic.sg.GeometryMappingJob \
        || job_exit_code=$?

    case "${job_exit_code}" in
        0) log_ok "Geometry mapping completed (acceptance criteria met)" ;;
        1) log_warn "Geometry mapping below acceptance threshold (job exit 1) — pipeline continues" ;;
        *) log_error "Geometry mapping failed (job exit ${job_exit_code})"; return 2 ;;
    esac

    return 0
}

# ---------------------------------------------------------------------------
# Phase 7: Cleanup old versions
# ---------------------------------------------------------------------------
phase_cleanup() {
    set_phase "Phase 7: Cleanup Old Versions"

    local tile_base="${VALHALLA_TILE_DIR}/${TILE_SUBDIR}"
    local versions
    mapfile -t versions < <(find "${tile_base}" -maxdepth 1 -type d -name "v[0-9]*" | sort)

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

US-cluster tile pipeline. <region> is any US region key in regions.json. The
on-disk tile layout is resolved from the config automatically:
  • Grouped region (has "tile_group") → shared tiles under the group's tile_dir,
    OSM merged from the group's sources. E.g. new_york/new_jersey/connecticut
    → nyc_tri_state (routing crosses state lines).
  • Single region (has its own "tile_dir" + "osm_source", no group) → tiles
    under that tile_dir, single-source OSM. Same shape as Singapore.
Adding a new region is a regions.json edit only — no change to this script.

Options:
  --pipeline-config <path>  Path to pipeline .conf file
  --force-download          Re-download + re-merge OSM even if fresh
  --osm-max-age-days <n>    Max OSM age before re-acquire (default: 6)
  --no-elevation            Skip elevation data
  --skip-build              Skip OSM + tile build; operate on existing 'latest'
  --skip-geometry-mapping   Skip geometry-mapping (default for US)
  --with-geometry-mapping   Force-run geometry-mapping
  --no-extract              Skip building the .tar tile extract (index.bin)
  --keep-versions <n>       Old tile versions to retain (default: 3)
  --dry-run                 Print actions without executing
  --notify-url <url>        POST webhook on completion/failure
  -h, --help                Show this help

Environments (VALHALLA_ENV):
  local      pipeline.local.conf  + binary/Docker (no S3)
  stage-us   pipeline.stage-us.conf + Docker + US S3
  prod-us    pipeline.prod-us.conf  + Docker + US S3 + elevation

Examples:
  # Grouped region — build the tri-state group via any member region key
  ./run-tile-pipeline-us.sh new_york --no-elevation     # → tiles under nyc_tri_state/

  # Single region — Singapore-style, tiles under its own tile_dir
  ./run-tile-pipeline-us.sh florida --no-elevation      # → tiles under florida/

  # Production US — uses pipeline.prod-us.conf automatically
  VALHALLA_ENV=prod-us ./run-tile-pipeline-us.sh new_york

  # Dry-run (verify a newly-added region resolves correctly before a real build)
  VALHALLA_ENV=prod-us ./run-tile-pipeline-us.sh new_york --dry-run

  # Cron (every Tuesday 07:00 UTC = 02:00 US Eastern wall-ish):
  # 0 7 * * 1 cd /opt/valhalla && VALHALLA_ENV=prod-us ./deploy/scripts/run-tile-pipeline-us.sh new_york >> /var/log/valhalla/cron-us.log 2>&1

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

    # Help requested as the first arg — show usage before treating it as a region.
    if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        show_usage
        exit 0
    fi

    REGION="$1"
    shift

    # Defaults
    VALHALLA_ENV="${VALHALLA_ENV:-local}"
    PIPELINE_CONFIG_FILE=""
    FORCE_DOWNLOAD=false
    OSM_MAX_AGE_DAYS=6
    DRY_RUN=false
    SKIP_BUILD=false
    # US: geometry mapping is SG-specific (LTA), so default to skipping it.
    SKIP_GEOMETRY_MAPPING=true
    BUILD_EXTRACT=true
    TILE_EXTRACT=""
    KEEP_VERSIONS_ARG=""
    NOTIFY_URL="${NOTIFY_URL:-}"
    SKIP_ELEVATION_ARG=""
    # Tile-layout vars resolved in bootstrap (initialized for set -u safety).
    IS_GROUP=false
    TILE_GROUP=""
    TILE_SUBDIR=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --pipeline-config)        PIPELINE_CONFIG_FILE="$2"; shift 2 ;;
            --force-download)         FORCE_DOWNLOAD=true;        shift   ;;
            --osm-max-age-days)       OSM_MAX_AGE_DAYS="$2";     shift 2 ;;
            --no-elevation)           SKIP_ELEVATION_ARG=true;   shift   ;;
            --skip-build)             SKIP_BUILD=true;            shift   ;;
            --skip-geometry-mapping)  SKIP_GEOMETRY_MAPPING=true; shift   ;;
            --with-geometry-mapping)  SKIP_GEOMETRY_MAPPING=false; shift  ;;
            --no-extract)             BUILD_EXTRACT=false;        shift   ;;
            --keep-versions)          KEEP_VERSIONS_ARG="$2";    shift 2 ;;
            --dry-run)                DRY_RUN=true;               shift   ;;
            --notify-url)             NOTIFY_URL="$2";            shift 2 ;;
            -h|--help)                show_usage; exit 0 ;;
            *) log_error "Unknown option: $1"; show_usage; exit 1 ;;
        esac
    done

    [[ -n "${SKIP_ELEVATION_ARG}" ]] && SKIP_ELEVATION=true

    bootstrap
    if [[ "${SKIP_BUILD}" == true ]]; then
        local existing_latest="${LATEST_LINK}"
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
    phase_s3_sync
    phase_swap_latest
    phase_cleanup
    geometry_mapping

    log_ok "US pipeline completed successfully — v${VERSION_TAG}"
    exit ${PIPELINE_EXIT_CODE}
}

main "$@"
