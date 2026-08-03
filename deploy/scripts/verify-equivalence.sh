#!/bin/bash
# =============================================================================
# verify-equivalence.sh — prove the tile-pipeline refactor preserves behavior
# =============================================================================
# Captures the --dry-run transcript of both pipeline scripts and diffs it
# against a golden baseline, after normalizing volatile fields (timestamps,
# RUN_IDs, run durations). Used to gate the lib/tile-pipeline-common.sh
# extraction: a passing run proves the thin pipeline scripts emit the same ordered
# phases and log lines as before.
#
# Usage:
#   ./verify-equivalence.sh baseline   # capture current output as the golden ref
#   ./verify-equivalence.sh check      # re-capture and diff against the golden ref
#
# Regions exercised:
#   singapore   — SG single-region
#   thailand    — SG single-region (second region, catches region-specific leaks)
#   new_york    — US grouped region (nyc_tri_state)
#
# Exit: 0 if all diffs empty (or baseline captured), 1 if any diff is non-empty.
# =============================================================================
set -uo pipefail

# readlink -f so a symlinked invocation resolves to the real tree, matching how
# both pipeline scripts derive SCRIPT_DIR. Without it SCRIPT_DIR would point at
# the symlink's directory: the scripts invoked at line 137/141 would not be found,
# and the PROJECT_ROOT below would normalize the wrong prefix at line 120.
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
OUT_DIR="${TPC_VERIFY_DIR:-/tmp/tpc-verify}"
mkdir -p "${OUT_DIR}"

SG_REGIONS=(singapore thailand)
US_REGIONS=(new_york)

# PROJECT_ROOT of the tree being captured. Baseline and check runs live in
# DIFFERENT trees (a temp git worktree at the pre-refactor commit vs the real
# working tree), so every absolute path in the transcript would otherwise
# differ and swamp the real signal. Normalizing it to a literal makes the
# comparison location-independent — which is what lets a baseline captured
# from a throwaway worktree be diffed against the working tree at all.
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# ---------------------------------------------------------------------------
# Hermetic data dirs — the transcript must not depend on local build state.
# ---------------------------------------------------------------------------
# Several dry-run log lines are derived from the filesystem, so a tree with a
# warm data/ dir and a tree without one legitimately take DIFFERENT branches:
#   • phase_osm     — "OSM file not found" vs "exists. Age: N day(s)" / "stale"
#   • phase_cleanup — "Versions present: 0" vs "2", plus a `find:` stderr line
#                     when the tile dir is absent entirely
# Those are real branches, so normalizing them away with regex would mask
# genuine behavior changes. Instead we pin the environment: every capture runs
# against a FRESH EMPTY sandbox, so both sides observe identical state and any
# surviving diff is attributable to the code.
#
# bootstrap() applies these as "${VAR:-default}", so exporting them here wins
# over pipeline.local.conf without editing the conf.
#
# Consequence: the golden always records the cold-cache path ("OSM file not
# found", "Versions present: 0"). That is the point — it is reproducible on any
# machine and in CI, where no data/ dir exists.
SANDBOX="${OUT_DIR}/sandbox"
SANDBOX_CONF="${SANDBOX}/pipeline.sandbox.conf"

# Env vars can NOT be used to redirect these paths: bootstrap() sources the
# conf (line ~236) BEFORE applying its "${VAR:-default}" fallbacks (~239), and
# the conf assigns VALHALLA_TILE_DIR=... unconditionally — so a conf value
# always clobbers an exported one. (Same precedence trap the lib documents for
# SKIP_ELEVATION.) We therefore generate a conf and pass --pipeline-config,
# which is the pipeline's own supported override path.
#
# Derived from the active pipeline.local.conf so non-path settings (executor
# image, S3, SKIP_ELEVATION) stay exactly as the real run would see them —
# only the four data paths are rewritten. If that conf is absent, the four
# lines below stand alone and the pipeline script's own defaults apply elsewhere.
_reset_sandbox() {
    rm -rf "${SANDBOX}"
    mkdir -p "${SANDBOX}/data/valhalla_tiles" \
             "${SANDBOX}/data/osm" \
             "${SANDBOX}/data/admin_data" \
             "${SANDBOX}/logs"

    local src="${PROJECT_ROOT}/deploy/config/pipeline.local.conf"
    if [[ -f "${src}" ]]; then
        grep -vE '^\s*(VALHALLA_TILE_DIR|OSM_DIR|VALHALLA_ADMIN_DIR|VALHALLA_LOG_DIR)=' \
            "${src}" > "${SANDBOX_CONF}"
    else
        : > "${SANDBOX_CONF}"
    fi
    cat >> "${SANDBOX_CONF}" <<EOF
VALHALLA_TILE_DIR=${SANDBOX}/data/valhalla_tiles
OSM_DIR=${SANDBOX}/data/osm
VALHALLA_ADMIN_DIR=${SANDBOX}/data/admin_data
VALHALLA_LOG_DIR=${SANDBOX}/logs
EOF
}

