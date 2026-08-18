#!/bin/bash
# =============================================================================
# Valhalla Tile Pipeline — Shared Core Library
# =============================================================================
# Sourced by the per-region pipeline scripts (run-tile-pipeline.sh,
# run-tile-pipeline-us.sh). NOT executable on its own.
#
# This library holds every phase and helper that is common across regions. The
# only things a pipeline script provides are:
#   • a region CONFIG block (defaults + labels), set BEFORE run_pipeline
#   • an ordered PHASES[] array (the execution order) and BUILD_PHASES[]
#     (the subset skipped by --skip-build)
#   • region-specific function definitions/overrides:
#       - resolve_tile_layout   (hook: resolve TILE_SUBDIR/OSM_* from regions.json)
#       - phase_osm             (SG: plain download; US: overridden for groups)
#       - geometry_mapping      (region-specific — LTA/EFS vs local cache)
#       - parse_extra_flag      (optional hook for region-only CLI flags)
#       - any *_acquire_* / phase_block_ways helpers a region needs
#
# Tiles are always addressed on disk by ${TILE_SUBDIR} (a pipeline script sets this in
# resolve_tile_layout — for a single region it equals ${REGION}; for a grouped
# region it is the shared group dir). The lib never hardcodes ${REGION} into a
# tile path.
# =============================================================================

# shellcheck shell=bash
# shellcheck disable=SC2154   # region config vars are set by the sourcing script

# ---------------------------------------------------------------------------
# Idempotent source guard.
# ---------------------------------------------------------------------------
# Everything below declares `readonly` constants. Under `set -e`, re-sourcing
# this file would abort the caller on the first re-assignment to a readonly var
# ("LIB_VERSION: readonly variable"). Today each pipeline script sources it
# exactly once, but a future helper, a test harness, or a pipeline script that
# sources another would trip it — a failure mode with a confusing message and no
# obvious cause.
# Returning early makes a second source a harmless no-op. `return` is valid here
# because this file is only ever sourced, never executed.
# ---------------------------------------------------------------------------
if [[ -n "${LIB_VERSION:-}" ]]; then
    return 0
fi

# ---------------------------------------------------------------------------
# Library version — a pipeline script asserts EXPECTED_LIB_VERSION against this so a
# pipeline script and a stale/mismatched lib copy can never silently run together.
# ---------------------------------------------------------------------------
readonly LIB_VERSION="1.0.0"

# ---------------------------------------------------------------------------
# Retry settings
# ---------------------------------------------------------------------------
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
    if [[ "${image}" =~ /valhalla:(development|production|staging|test|prod-virginia|stage-virginia)$ ]]; then
        local bare_tag="${image##*:}"
        log_error "VALHALLA_DOCKER_IMAGE uses the BARE tag '${bare_tag}' (${image})."
        log_error "build-valhalla-image.yml only publishes '<branch>-latest' and '<branch>-<sha>'. A bare tag is orphaned/manual and may point at a DIFFERENT commit than the published JAR → SIGBUS in AutoCost::Allowed."
        log_error "Pin to the maintained tag, e.g. '${image}-latest' (the JAR is published from <branch>-latest), in pipeline.${VALHALLA_ENV}.conf."
        exit 1
    fi

    # A BARE ':latest' on our OWN registry. This slipped past the checks above
    # (it is not ghcr.io, and 'latest' is not in the env-tag list) yet is exactly
    # as dangerous: CI publishes ONLY '<branch>-latest' and '<branch>-<sha>', so
    # ':latest' is a manually-pushed floating tag that drifts from the JAR's
    # libvalhalla.so.3 independently → SIGBUS in AutoCost::Allowed.
    # Note '<branch>-latest' does NOT match: the pattern anchors on ':latest'.
    if [[ "${image}" == *"/valhalla:latest" ]]; then
        log_error "VALHALLA_DOCKER_IMAGE uses the floating tag ':latest' (${image})."
        log_error "build-valhalla-image.yml only publishes '<branch>-latest' and '<branch>-<sha>'. A bare ':latest' is manual/orphaned and can point at a DIFFERENT commit than the published JAR → SIGBUS in AutoCost::Allowed."
        log_error "Pin to a maintained tag, e.g. '${image%:latest}:master-latest', in pipeline.${VALHALLA_ENV}.conf."
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
    echo -e "${BOLD}${PIPELINE_LABEL:-Pipeline }${status} — Run: ${RUN_ID:-unknown}${NC}"
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

    # NOTIFY_URL is a Slack incoming-webhook URL (see argo-cd
    # cronjob-group-valhalla-tile-pipeline*.yaml) — Slack only accepts a JSON
    # body with a "text" field, so the message must be built as one string
    # rather than posting the free-form run/region/status fields directly
    # (that shape is silently rejected by Slack). Formatted as labeled
    # *Field:* lines (mrkdwn, Slack's default for the plain text field) to
    # match the convention used for webhook messages elsewhere in the org
    # (see tada-corporate-service SftpFileProcessor.buildSlackMessage,
    # tada-ride-service SlackService) rather than one flat sentence.
    if [[ -n "${NOTIFY_URL:-}" ]] && command -v curl &>/dev/null; then
        local emoji="✅"
        [[ "${status}" != "SUCCESS" ]] && emoji="❌"
        local text="${emoji} *Valhalla ${PIPELINE_LABEL:-Pipeline }${status}*\n"
        text+="*Region:* ${REGION:-unknown}\n"
        text+="*Group:* ${TILE_GROUP:-none}\n"
        text+="*Env:* ${VALHALLA_ENV:-unknown}\n"
        text+="*Run:* ${RUN_ID:-unknown}\n"
        text+="*Exit code:* ${exit_code}\n"
        text+="*Duration:* ${duration:-unknown}\n"
        text+="*Last phase:* ${PHASE_REACHED:-bootstrap}"
        local payload
        payload="{\"text\":\"${text}\"}"
        curl -s -X POST "${NOTIFY_URL}" \
            -H "Content-Type: application/json" \
            -d "${payload}" \
            --max-time 10 \
            --retry 2 || log_warn "Webhook notification failed"
    fi

    # DogStatsD event (DHL-29015) — mirrors the Slack webhook above: same
    # choke point, same fire-and-forget tolerance for failure. Unlike the
    # webhook, this needs no URL/credential — the org runs Datadog in socket
    # mode (DD_DOGSTATSD_URL=unix:///var/run/datadog/dsd.socket, confirmed by
    # infra), and the local agent forwards the event using its own identity.
    # A Unix datagram socket can't be reached via bash's /dev/udp (that's
    # UDP-only) or by any tool on PATH in this image (no socat/nc — see
    # Dockerfile.tilebuilder's runtime package list); python3 IS already on
    # PATH for valhalla_build_extract/valhalla_build_elevation, and its stdlib
    # socket module supports AF_UNIX+SOCK_DGRAM with no extra dependency, so
    # it's the smallest correct option here, not the general-purpose choice.
    # The event payload is passed via env var, not interpolated into the
    # Python source, so its content can't break out of the script.
    if [[ -n "${DD_DOGSTATSD_URL:-}" ]]; then
        local dd_socket_path="${DD_DOGSTATSD_URL#unix://}"
        local alert_type="success"
        [[ "${status}" != "SUCCESS" ]] && alert_type="error"
        local dd_title="Valhalla ${PIPELINE_LABEL:-Pipeline }${status}"
        local dd_text="region:${REGION:-unknown} group:${TILE_GROUP:-none} env:${VALHALLA_ENV:-unknown} run:${RUN_ID:-unknown} exit_code:${exit_code} duration:${duration:-unknown} phase:${PHASE_REACHED:-bootstrap}"
        DD_EVENT="_e{${#dd_title},${#dd_text}}:${dd_title}|${dd_text}|t:${alert_type}|#env:${VALHALLA_ENV:-unknown},tile_region:${REGION:-unknown},pipeline:valhalla-tile" \
        DD_SOCKET_PATH="${dd_socket_path}" \
        timeout 2 python3 -c '
