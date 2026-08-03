#!/bin/bash
# =============================================================================
# Valhalla Tile Generation Pipeline — US CLUSTER (any region or tile group)
# =============================================================================
# Dedicated entrypoint for the US server cluster. Kept SEPARATE from
# run-tile-pipeline.sh (Singapore/APAC) on purpose: the US cluster has its own
# EFS mount and its own S3 bucket (us-east-1). Isolating the two pipelines means
# a change for one region can never break the other's weekly production build.
#
# Both entrypoints are THIN PIPELINE SCRIPTS over lib/tile-pipeline-common.sh — the
# shared phase logic lives in the lib; this file provides only the US region
# config and the US-specific phases (grouped-OSM merge, block-ways, elevation
# acquire, local-cache geometry mapping).
#
# Lifecycle:
#   OSM acquire → block ways → admin build → elevation acquire → tile build
#   → tile extract → validate → S3 sync → swap latest → cleanup → (geometry mapping)
#
# ELEVATION (when enabled): Skadi .hgt.gz tiles covering the region (group =
# union of member bounds from regions.json) are downloaded into the versioned
# tile dir BEFORE the tile build, because valhalla_build_tiles samples them
# during its Enhance stage to stamp per-edge grade. Without this the build
# silently emits tiles with no elevation. Toggle precedence is
# --no-elevation (CLI) > regions.json skip_elevation (region, then its tile_group)
# > SKIP_ELEVATION (env) > pipeline.<env>.conf. Set skip_elevation in regions.json
# to disable elevation for ONE region/group without affecting the whole cluster
# (SKIP_ELEVATION in the conf is per-environment). Tune
# download concurrency with ELEVATION_PARALLELISM (default 8). The .hgt.gz
# tiles are excluded from the .tar extract (extract packs *.gph only) but ARE
# included in the S3 sync as part of the versioned tileset.
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
# Then run:  VALHALLA_ENV=prod-virginia ./run-tile-pipeline-us.sh <new_region>
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
#   --with-elevation          Force-include elevation data (overrides conf/env)
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
#   VALHALLA_ENV              local | dev | test | stage-virginia | prod-virginia (default: local)
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

# ---------------------------------------------------------------------------
# Source the shared core, asserting a matching version so a pipeline script and a stale
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
readonly REGION_LABEL=" (US)"                           # bootstrap phase label suffix
readonly LOG_PREFIX="pipeline-us"                       # log file name prefix
readonly DEFAULT_S3_REGION="us-east-1"
readonly PIPELINE_LABEL="US Pipeline "                  # on_exit banner prefix
readonly COMPLETION_LABEL="US pipeline completed successfully — "
readonly EFS_SKIP_NOTE=" (local dev / no US traffic yet)"

# Execution order (verbatim from the original main()) and the --skip-build subset.
readonly PHASES=(phase_osm phase_block_ways phase_build phase_extract phase_validate
                 phase_s3_sync phase_swap_latest phase_cleanup
                 geometry_mapping phase_efs_sync)
readonly BUILD_PHASES=(phase_osm phase_block_ways phase_build)

# Region-specific default flags. US: geometry mapping is SG-specific (LTA), so
# default to skipping it.
set_region_defaults() {
    SKIP_GEOMETRY_MAPPING=true
}

# US-only CLI flag: --with-geometry-mapping (forces the job on). Returns 0 if it
# consumed the arg, 1 otherwise (lib then reports "Unknown option").
parse_extra_flag() {
    case "$1" in
        --with-geometry-mapping) SKIP_GEOMETRY_MAPPING=false; return 0 ;;
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# Tile-layout resolution. US regions normally belong to a tile_group (shared,
# multi-source-merged tiles). A US region with its own tile_dir / osm_source
# (single-state) is also supported as a fallback.
# ---------------------------------------------------------------------------
resolve_tile_layout() {
    local regions_config="${PROJECT_ROOT}/config/regions/regions.json"
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
}

# ---------------------------------------------------------------------------
# Phase 1: OSM Acquire / Merge (grouped → merge sources; single → download)
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