# Run one pipeline script against a freshly-reset sandbox, so runs can't observe each
# other's output (a log file or version dir left by the previous region).
# --help runs are passed through untouched: they exit before arg parsing gets
# to --pipeline-config, and appending it would change what is being compared.
_run_entrypoint() {
    _reset_sandbox
    if [[ "$*" == *--help* ]]; then
        VALHALLA_ENV=local "$@" 2>&1 | _norm
    else
        VALHALLA_ENV=local "$@" --pipeline-config "${SANDBOX_CONF}" 2>&1 | _norm
    fi
}

_norm() {
    # Quote folding (first clause) must come BEFORE the path substitutions: GNU
    # findutils quotes paths in its diagnostics using the locale's quoting style
    # — ASCII 'path' under LC_ALL=C, but U+2018/U+2019 ‘path’ under a UTF-8
    # locale. Same code, same paths, different bytes, so an unfolded transcript
    # diffs unequal purely on the capture host's locale. That would make the
    # golden non-portable to CI and to another machine, which defeats the point.
    # Folding both curly forms to ASCII ' is safe: no pipeline log line uses a
    # curly quote to mean anything a straight quote wouldn't.
    sed -E \
        -e 's/\xe2\x80\x98/'"'"'/g' \
        -e 's/\xe2\x80\x99/'"'"'/g' \
        -e "s|${SANDBOX}|[SANDBOX]|g" \
        -e "s|${PROJECT_ROOT}|[ROOT]|g" \
        -e 's/\[[0-9]{2}:[0-9]{2}:[0-9]{2}\]/[TS]/g' \
        -e 's/[0-9]{8}-[0-9]{6}/RUNID/g' \
        -e 's/v[0-9]{8}-[0-9]{6}/vRUNID/g' \
        -e 's/"ts":"[^"]*"/"ts":"TS"/g' \
        -e 's/"run":"[^"]*"/"run":"RUNID"/g' \
        -e 's/Duration:    [0-9]+s/Duration:    Ns/g'
}

_capture() {
    local suffix="$1"   # "golden" or "current"
    local r
    for r in "${SG_REGIONS[@]}"; do
        _run_entrypoint "${SCRIPT_DIR}/run-tile-pipeline.sh" "$r" --dry-run \
            > "${OUT_DIR}/sg.${r}.${suffix}.log"
    done
    for r in "${US_REGIONS[@]}"; do
        _run_entrypoint "${SCRIPT_DIR}/run-tile-pipeline-us.sh" "$r" --dry-run \
            > "${OUT_DIR}/us.${r}.${suffix}.log"
    done
    _run_entrypoint "${SCRIPT_DIR}/run-tile-pipeline.sh"    --help > "${OUT_DIR}/sg.help.${suffix}.log"
    _run_entrypoint "${SCRIPT_DIR}/run-tile-pipeline-us.sh" --help > "${OUT_DIR}/us.help.${suffix}.log"
    rm -rf "${SANDBOX}"
}

_keys() {
    local r
    for r in "${SG_REGIONS[@]}"; do echo "sg.${r}"; done
    for r in "${US_REGIONS[@]}"; do echo "us.${r}"; done
    echo "sg.help"
    echo "us.help"
}

case "${1:-check}" in
    baseline)
        _capture golden
        echo "Golden baseline captured under ${OUT_DIR}/*.golden.log"
        echo "Review these, then commit the refactor and run: $0 check"
        ;;
    check)
        _capture current
        rc=0
        while IFS= read -r key; do
            if [[ ! -f "${OUT_DIR}/${key}.golden.log" ]]; then
                echo "MISSING golden for ${key} — run '$0 baseline' first"; rc=1; continue
            fi
            if diff -q "${OUT_DIR}/${key}.golden.log" "${OUT_DIR}/${key}.current.log" >/dev/null; then
                echo "  ✓ ${key}"
            else
                echo "  ✗ ${key} — differs:"
                diff "${OUT_DIR}/${key}.golden.log" "${OUT_DIR}/${key}.current.log" | sed 's/^/      /'
                rc=1
            fi
        done < <(_keys)
        exit ${rc}
        ;;
    *)
        echo "Usage: $0 {baseline|check}" >&2
        exit 2
        ;;
esac