import os, socket
sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
sock.sendto(os.environ["DD_EVENT"].encode(), os.environ["DD_SOCKET_PATH"])
' 2>/dev/null || log_warn "Datadog event notification failed"
    fi
}

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
# Region-shaped values are driven by config vars the pipeline script sets before calling
# run_pipeline:
#   REGION_LABEL            e.g. "" (SG) or " (US)" — appended to "Bootstrap"
#   LOG_PREFIX              e.g. "pipeline" (SG) or "pipeline-us" (US)
#   DEFAULT_S3_REGION       e.g. "ap-southeast-1" (SG) or "us-east-1" (US)
# Tile-layout resolution is delegated to the pipeline script's resolve_tile_layout hook,
# which must set: TILE_SUBDIR, OSM_FILE, and (if applicable) OSM_SOURCE /
# TILE_GROUP / IS_GROUP. bootstrap then derives the versioned dirs from
# TILE_SUBDIR.
# ---------------------------------------------------------------------------
bootstrap() {
    PIPELINE_START_TIME="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    RUN_ID="$(date -u '+%Y%m%d-%H%M%S')"

    log_phase "Phase 0: Bootstrap${REGION_LABEL}"
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
    S3_REGION="${S3_REGION:-${DEFAULT_S3_REGION}}"
    VALHALLA_BUILD_TILES_BIN="${VALHALLA_BUILD_TILES_BIN:-}"
    # NO floating-upstream fallback. The tile builder MUST be a binary/image built
    # from THIS repo so the tile layout matches the libvalhalla.so.3 in the JNI
    # JAR; a version skew causes SIGBUS in costing (AutoCost::Allowed) on every
    # route. Leave blank only if a from-source valhalla_build_tiles is on PATH or
    # VALHALLA_BUILD_TILES_BIN is set.
    VALHALLA_DOCKER_IMAGE="${VALHALLA_DOCKER_IMAGE:-}"
    _reject_unsafe_docker_image "${VALHALLA_DOCKER_IMAGE}"

    VERSION_TAG="${RUN_ID}"

    mkdir -p "${VALHALLA_LOG_DIR}"
    # LOG_FILE keys on ${REGION} (not TILE_SUBDIR) and is set BEFORE region
    # validation — matching both original scripts exactly. This preserves the
    # per-region log filename and ensures even a bad-region run still opens a
    # log file / START entry.
    LOG_FILE="${VALHALLA_LOG_DIR}/${LOG_PREFIX}-${REGION}-${RUN_ID}.log"
    log_info "Log file: ${LOG_FILE}"
    echo "{\"ts\":\"${PIPELINE_START_TIME}\",\"level\":\"START\",\"run\":\"${RUN_ID}\",\"region\":\"${REGION}\",\"env\":\"${VALHALLA_ENV}\",\"version\":\"${SCRIPT_VERSION}\"}" >> "${LOG_FILE}"

    # Validate region exists in regions.json
    local regions_config="${PROJECT_ROOT}/config/regions/regions.json"
    if ! jq -e ".regions.${REGION}" "${regions_config}" > /dev/null 2>&1; then
        log_error "Region '${REGION}' not found in ${regions_config}"
        log_info "Available regions:"
        jq -r '.regions | to_entries[] | "  \(.key) (\(if .value.enabled then "enabled" else "disabled" end))"' "${regions_config}"
        exit 1
    fi

    # Resolve tile layout (TILE_SUBDIR, OSM_FILE, OSM_SOURCE/TILE_GROUP/IS_GROUP).
    # Pipeline-script-provided so grouped (US) vs single-region (SG) layouts stay isolated.
    resolve_tile_layout

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
    _preflight_s3

    log_ok "Bootstrap complete"
}