# ---------------------------------------------------------------------------
# Phase 1.5: Block Ways (stamp access=no on listed OSM way_ids before build)
# ---------------------------------------------------------------------------
phase_block_ways() {
    set_phase "Phase 1.5: Block Ways"
    local blocklist out
    # Use the script-level SCRIPT_DIR/PROJECT_ROOT (defined at the top with
    # readlink -f) rather than re-deriving from BASH_SOURCE here: BASH_SOURCE is
    # NOT symlink-resolved, so when this pipeline script is invoked via a symlink (e.g.
    # /usr/local/bin/run-tile-pipeline-us.sh) the local derivation yields
    # /usr/local/bin and a repo_root of /usr — silently skipping the blocklist.
    blocklist="${PROJECT_ROOT}/config/regions/${REGION}/blocked_way_ids.txt"

    if [[ ! -f "${blocklist}" ]] || ! grep -qvE '^[[:space:]]*(#.*)?$' "${blocklist}"; then
        log_info "No blocked way_ids for '${REGION}'; skipping (${blocklist})"
        return 0
    fi

    if ! python3 -c "import osmium" 2>/dev/null; then
        log_error "phase_block_ways requires pyosmium (apt: python3-pyosmium); not found"
        exit 1
    fi

    out="${OSM_FILE%.pbf}.blocked.pbf"
    log_info "Stamping access=no on blocked way_ids from ${blocklist}"
    python3 "${SCRIPT_DIR}/apply_blocked_ways.py" --in "${OSM_FILE}" --out "${out}" --blocklist "${blocklist}"
    mv -f "${out}" "${OSM_FILE}"
    log_ok "Block-ways phase complete"
}

# ---------------------------------------------------------------------------
# Elevation bbox resolution + Skadi acquire (US-only; run inside phase_build).
# ---------------------------------------------------------------------------
_resolve_elevation_bbox() {
    local regions_config="${PROJECT_ROOT}/config/regions/regions.json"
    local filter
    if [[ "${IS_GROUP}" == true ]]; then
        # Union over all regions whose tile_group == this group.
        filter=".regions | map(select(.tile_group==\"${TILE_GROUP}\") | .bounds)"
    else
        # Single region: wrap its bounds in a 1-element array for the same reducer.
        filter="[.regions.${REGION}.bounds]"
    fi

    jq -r "
        ${filter}
        | map(select(. != null))
        | if length == 0 then empty
          else
            \"\(map(.min_lon) | min),\(map(.min_lat) | min),\(map(.max_lon) | max),\(map(.max_lat) | max)\"
          end
    " "${regions_config}" 2>/dev/null
}

# Per-region elevation opt-out from regions.json. Echoes "<value> <scope>", or
# nothing when neither the region nor its tile group declares `skip_elevation`
# (in which case run_pipeline falls through to the env/conf value).
#
# The region's own setting wins over the group's, so a single member can differ
# from its group. The scope is returned on the SAME line rather than assigned to
# a global, because the caller invokes this in a command substitution — a
# subshell, whose variable assignments are discarded. The caller splits the two
# fields; the scope is used only to name the source in the log line.
#
# Only `true`/`false` are honoured — any other value is ignored with a warning
# rather than being silently coerced, since a typo'd "yes" quietly enabling a
# multi-hour elevation download is exactly the silent surprise this avoids.
# The warning goes to stderr so it can't be captured as part of the value.
_resolve_region_skip_elevation() {
    local regions_config="${PROJECT_ROOT}/config/regions/regions.json"
    local value="" scope=""

    value="$(jq -r ".regions.${REGION}.skip_elevation // empty" "${regions_config}" 2>/dev/null)"
    scope="region ${REGION}"

    if [[ -z "${value}" && -n "${TILE_GROUP:-}" ]]; then
        value="$(jq -r ".tile_groups.${TILE_GROUP}.skip_elevation // empty" "${regions_config}" 2>/dev/null)"
        scope="tile_group ${TILE_GROUP}"
    fi

    [[ -z "${value}" ]] && return 0

    if [[ "${value}" != true && "${value}" != false ]]; then
        log_warn "Ignoring invalid skip_elevation='${value}' in regions.json (${scope}) — expected boolean true/false." >&2
        return 0
    fi

    printf '%s %s' "${value}" "${scope}"
}