# ---------------------------------------------------------------------------
# S3 preflight — fail fast, BEFORE the multi-hour build
# ---------------------------------------------------------------------------
# phase_s3_sync runs at the very END of the pipeline. Without this check, a
# misconfigured bucket / wrong region / missing IAM permission is discovered
# only after the whole build has completed — the run dies at exit 5 having
# burned hours of compute. Worse, a BLANK S3_TILE_BUCKET makes phase_s3_sync
# return 0 silently, so a US prod run "succeeds" while archiving nothing.
#
# This asserts, at bootstrap time:
#   1. S3_TILE_BUCKET is non-empty in any non-local environment (blank is only
#      legitimate for local dev, where S3 is deliberately disabled).
#   2. The bucket is reachable and writable-by-identity from THIS cluster, in
#      the configured S3_REGION. head-bucket surfaces credential, region, and
#      existence failures as distinct exit statuses.
#
# Cross-cluster relevance: the US cluster carries its own bucket in us-east-1
# and its own instance role. This is the check that catches "US cron is running
# with SG credentials" or "prod-virginia.conf never got its bucket filled in".
#
# AWS_PROFILE / S3_ENDPOINT_URL are honoured if set, so a cluster can point at a
# non-default credential profile or an S3-compatible endpoint without the
# pipeline scripts needing to know.
# ---------------------------------------------------------------------------
_preflight_s3() {
    local env="${VALHALLA_ENV:-local}"

    if [[ -z "${S3_TILE_BUCKET}" ]]; then
        if [[ "${env}" == "local" ]]; then
            log_info "S3 preflight: S3_TILE_BUCKET blank — S3 archive disabled (local dev)"
            return 0
        fi
        log_error "S3_TILE_BUCKET is blank in environment '${env}'."
        log_error "A non-local run MUST archive to S3 — a blank bucket makes Phase 5 skip silently, so the build would 'succeed' having stored nothing."
        log_error "Set S3_TILE_BUCKET in deploy/config/pipeline.${env}.conf (US cluster: a us-east-1 bucket), or run with VALHALLA_ENV=local."
        exit 1
    fi

    log_info "S3 preflight:   ${S3_TILE_BUCKET} (region ${S3_REGION})"
    [[ -n "${AWS_PROFILE:-}" ]] && log_info "S3 profile:     ${AWS_PROFILE}"

    if [[ "${DRY_RUN}" == true ]]; then
        log_dry "Would verify bucket reachable: ${S3_TILE_BUCKET} (region ${S3_REGION})"
        return 0
    fi

    if ! command -v aws &>/dev/null; then
        # Not fatal: phase_s3_sync degrades to exit 6 (partial success) on a
        # missing CLI. Keep that contract rather than hard-failing here.
        log_warn "aws CLI not found — skipping S3 preflight; Phase 5 will report partial success (exit 6)"
        return 0
    fi

    # Strip the s3:// scheme and any key prefix — head-bucket takes a bare name.
    local bucket_name="${S3_TILE_BUCKET#s3://}"
    bucket_name="${bucket_name%%/*}"

    local head_err rc=0
    head_err="$(aws s3api head-bucket \
        --bucket "${bucket_name}" \
        --region "${S3_REGION}" \
        ${S3_ENDPOINT_URL:+--endpoint-url "${S3_ENDPOINT_URL}"} 2>&1)" || rc=$?

    if [[ ${rc} -ne 0 ]]; then
        log_error "S3 preflight FAILED for bucket '${bucket_name}' in region '${S3_REGION}' (aws exit ${rc})."
        log_error "aws: ${head_err}"
        log_error "Common causes: bucket does not exist; bucket lives in a DIFFERENT region than S3_REGION (the US cluster's bucket must be us-east-1); this host's IAM role lacks s3:ListBucket/PutObject; credentials are for the wrong account."
        log_error "Verify with: aws sts get-caller-identity && aws s3api head-bucket --bucket ${bucket_name} --region ${S3_REGION}"
        exit 1
    fi

    log_ok "S3 preflight passed: ${bucket_name} reachable in ${S3_REGION}"
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
    if [[ "${IS_GROUP:-false}" == true ]]; then
        command -v osmium &>/dev/null || missing+=("osmium-tool")
    fi

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

_download_osm() {
    local tmp_file="${OSM_FILE}.download.tmp"
    local md5_url="${OSM_SOURCE}.md5"
    local md5_file="${OSM_FILE}.md5"

    log_info "Downloading from: ${OSM_SOURCE}"

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
    local file_size
    file_size="$(du -sh "${OSM_FILE}" | cut -f1)"
    log_ok "OSM downloaded: ${OSM_FILE} (${file_size})"
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

# Pipe filter: prefix each line with a log tag for the console
_log_stream() {
    local tag="$1"
    while IFS= read -r line; do
        echo -e "${CYAN}  [${tag}]${NC} ${line}"
    done
}

# ---------------------------------------------------------------------------
# Resolve the JNI JAR — prefer the prod path baked into the Docker image,
# fall back to the local-dev gradle output. Shared by geometry_mapping and
# phase_validate's route smoke check, both of which run a Java class against
# the JNI-bundled Actor. (geometry_mapping still hardcodes /app/lib/* directly
# for its classpath since it's effectively prod-only; only the route smoke
# check uses _resolve_jni_runtime_classpath's local-dev fallback.)
# ---------------------------------------------------------------------------
_resolve_jni_jar() {
    if [[ -f "/app/valhalla-jni.jar" ]]; then
        echo "/app/valhalla-jni.jar"
        return 0
    fi

    # Filter out -sources.jar and -javadoc.jar — Gradle's java{} block
    # produces them via withSourcesJar()/withJavadocJar(); only the main
    # JAR has the compiled classes. Mirrors docker/Dockerfile.prod.
    local jar
    jar="$(ls "${PROJECT_ROOT}/src/bindings/java/build/libs/valhalla-jni-"*.jar 2>/dev/null \
        | grep -v sources | grep -v javadoc | head -1)"

    if [[ -z "${jar}" || ! -f "${jar}" ]]; then
        log_error "valhalla-jni JAR not found (checked /app/valhalla-jni.jar and ${PROJECT_ROOT}/src/bindings/java/build/libs/)"
        return 1
    fi

    echo "${jar}"
}

# ---------------------------------------------------------------------------
# Resolve the classpath entry for the JAR's transitive deps (SLF4J, Kotlin
# stdlib, org.json — the thin valhalla-jni-*.jar doesn't bundle them).
# Prod ships them at /app/lib/ (Dockerfile.prod). Local dev has no equivalent
# unless `./gradlew copyRuntimeDeps` was run manually into build/libs/runtime/.
# Echoes the classpath entry, or nothing if neither is present — callers must
# check for an empty result rather than treat "found a JAR" as "can run it".
# ---------------------------------------------------------------------------
_resolve_jni_runtime_classpath() {
    if [[ -d "/app/lib" ]]; then
        echo "/app/lib/*"
    elif [[ -d "${PROJECT_ROOT}/src/bindings/java/build/libs/runtime" ]]; then
        echo "${PROJECT_ROOT}/src/bindings/java/build/libs/runtime/*"
    fi
}

# ---------------------------------------------------------------------------
# Phase 2 & 3: Admin Build + Tile Build (admins must precede tiles)
# ---------------------------------------------------------------------------
# Elevation acquire is optional and region-provided: if the pipeline script defines an
# _acquire_elevation function it runs after the admin build (US); otherwise it
# is skipped (SG has no inline elevation download).
# ---------------------------------------------------------------------------
phase_build() {
    set_phase "Phase 2: Admin Build"

    if [[ "${DRY_RUN}" == true ]]; then
        if declare -F _acquire_elevation >/dev/null; then
            if [[ "${SKIP_ELEVATION}" == true ]]; then
                log_dry "Elevation disabled — would build tiles without grade data"
            else
                local _dry_bbox; _dry_bbox="$(_resolve_elevation_bbox)"
                if [[ -n "${_dry_bbox}" ]]; then
                    log_dry "Would download elevation tiles for bbox ${_dry_bbox} → ${VERSIONED_TILE_DIR}"
                else
                    log_dry "Elevation enabled but no bounds in regions.json for '${REGION}' — would build without grade data"
                fi
            fi
        fi
        log_dry "Would build tiles: ${OSM_FILE} → ${VERSIONED_TILE_DIR}"
        return 0
    fi

    mkdir -p "${VERSIONED_TILE_DIR}"
    mkdir -p "${VALHALLA_ADMIN_DIR}"

    # Build config template: prefer the region-named template, fall back to the
    # tile group's name (e.g. valhalla-new_york.json serves the nyc_tri_state
    # group), then any available template.
    local config_template="${PROJECT_ROOT}/config/regions/${REGION}/valhalla-${REGION}.json"
    if [[ ! -f "${config_template}" && -n "${TILE_GROUP:-}" ]]; then
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

    # Elevation tiles must exist BEFORE the tile build (region-provided step).
    # valhalla_build_tiles reads the Skadi .hgt(.gz) tiles from
    # additional_data.elevation (= VERSIONED_TILE_DIR, set in
    # _generate_build_config) during its Enhance stage to stamp per-edge grade.
    # The fresh versioned dir is empty, so without this download the build
    # silently produces tiles with NO elevation data. Non-critical: a failed
    # download only degrades grade-aware costing, so we warn and continue.
    if declare -F _acquire_elevation >/dev/null; then
        _acquire_elevation || log_warn "Elevation acquire failed (non-critical — tiles will build without grade data)"
    fi

    set_phase "Phase 3: Tile Build"
    retry "${MAX_BUILD_RETRIES}" "${BUILD_RETRY_DELAY}" "Tile build" -- \
        _run_tile_build "${build_config}"

    rm -f "${build_config}"
    log_ok "Build phase complete"
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
        errors=$(( errors + 1 ))
    fi

    local tile_count
    tile_count="$(find "${VERSIONED_TILE_DIR}" -name "*.gph" 2>/dev/null | wc -l)"
    if [[ ${tile_count} -gt 0 ]]; then
        log_ok "Tile count: ${tile_count}"
    else
        log_error "No .gph tile files found"
        errors=$(( errors + 1 ))
    fi

    local tile_mb
    tile_mb="$(du -sm "${VERSIONED_TILE_DIR}" 2>/dev/null | cut -f1)"
    if [[ ${tile_mb} -gt 10 ]]; then
        log_ok "Tile size: $(du -sh "${VERSIONED_TILE_DIR}" | cut -f1)"
    else
        log_error "Tiles too small: ${tile_mb} MB (expected > 10 MB)"
        errors=$(( errors + 1 ))
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
        errors=$(( errors + 1 ))
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
                errors=$(( errors + 1 ))
            fi
        else
            log_error "Tile extract missing: ${TILE_EXTRACT}"
            errors=$(( errors + 1 ))
        fi
    fi

    # Check 8: Sample route request — the only check that proves the tiles are
    # actually routable, not just present on disk. Must run against the
    # VERSIONED_TILE_DIR built THIS run, before phase_swap_latest/phase_s3_sync
    # promote it — unlike geometry_mapping, which intentionally runs after the
    # swap, a check meant to gate promotion would be too late there.
    if [[ "${SKIP_ROUTE_CHECK}" == true ]]; then
        log_info "Skipping route smoke check (--skip-route-check)"
    else
        local jar=""
        jar="$(_resolve_jni_jar 2>/dev/null)" || true
        local runtime_cp=""
        [[ -n "${jar}" ]] && runtime_cp="$(_resolve_jni_runtime_classpath)"

        if [[ -z "${jar}" || -z "${runtime_cp}" ]] || ! command -v java &>/dev/null; then
            # Local dev without a prod-style JAR + runtime deps layout (see
            # _resolve_jni_runtime_classpath), or an image without a JRE, can't
            # run this check at all — warn rather than fail so `VALHALLA_ENV=local`
            # and any non-JRE tile-builder image keep working without this check
            # blocking every run.
            log_warn "Route smoke check skipped — java and/or valhalla-jni JAR + runtime classpath not available (expected in the prod Docker image; local dev needs ./gradlew copyRuntimeDeps)"
        else
            local route_check_log="${VALHALLA_LOG_DIR}/route-check-${REGION}-${RUN_ID}.log"
            local route_check_exit=0
            if ! java -cp "${jar}:${runtime_cp}" global.tada.valhalla.validation.RouteSmokeCheckJob \
                "${REGION}" "${VERSIONED_TILE_DIR}" 2>&1 | tee -a "${route_check_log}" | _log_stream "ROUTE-CHECK"; then
                route_check_exit=${PIPESTATUS[0]}
            fi

            # Exit 3 = RouteSmokeCheckJob.EXIT_NO_SAMPLE_LOCATIONS — this region has
            # no sample coordinates configured (today: anything but singapore/
            # new_york). Benign, not a defect — warn and continue rather than fail
            # validation for a region this check was never meant to cover.
            if [[ ${route_check_exit} -eq 0 ]]; then
                log_ok "Route smoke check passed"
            elif [[ ${route_check_exit} -eq 3 ]]; then
                log_warn "Route smoke check skipped — no sample locations configured for region '${REGION}' (log: ${route_check_log})"
            else
                log_error "Route smoke check failed (exit ${route_check_exit}) — tiles cannot serve a route (log: ${route_check_log})"
                errors=$(( errors + 1 ))
            fi
        fi
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

    ln -sfn "v${VERSION_TAG}" "${LATEST_LINK}"
    log_ok "Latest symlink updated: ${LATEST_LINK} → v${VERSION_TAG}"

    if [[ -n "${previous_version}" ]]; then
        log_info "Rollback available: ln -sfn ${previous_version} ${LATEST_LINK}"
    fi
}

# ---------------------------------------------------------------------------
# EFS retention — prune old versions + sweep orphaned staging dirs
# ---------------------------------------------------------------------------
# Idempotent, side-effect-safe retention for the EFS tile dir. Keeps the newest
# ${KEEP_VERSIONS} published v<TAG> dirs (the tar lives INSIDE each, so pruning
# the dir reclaims its .tar too) and removes leftover *.partial staging dirs
# from crashed runs — each *.partial is a full-size copy that the version prune
# deliberately ignores, so it must be reclaimed here or it leaks forever.
#
# Every operation here is best-effort: this function must NEVER abort the
# pipeline. It is called (a) early in phase_efs_sync as a self-healing backstop
# for whatever a prior run left behind, and (b) again after the new version is
# live. Because it is the ONLY thing that reclaims EFS space, it must run even
# when the surrounding phase later fails — hence callers invoke it guarded:
#   _efs_prune "${dir}" || log_warn "EFS prune failed (non-fatal)"
# and the body itself swallows per-item errors so `set -e` can't kill the run.
# ---------------------------------------------------------------------------
_efs_prune() {
    local efs_tile_dir="$1"
    [[ -d "${efs_tile_dir}" ]] || return 0

    # Sweep orphaned staging dirs (pod killed after cp started, before promote).
    # Excluded from the version prune below, so they must be reclaimed here.
    local orphan
    while IFS= read -r -d '' orphan; do
        log_warn "Removing orphaned EFS staging dir: $(basename "${orphan}")"
        rm -rf "${orphan}" || log_warn "Could not remove ${orphan}"
    done < <(find "${efs_tile_dir}" -maxdepth 1 -type d -name "v*.partial" -print0 2>/dev/null)

    # Prune published versions — keep newest N. RUN_ID is a zero-padded
    # %Y%m%d-%H%M%S stamp, so lexical sort == chronological order.
    local versions
    mapfile -t versions < <(
        find "${efs_tile_dir}" -maxdepth 1 -type d -name "v[0-9]*" ! -name "*.partial" 2>/dev/null \
        | sort
    )
    local total=${#versions[@]}
    local to_remove=$(( total - KEEP_VERSIONS ))
    if [[ ${to_remove} -gt 0 ]]; then
        log_info "EFS versions: ${total} (keeping ${KEEP_VERSIONS}); removing ${to_remove} oldest"
        local i
        for (( i=0; i<to_remove; i++ )); do
            log_info "Removing old EFS version: $(basename "${versions[$i]}")"
            rm -rf "${versions[$i]}" || log_warn "Could not remove ${versions[$i]}"
        done
    else
        log_info "EFS versions: ${total} (keeping ${KEEP_VERSIONS}) — nothing to prune"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Phase 6.5: EFS Tile Sync
# ---------------------------------------------------------------------------
# Mirrors the just-built tiles to EFS so the tada-traffic-data-builder cron
# (running in a separate pod) can mmap the .gph files at
# ${VALHALLA_EFS_DIR}/${TILE_SUBDIR}/latest. Without this, that cron's call to
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
        log_info "EFS dir not present at ${efs_dir} — skipping EFS sync${EFS_SKIP_NOTE}"
        return 0
    fi

    local efs_tile_dir="${efs_dir}/${TILE_SUBDIR}"
    local efs_versioned_dir="${efs_tile_dir}/v${VERSION_TAG}"
    local efs_latest_link="${efs_tile_dir}/latest"
    local efs_partial_dir="${efs_versioned_dir}.partial"

    # -----------------------------------------------------------------------
    # In-place detection: is the build ALREADY on the EFS tree?
    # -----------------------------------------------------------------------
    # In prod/stage, VALHALLA_TILE_DIR is itself the EFS mount
    # (/mnt/efs/valhalla_tiles), which is exactly this phase's default efs_dir.
    # VERSIONED_TILE_DIR is then the SAME path as efs_versioned_dir, so the
    # copy below would `cp -r` the tileset onto its own tree as
    # v<TAG>.partial — a full multi-GB write over NFS — only to hit the
    # "already exists" branch and rm -rf the duplicate. Pure waste: the tiles
    # are already in their final location, and Phase 6 has already published
    # them via the local 'latest' symlink.
    #
    # Compared on RESOLVED paths (readlink -f) so a symlinked or bind-mounted
    # EFS root still matches; -ef would also catch hardlink identity but fails
    # when the dest does not exist yet, which is the normal separate-tree case.
    # Falls back to the raw strings if readlink is unavailable.
    #
    # When in-place we skip ONLY the copy — the symlink swap and retention
    # prune below are still required, since Phase 6's symlink is the local
    # VALHALLA_TILE_DIR one and may differ from ${efs_latest_link} when
    # VALHALLA_EFS_DIR is pointed elsewhere.
    local _src_real _dst_real
    _src_real="$(readlink -f "${VERSIONED_TILE_DIR}" 2>/dev/null || echo "${VERSIONED_TILE_DIR}")"
    _dst_real="$(readlink -f "${efs_versioned_dir}" 2>/dev/null || echo "${efs_versioned_dir}")"
    local efs_in_place=false
    [[ "${_src_real}" == "${_dst_real}" ]] && efs_in_place=true

    if [[ "${DRY_RUN}" == true ]]; then
        if [[ "${efs_in_place}" == true ]]; then
            log_dry "Tiles already built in place on EFS (${efs_versioned_dir}) — would skip redundant copy"
        else
            log_dry "Would copy: ${VERSIONED_TILE_DIR} → ${efs_versioned_dir}"
        fi
        log_dry "Would update: ${efs_latest_link} → v${VERSION_TAG}"
        return 0
    fi

    mkdir -p "${efs_tile_dir}"

    # Self-healing backstop: reclaim whatever a prior run left behind (orphaned
    # *.partial staging dirs AND any over-retention versions) BEFORE we add this
    # run's copy. This runs even if a previous run died before its own prune, so
    # EFS can't grow unbounded across failed runs. Guarded: never aborts.
    _efs_prune "${efs_tile_dir}" || log_warn "EFS pre-sync prune failed (non-fatal)"

    if [[ "${efs_in_place}" == true ]]; then
        # Build wrote straight to EFS — nothing to copy. Verify the tiles are
        # really there before we point 'latest' at them, so an in-place run can
        # never publish a symlink to a missing dir.
        if [[ ! -d "${efs_versioned_dir}" ]]; then
            log_error "EFS in-place detected but ${efs_versioned_dir} is missing"
            return 5
        fi
        log_info "Tiles built in place on EFS — skipping redundant copy: ${efs_versioned_dir}"
    else
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

        # Promote .partial → final. The destination may already exist: this run
        # could be a re-run/retry with the same RUN_ID tag, or a --skip-build pass
        # that reuses an existing 'latest' tag. A bare `mv -T` onto a populated dir
        # fails ("File exists"), which is what made this phase non-idempotent.
        #
        # The version tag is content-addressing by convention: the same v<TAG> is
        # the same tiles from the same build. So if the dir already exists, the tiles
        # are already published — we just discard the redundant fresh copy and fall
        # through to (re)assert the 'latest' symlink. This is idempotent and, crucially,
        # never renames the live 'v<TAG>' dir, so 'latest' can't dangle for the
        # traffic cron mid-swap.
        if [[ -e "${efs_versioned_dir}" ]]; then
            log_info "EFS version dir already exists — tiles already published; reusing: ${efs_versioned_dir}"
            rm -rf "${efs_partial_dir}"
        else
            mv -T "${efs_partial_dir}" "${efs_versioned_dir}"
        fi

        local elapsed=$(( $(date +%s) - start_epoch ))
        local size
        size="$(du -sh "${efs_versioned_dir}" | cut -f1)"
        log_ok "EFS copy complete: ${size} in ${elapsed}s"
    fi

    # Atomic symlink swap. Readers see either the old version or the new,
    # never a half-state. Two preconditions ln -sfn alone doesn't handle:
    #
    # 1. If ${efs_latest_link} pre-exists as a real DIRECTORY (e.g. created
    #    by bootstrap before this script ever ran), `ln -sfn target dir` does
    #    NOT replace it — it silently creates `dir/target` inside, producing a
    #    useless self-referencing symlink. We must rmdir the (presumed-empty)
    #    placeholder first.
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

    # Prune again now that this run's version is live and counts toward retention.
    # Guarded so a prune hiccup never fails the pipeline after tiles are published.
    _efs_prune "${efs_tile_dir}" || log_warn "EFS post-swap prune failed (non-fatal)"
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
# Shared pipeline pipeline script — the common body of both scripts' main().
# A pipeline script calls: run_pipeline "$@"
# It relies on the pipeline script having ALREADY defined (before sourcing or after):
#   • config defaults set in set_region_defaults (called here)
#   • PHASES[] and BUILD_PHASES[] arrays (execution order + skip-build subset)
#   • resolve_tile_layout, phase_osm, geometry_mapping (+ any region helpers)
#   • optional: parse_extra_flag, set_region_defaults
# ---------------------------------------------------------------------------
run_pipeline() {
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

    # Shared defaults
    VALHALLA_ENV="${VALHALLA_ENV:-local}"
    PIPELINE_CONFIG_FILE=""
    FORCE_DOWNLOAD=false
    OSM_MAX_AGE_DAYS=6
    DRY_RUN=false
    SKIP_BUILD=false
    SKIP_ROUTE_CHECK=false
    BUILD_EXTRACT=true
    TILE_EXTRACT=""
    KEEP_VERSIONS_ARG=""
    NOTIFY_URL="${NOTIFY_URL:-}"
    SKIP_ELEVATION_ARG=""
    # Tile-layout vars (initialized for set -u safety; resolved in bootstrap).
    IS_GROUP=false
    TILE_GROUP=""
    TILE_SUBDIR=""
    # Region defaults (SKIP_GEOMETRY_MAPPING, etc.) come from the pipeline script.
    if declare -F set_region_defaults >/dev/null; then
        set_region_defaults
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --pipeline-config)        PIPELINE_CONFIG_FILE="$2"; shift 2 ;;
            --force-download)         FORCE_DOWNLOAD=true;        shift   ;;
            --osm-max-age-days)       OSM_MAX_AGE_DAYS="$2";     shift 2 ;;
            --no-elevation)           SKIP_ELEVATION_ARG=true;   shift   ;;
            --with-elevation)         SKIP_ELEVATION_ARG=false;  shift   ;;
            --skip-build)             SKIP_BUILD=true;            shift   ;;
            --skip-geometry-mapping)  SKIP_GEOMETRY_MAPPING=true; shift  ;;
            --skip-route-check)       SKIP_ROUTE_CHECK=true;      shift   ;;
            --no-extract)             BUILD_EXTRACT=false;        shift   ;;
            --keep-versions)          KEEP_VERSIONS_ARG="$2";    shift 2 ;;
            --dry-run)                DRY_RUN=true;               shift   ;;
            --notify-url)             NOTIFY_URL="$2";            shift 2 ;;
            -h|--help)                show_usage; exit 0 ;;
            *)
                # Region-specific flags (e.g. --with-geometry-mapping) are
                # handled by the pipeline script's parse_extra_flag hook if present.
                if declare -F parse_extra_flag >/dev/null && parse_extra_flag "$1"; then
                    shift
                else
                    log_error "Unknown option: $1"; show_usage; exit 1
                fi
                ;;
        esac
    done

    # SKIP_ELEVATION precedence: CLI flag (--no-elevation/--with-elevation) >
    # regions.json skip_elevation > env var > conf file. bootstrap()'s
    # _load_pipeline_config sources the conf, which sets SKIP_ELEVATION and would
    # otherwise clobber the flag, the region setting, and an env override.
    # Capture any pre-bootstrap env value here, then re-assert the correct
    # precedence AFTER bootstrap (below).
    local skip_elev_env="${SKIP_ELEVATION:-}"

    bootstrap

    # After bootstrap, SKIP_ELEVATION holds the value sourced from the conf
    # (default false). Capture it before applying env/flag overrides so we can
    # detect and surface a silent disable.
    local conf_skip_elev="${SKIP_ELEVATION:-false}"

    # Per-region opt-out, read AFTER bootstrap because it may be keyed on the
    # tile group, which resolve_tile_layout only sets during bootstrap. Empty
    # when the region declares nothing, in which case env/conf decide as before.
    # The hook returns "<value> <scope>" on one line — it runs in a subshell, so
    # it cannot hand the scope back via a global. Scope is for logging only.
    # `|| true` is REQUIRED: when the hook declares nothing it prints an empty
    # string, and `read` returns 1 at EOF — which `set -e` would treat as a fatal
    # error and abort the run right after bootstrap. The empty-value case is the
    # common one (any region without skip_elevation), so this must not fail.
    local skip_elev_region="" skip_elev_scope=""
    if declare -F _resolve_region_skip_elevation >/dev/null; then
        read -r skip_elev_region skip_elev_scope \
            < <(_resolve_region_skip_elevation) || true
    fi

    # Re-apply precedence now that the conf has been sourced. SKIP_ELEVATION_ARG
    # is "true" for --no-elevation, "false" for --with-elevation, "" if neither.
    local skip_elev_source="conf (pipeline.${VALHALLA_ENV}.conf)"
    if [[ -n "${SKIP_ELEVATION_ARG}" ]]; then
        SKIP_ELEVATION="${SKIP_ELEVATION_ARG}"    # explicit CLI flag always wins
        skip_elev_source="CLI flag ($([[ "${SKIP_ELEVATION_ARG}" == true ]] && echo --no-elevation || echo --with-elevation))"
    elif [[ -n "${skip_elev_region}" ]]; then
        SKIP_ELEVATION="${skip_elev_region}"      # region opt-out beats env/conf
        skip_elev_source="regions.json skip_elevation=${skip_elev_region} (${skip_elev_scope})"
    elif [[ -n "${skip_elev_env}" ]]; then
        SKIP_ELEVATION="${skip_elev_env}"         # explicit env beats conf
        skip_elev_source="env SKIP_ELEVATION=${skip_elev_env}"
    fi

    # Resolved-state visibility + silent-disable warning are only meaningful for
    # regions that actually acquire elevation (pipeline scripts that define
    # _resolve_elevation_bbox). SG has no inline elevation step, so this block
    # is skipped there and its output is unchanged.
    if declare -F _resolve_elevation_bbox >/dev/null; then
        log_info "Elevation: SKIP_ELEVATION=${SKIP_ELEVATION} (source: ${skip_elev_source})"
        if [[ "${SKIP_ELEVATION}" == true && "${conf_skip_elev}" != true ]]; then
            local _elev_bbox; _elev_bbox="$(_resolve_elevation_bbox)"
            if [[ -n "${_elev_bbox}" ]]; then
                log_warn "Elevation is DISABLED by ${skip_elev_source}, overriding the conf (SKIP_ELEVATION=${conf_skip_elev})."
                log_warn "Region '${REGION}' HAS elevation bounds (${_elev_bbox}) — tiles will build WITHOUT per-edge grade."
                if [[ -n "${skip_elev_region}" && -z "${SKIP_ELEVATION_ARG}" ]]; then
                    log_warn "To build with elevation, pass --with-elevation (wins over regions.json), or remove 'skip_elevation' from the ${skip_elev_scope} entry in regions.json."
                else
                    log_warn "To build with elevation, pass --with-elevation or unset the SKIP_ELEVATION env."
                fi
            fi
        fi
    fi

    if [[ "${SKIP_BUILD}" == true ]]; then
        local existing_latest="${LATEST_LINK}"
        if [[ ! -e "${existing_latest}" ]]; then
            log_error "--skip-build requires an existing 'latest' symlink at: ${existing_latest}"
            exit 1
        fi
        VERSIONED_TILE_DIR="$(readlink -f "${existing_latest}")"
        # Dirs are named v<RUN_ID>; VERSION_TAG is the bare RUN_ID (consumers add
        # the 'v'). Strip the leading 'v' so --skip-build doesn't yield 'vv<tag>'
        # in S3 keys, symlink targets, and EFS paths.
        VERSION_TAG="$(basename "${VERSIONED_TILE_DIR}")"
        VERSION_TAG="${VERSION_TAG#v}"
        log_info "Skipping build — using existing tiles: ${VERSIONED_TILE_DIR}"
    fi

    # Run phases in declared order. Under --skip-build, the leading BUILD_PHASES
    # are skipped (their work is replaced by the --skip-build resolution above).
    local phase
    for phase in "${PHASES[@]}"; do
        if [[ "${SKIP_BUILD}" == true ]] && _is_build_phase "${phase}"; then
            continue
        fi
        "${phase}"
    done

    log_ok "${COMPLETION_LABEL}v${VERSION_TAG}"
    exit ${PIPELINE_EXIT_CODE}
}

# True if $1 is listed in BUILD_PHASES[] (the --skip-build subset).
_is_build_phase() {
    local candidate="$1" p
    for p in "${BUILD_PHASES[@]}"; do
        [[ "${p}" == "${candidate}" ]] && return 0
    done
    return 1
}