_acquire_elevation() {
    if [[ "${SKIP_ELEVATION}" == true ]]; then
        log_info "Elevation disabled (SKIP_ELEVATION/--no-elevation) — skipping elevation download"
        return 0
    fi

    local bbox
    bbox="$(_resolve_elevation_bbox)"
    if [[ -z "${bbox}" ]]; then
        log_warn "No bounds found in regions.json for '${REGION}' — cannot download elevation. Tiles will build without grade data."
        return 0
    fi

    if [[ "${DRY_RUN}" == true ]]; then
        log_dry "Would download elevation tiles for bbox ${bbox} → ${VERSIONED_TILE_DIR}"
        return 0
    fi

    log_info "Elevation bbox (${IS_GROUP:+group }${REGION}): ${bbox}"
    log_info "Downloading Skadi elevation tiles → ${VERSIONED_TILE_DIR}"

    local elev_log="${VALHALLA_LOG_DIR}/elevation-${TILE_SUBDIR}-${RUN_ID}.log"
    local parallelism="${ELEVATION_PARALLELISM:-8}"

    if [[ "${USE_DOCKER}" == true ]]; then
        # The valhalla image ships valhalla_build_elevation on PATH. Mount the
        # versioned tile dir as the output target (same mount the tile build uses).
        docker run --rm \
            -v "${VERSIONED_TILE_DIR}:/valhalla/tiles" \
            "${VALHALLA_DOCKER_IMAGE}" \
            valhalla_build_elevation \
            --from-bbox "${bbox}" \
            --outdir /valhalla/tiles \
            --parallelism "${parallelism}" -v \
            2>&1 | tee -a "${elev_log}" | _log_stream "ELEVATION"
        local elev_exit=${PIPESTATUS[0]:-$?}
    else
        local elev_script="${PROJECT_ROOT}/scripts/valhalla_build_elevation"
        local runner=()
        if [[ -x "${elev_script}" ]]; then
            runner=(python3 "${elev_script}")
        elif command -v valhalla_build_elevation &>/dev/null; then
            runner=(valhalla_build_elevation)
        else
            log_warn "valhalla_build_elevation not found (checked ${elev_script} and PATH) — skipping elevation"
            return 0
        fi
        "${runner[@]}" \
            --from-bbox "${bbox}" \
            --outdir "${VERSIONED_TILE_DIR}" \
            --parallelism "${parallelism}" -v \
            2>&1 | tee -a "${elev_log}" | _log_stream "ELEVATION"
        local elev_exit=${PIPESTATUS[0]:-$?}
    fi

    if [[ ${elev_exit} -ne 0 ]]; then
        log_error "Elevation download failed (exit ${elev_exit})"
        return 1
    fi

    local hgt_count
    hgt_count="$(find "${VERSIONED_TILE_DIR}" -name "*.hgt*" 2>/dev/null | wc -l)"
    if [[ ${hgt_count} -eq 0 ]]; then
        log_warn "Elevation download reported success but no .hgt tiles found in ${VERSIONED_TILE_DIR}"
        return 1
    fi
    log_ok "Elevation tiles ready: ${hgt_count} tiles ($(du -sh "${VERSIONED_TILE_DIR}" 2>/dev/null | cut -f1) incl. graph)"
}

# ---------------------------------------------------------------------------
# Geometry Mapping (US form — local cache dir, no LTA/EFS snapshots).
# Default-skipped for US; enable with --with-geometry-mapping.
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
  --with-elevation          Force-include elevation data (overrides conf/env)
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
  stage-virginia   pipeline.stage-virginia.conf + Docker + US S3
  prod-virginia    pipeline.prod-virginia.conf  + Docker + US S3 + elevation

Examples:
  # Grouped region — build the tri-state group via any member region key
  ./run-tile-pipeline-us.sh new_york --no-elevation     # → tiles under nyc_tri_state/

  # Single region — Singapore-style, tiles under its own tile_dir
  ./run-tile-pipeline-us.sh florida --no-elevation      # → tiles under florida/

  # Production US — uses pipeline.prod-virginia.conf automatically
  VALHALLA_ENV=prod-virginia ./run-tile-pipeline-us.sh new_york

  # Staging US with elevation forced on (staging conf skips it by default)
  VALHALLA_ENV=stage-virginia ./run-tile-pipeline-us.sh new_york --with-elevation

  # Dry-run (verify a newly-added region resolves correctly before a real build)
  VALHALLA_ENV=prod-virginia ./run-tile-pipeline-us.sh new_york --dry-run

  # Cron (every Tuesday 07:00 UTC = 02:00 US Eastern wall-ish):
  # 0 7 * * 1 cd /opt/valhalla && VALHALLA_ENV=prod-virginia ./deploy/scripts/run-tile-pipeline-us.sh new_york >> /var/log/valhalla/cron-us.log 2>&1

EOF
}

run_pipeline "$@"
