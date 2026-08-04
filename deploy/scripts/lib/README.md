# Tile Pipeline — shared core & how to add regions / clusters

`lib/tile-pipeline-common.sh` holds the shared tile-generation logic. The per-cluster
entrypoints are **thin pipeline scripts** that source it:

- `run-tile-pipeline.sh` — Singapore / APAC (SG)
- `run-tile-pipeline-us.sh` — US cluster

The lib owns every shared phase (OSM helpers, admin/tile build, extract, validate, S3
sync, swap-latest, cleanup, EFS sync, retention) and the `run_pipeline` entry function.
A pipeline script supplies only cluster config + the region-shaped functions. A fix to
shared logic is made **once, in the lib**.

Two orderings inside `phase_build` are load-bearing and must not be re-ordered: admins are
built **before** tiles (they are an *input* to `valhalla_build_tiles`, not a post-step),
and an admin-build failure is non-fatal — it warns and continues, yielding tiles without
admin data rather than no tiles at all.

Tiles are always addressed on disk by `${TILE_SUBDIR}` (never `${REGION}`): a pipeline
script's `resolve_tile_layout` sets it — for a single region it equals the region name,
for a grouped region it's the shared group dir.

---

## What changed in this refactor

Both pipeline scripts previously carried a near-complete copy of the pipeline. Every
shared fix had to be applied twice, and the two copies had already drifted.

| | Before | After |
|---|---|---|
| `run-tile-pipeline.sh` (SG) | 1303 lines, full pipeline | **269** — thin pipeline script |
| `run-tile-pipeline-us.sh` (US) | 1522 lines, full pipeline | **508** — thin pipeline script |
| `lib/tile-pipeline-common.sh` | — | **1366** — shared core |

2825 lines of duplicated pipeline became 777 lines of pipeline script over one shared
core.
Behavior is unchanged and *proven* unchanged — see [Verifying a change](#verifying-a-change).

Alongside the extraction:

- **Version guard.** The lib exports `LIB_VERSION`; each pipeline script declares
  `EXPECTED_LIB_VERSION` and aborts on mismatch, so a half-deployed pair fails loudly at
  startup instead of running with a lib it wasn't written against. Bump both together.
- **S3 preflight.** `_preflight_s3` runs in `bootstrap` and **hard-fails (exit 1)** on a
  blank `S3_TILE_BUCKET` in any non-`local` env, and verifies the bucket is reachable in
  `S3_REGION` from the host's IAM role. Previously a blank bucket made Phase 5 skip
  silently and the run reported success having archived nothing — after the multi-hour
  build.
- **Docker image guard.** `_reject_unsafe_docker_image` rejects tag patterns that drift
  from the JAR's `libvalhalla.so.3`. The prod confs were repinned off `:latest`.
  See [Builder image tags](#builder-image-tags).
- **`local` conf anchored to `${PROJECT_ROOT}`.** `pipeline.local.conf` paths were
  CWD-relative, so output landed in a different place depending on where you invoked the
  script from. The conf is sourced from inside `bootstrap()`, where `PROJECT_ROOT` is
  already set, so `${PROJECT_ROOT}/data/...` expands correctly.
- **Per-region elevation opt-out.** `skip_elevation` in `regions.json`, on a region or a
  `tile_groups` entry. See [the region docs](../../../config/regions/README.md).
- **Retention** (`_efs_prune`) runs pre-sync *and* post-swap.

### Packaging (`docker/Dockerfile.prod`)

`deploy/scripts/` is now copied as a **whole directory** rather than file-by-file, so new
libs/helpers/pipeline scripts ship without a Dockerfile edit. Two consequences worth
knowing:

- The image build **verifies the scripts in-image**: `bash -n` on both
  `run-tile-pipeline*.sh` and the lib, sources the lib and asserts `LIB_VERSION` is
  non-empty (the value each pipeline script's guard compares), `ast.parse` on
  `apply_blocked_ways.py`, and checks both `/usr/local/bin` symlinks are executable. A
  missing `lib/` used to be invisible until a real build failed in prod. The version
  assertion is deliberately non-empty rather than an equality check against
  `EXPECTED_LIB_VERSION`: both pipeline scripts already assert equality at startup, and
  `COPY deploy/scripts/` ships the lib and both scripts as one layer from one commit, so
  the image cannot hold a bumped lib with a stale script unless the commit itself is
  inconsistent. What this proves is that the lib resolves and executes far enough to
  export anything at all — i.e. it is not missing or truncated.
- `.dockerignore` needs `**/data/` and `**/logs/` **in addition to** `data/` and `logs/`.
  Docker's patterns are root-relative (unlike `.gitignore`), so a bare `data/` matches
  `./data/` only and would let `deploy/scripts/data/` — a ~238MB local OSM extract — into
  the image. Do not delete the `**/` entries as redundant.

---

## Builder image tags

**Use `<branch>-latest`. Never `:latest`.**

`build-valhalla-image.yml` publishes exactly two tags per push, and nothing else:

```
633107344074.dkr.ecr.ap-southeast-1.amazonaws.com/valhalla:<branch>-latest
633107344074.dkr.ecr.ap-southeast-1.amazonaws.com/valhalla:<branch>-<short-sha>
```

`<branch>` is `GITHUB_REF_NAME` with unsafe characters replaced — no special-casing, so
`master` → `master-latest`. Deployable branches are `master`, `development`, `test`,
`staging`, `dist`, `snapshot`. **There is no step anywhere in CI that pushes `:latest`.**

The coupling that matters: `publish-jni-jar.yml` extracts the JNI JAR from
`<branch>-latest` — the *same tag*. Builder and `libvalhalla.so.3` therefore come from one
commit. Break that and tiles are built by a different Valhalla version than the one serving
them, which surfaces as **SIGBUS in `AutoCost::Allowed` on every route**, not as a build
error.

### `<branch>-latest` is the proven convention

The dev/test/stage confs have always used it, and are what currently works:

| Conf | Image tag |
|---|---|
| `pipeline.dev.conf` | `valhalla:development-latest` |
| `pipeline.test.conf` | `valhalla:test-latest` |
| `pipeline.stage.conf` | `valhalla:staging-latest` |
| `pipeline.prod.conf` | `valhalla:master-latest` |
| `pipeline.prod-virginia.conf` | `valhalla:master-latest` |
| `pipeline.stage-virginia.conf` | `valhalla:staging-latest` |
| `pipeline.local.conf` | `valhalla:local` (locally built, not from ECR) |

`:latest` was only ever set in the two **prod** confs — i.e. the environments that work
never used it. Since CI does not publish `:latest`, anything under that tag was pushed
manually: it either 404s or silently pulls an unrelated stale commit. The prod repin to
`master-latest` brings prod in line with dev/test/stage rather than introducing a new
scheme.

### Rejected patterns

`_reject_unsafe_docker_image` (called from `bootstrap`) exits 1 on:

| Pattern | Why |
|---|---|
| `ghcr.io/valhalla/valhalla:*` | floating **upstream** image, not built from this repo — the original SIGBUS cause |
| `…/valhalla:development` \| `:staging` \| `:test` \| `:production` \| `:prod-virginia` \| `:stage-virginia` | bare env tag; CI never publishes these, so it's orphaned/manual |
| `…/valhalla:latest` | bare `:latest` on our own registry — manual, drifts from the JAR independently |

`<branch>-latest` does **not** match the third pattern — it anchors on `:latest`.

A blank `VALHALLA_DOCKER_IMAGE` is *not* rejected by this guard — it's how you say "build
with a local binary instead". `_check_deps` picks the executor in precedence order
**`VALHALLA_BUILD_TILES_BIN` > system `valhalla_build_tiles` on `PATH` > Docker**, and only
errors on a blank image when it has fallen through to Docker (nothing left to run). Either
way the binary must itself be built from this repo; the guard cannot check that, so a
system `valhalla_build_tiles` from a distro package is a silent version-skew risk.

There is deliberately **no** fallback image — a wrong default is worse than a hard failure
here.

### Registry is `ap-southeast-1` for every cluster, including US

`ECR_REGISTRY` is hardcoded to `ap-southeast-1` in the workflow, so that is the only
registry CI pushes to. A `us-east-1` image reference has nothing to pull — the US confs
previously pointed there and could not have worked. Cross-region pull cost is paid once per
multi-hour build, so it is negligible. To make US pull locally, set up ECR cross-region
replication **first**, then change the host portion.

### If a tag is missing

Trigger `build-valhalla-image.yml` on that branch (it has `workflow_dispatch`). Do **not**
work around it by pointing at `:latest`. To check what exists:

```bash
aws ecr describe-images --repository-name valhalla --region ap-southeast-1 \
  --query "reverse(sort_by(imageDetails,&imagePushedAt))[:25].[imagePushedAt,imageTags]" \
  --output table
```

---

## Exit codes

`run_pipeline` exits with `PIPELINE_EXIT_CODE`; `on_exit` always prints a summary banner
naming the phase reached. Non-zero is not uniformly fatal — 6 means the tiles are live:

| Code | Meaning | Tiles usable? |
|---|---|---|
| 0 | success | yes |
| 1 | config / preflight / usage error (unknown region, blank S3 bucket, unsafe image, missing dep, `--skip-build` with no `latest`) | unchanged |
| 3 | no Valhalla build-config template found | no |
| 4 | validation failed (missing tiles or extract) | not published |
| 5 | S3 upload failed | built, not archived |
| 6 | partial success — `aws` CLI absent, S3 sync skipped | **yes, published** |

Geometry mapping is deliberately non-fatal for the two expected cases — the job's own exit
1 (below acceptance threshold) and exit 3 (no LTA speed-bands snapshot yet; the
`tada-valhalla-traffic` cron will produce it) both **warn and continue**. A cluster with no
traffic feed is a valid state. Any other job exit is a real failure.

---

## Adding a new REGION (no new script)

**You do NOT create or edit any script.** Edit `config/regions/regions.json` and run the
pipeline script for that cluster. The scripts are region-agnostic — the region is an
argument.

### US-pipeline region (`run-tile-pipeline-us.sh`)

`resolve_tile_layout` reads `tile_dir` + `osm_source`:

```json
"myregion": {
  "enabled": true,
  "tile_dir": "myregion",
  "osm_source": "https://download.geofabrik.de/.../myregion-latest.osm.pbf"
}
```

```bash
VALHALLA_ENV=prod-virginia ./run-tile-pipeline-us.sh myregion --no-elevation --dry-run  # verify resolution
VALHALLA_ENV=prod-virginia ./run-tile-pipeline-us.sh myregion --no-elevation            # real run
```

### SG-pipeline region (`run-tile-pipeline.sh`)

Keys the subdir off the region name, so it only needs `osm_source`:

```json
"myregion": {
  "enabled": true,
  "osm_source": "https://download.geofabrik.de/.../myregion-latest.osm.pbf"
}
```

```bash
VALHALLA_ENV=prod ./run-tile-pipeline.sh myregion --dry-run   # geometry mapping runs (SG default)
VALHALLA_ENV=prod ./run-tile-pipeline.sh myregion
```

### New MEMBER of an existing tile group

Add the region with `"tile_group": "<group>"`, and list its OSM source under that group's
`tile_groups.<group>.osm_sources[]`. No script change.

### Notes for region adds
- **Always start with `--dry-run`** — it resolves the region, prints the OSM source and
  all target paths, and confirms the config parses, without downloading or building.
- **Build template** (optional): add `config/regions/<region>/valhalla-<region>.json` for
  region-specific build settings; otherwise the pipeline falls back to an existing template.
- **`bounds`** in `regions.json` is only needed for elevation. Omit it for `--no-elevation`.
- **What runs, per flag / env:**
  - Geometry mapping — ON by default on SG; OFF by default on US (opt in with
    `--with-geometry-mapping`).
  - Elevation — pass `--no-elevation` to skip; needs `bounds` if enabled. Can also be
    disabled persistently per region (see below).
  - S3 sync — skips automatically if `S3_TILE_BUCKET` is unset (set per-env in
    `deploy/config/pipeline.<env>.conf`).
  - EFS sync — skips automatically if the EFS mount isn't present.

### Disabling elevation for one region (US pipeline)

`SKIP_ELEVATION` in `pipeline.<env>.conf` is **per-environment**, so flipping it there
turns elevation off for every region on that cluster. To disable it for one region only,
set `skip_elevation` in `regions.json` — on the region, or on a `tile_groups` entry to
cover all its members:

```json
"tile_groups": {
  "nyc_tri_state": {
    "tile_dir": "nyc_tri_state",
    "skip_elevation": true
  }
}
```

Resolution order, highest first:

| Source | Scope | Notes |
|---|---|---|
| `--no-elevation` / `--with-elevation` | one run | always wins — the operator escape hatch |
| `regions.json` region `skip_elevation` | one region | beats its tile group |
| `regions.json` tile_group `skip_elevation` | all group members | |
| `SKIP_ELEVATION` env var | one run | |
| `SKIP_ELEVATION` in `pipeline.<env>.conf` | whole cluster | the default |

Notes:
- Only `true` / `false` are accepted. Any other value logs a warning and is **ignored**
  (falls through to env/conf) rather than being coerced — a typo'd `"yes"` must not
  silently trigger a multi-hour elevation download.
- Every run logs the resolved value **and its source**, e.g.
  `Elevation: SKIP_ELEVATION=true (source: regions.json skip_elevation=true (tile_group nyc_tri_state))`.
- SG (`run-tile-pipeline.sh`) has no inline elevation phase, so this key has no effect
  there. It is read via the `_resolve_region_skip_elevation` hook, which only the US
  pipeline script defines — a new cluster pipeline script opts in by defining it
  too.

---

## Adding a new CLUSTER (new thin pipeline script)

Create a new pipeline script **only** when the region family needs its own
infrastructure — a
separate EFS mount, a separate S3 bucket / AWS region, and/or different post-build
semantics (this is why US is separate from SG). This is an infra-level event, not a
per-region one. The new pipeline script is ~250–470 lines over the shared lib, not a
full copy.

### Steps

1. **Copy a template.** Start from `run-tile-pipeline-us.sh` (it already supports groups +
   single regions) and rename to `run-tile-pipeline-<cluster>.sh`.

2. **Boilerplate header (keep as-is, adjust `SCRIPT_VERSION`):**
   ```bash
   set -euo pipefail
   trap '' PIPE
   readonly SCRIPT_VERSION="1.0.0-<cluster>"
   readonly SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
   readonly PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
   readonly EXPECTED_LIB_VERSION="1.0.0"
   # shellcheck source=lib/tile-pipeline-common.sh
   source "${SCRIPT_DIR}/lib/tile-pipeline-common.sh"
   [[ "${LIB_VERSION}" == "${EXPECTED_LIB_VERSION}" ]] || { echo "lib version mismatch" >&2; exit 1; }
   trap on_exit EXIT
   ```

3. **Cluster config block** — the labels/defaults that identify the cluster in logs:
   ```bash
   readonly REGION_LABEL=" (<CLUSTER>)"                 # bootstrap phase-label suffix
   readonly LOG_PREFIX="pipeline-<cluster>"             # log filename prefix
   readonly DEFAULT_S3_REGION="<aws-region>"            # e.g. eu-central-1
   readonly PIPELINE_LABEL="<CLUSTER> Pipeline "        # on_exit banner prefix
   readonly COMPLETION_LABEL="<CLUSTER> pipeline completed successfully — "
   readonly EFS_SKIP_NOTE=" (local dev / no <CLUSTER> traffic yet)"
   ```
   The actual **EFS mount** (`VALHALLA_EFS_DIR`) and **S3 bucket** (`S3_TILE_BUCKET`) are NOT
   hardcoded — they live in the cluster's `deploy/config/pipeline.<env>.conf`
   (e.g. `pipeline.prod-<cluster>.conf`). Create those conf files too.

4. **Execution order:**
   ```bash
   readonly PHASES=(phase_osm phase_build phase_extract phase_validate
                    phase_s3_sync phase_swap_latest phase_cleanup
                    geometry_mapping phase_efs_sync)
   readonly BUILD_PHASES=(phase_osm phase_build)   # subset skipped by --skip-build
   ```
   (Add `phase_block_ways` to both arrays if the cluster needs the block-ways step; then
   define that function too.)

5. **Region-shaped functions the pipeline script must define:**

   | Function | Purpose | Source to copy |
   |---|---|---|
   | `set_region_defaults` | default flags, e.g. `SKIP_GEOMETRY_MAPPING=true` | trivial |
   | `resolve_tile_layout` | region → `TILE_SUBDIR` / `OSM_FILE` / `OSM_SOURCE` / `TILE_GROUP` / `IS_GROUP` | **US** (groups + single) |
   | `phase_osm` | OSM download or group-merge | **US** (has `_acquire_group_osm`) |
   | `geometry_mapping` | post-swap traffic mapping (or no-op) | see step 6 |
   | `show_usage` | help text | copy + edit |
   | `parse_extra_flag` | cluster-only CLI flags (optional) | copy if needed |

   For **groups**, also copy `_acquire_group_osm` from the US pipeline script.

6. **Elevation & geometry mapping — decide per cluster:**
   - **No elevation:** simply **do not define** `_resolve_elevation_bbox` / `_acquire_elevation`.
     The lib's `phase_build` checks `declare -F _acquire_elevation` and skips the step when
     it's absent — nothing else to do.
   - **Optional geometry mapping (driven by traffic-data availability):** set
     `SKIP_GEOMETRY_MAPPING=true` in `set_region_defaults` (default OFF), add a
     `--with-geometry-mapping` flag via `parse_extra_flag`, and define `geometry_mapping`.
     Copy the **SG form** (reads speed-band snapshots from EFS): if no snapshot exists yet
     the job exits 3 and the pipeline **warns and continues** — safe for a cluster with no
     traffic feed yet.

7. **End the pipeline script with:**
   ```bash
   run_pipeline "$@"
   ```

8. **Verify before shipping** — see below.

### What you do NOT touch
The shared phases in `lib/tile-pipeline-common.sh`. A new cluster reuses them as-is; if one
needs changing, change it in the lib (it affects all clusters) and re-verify **every**
pipeline script, not just the one you were working on.

---

## Verifying a change

`verify-equivalence.sh` proves a lib change is behavior-preserving by diffing `--dry-run`
transcripts against a golden baseline. This is what gated the extraction itself, and it is
the check to run after any subsequent lib edit.

```bash
cd deploy/scripts

# 1. Capture the golden from the PRE-change tree (e.g. a temp worktree at the old commit)
./verify-equivalence.sh baseline

# 2. Apply your change, then:
./verify-equivalence.sh check    # exit 0 = byte-identical after normalization
```

It exercises `singapore` + `thailand` (SG single-region), `new_york` (US grouped), and
`--help` for both pipeline scripts, then normalizes the volatile fields — timestamps,
`RUN_ID`s,
durations, `find`'s locale-dependent quote style, and both `${PROJECT_ROOT}` and the sandbox
path, so a baseline captured in a throwaway worktree is comparable to the working tree.

The golden currently checked against was captured **from this branch**, post-refactor: it is
a forward regression guard, not the extraction gate. The original pre-refactor golden served
its purpose and is gone. A `check` on this branch passes all five cases; if you re-baseline,
review the transcripts before trusting them (the script prints that reminder too).

Two design points worth knowing before you extend it:

- **Every capture runs against a fresh empty sandbox.** Several dry-run lines are derived
  from the filesystem (`phase_osm`: "not found" vs "Age: N day(s)"; `phase_cleanup`:
  "Versions present: 0" vs "2"). Those are *real* branches, so normalizing them away with
  regex would mask genuine changes. Pinning the state instead means any surviving diff is
  attributable to code. The golden therefore always records the cold-cache path, which is
  also what CI sees.
- **It passes `--pipeline-config`, not env vars.** `bootstrap()` sources the conf *before*
  applying its `${VAR:-default}` fallbacks and the conf assigns `VALHALLA_TILE_DIR=`
  unconditionally, so an exported value is always clobbered. `--pipeline-config` is the
  supported override path. (Same precedence trap as `SKIP_ELEVATION`.)
- **`_norm` folds curly quotes to ASCII, and that clause must stay first.** GNU `findutils`
  quotes paths in its diagnostics per the locale — `'path'` under `LC_ALL=C` but `‘path’`
  (U+2018/U+2019) under a UTF-8 locale. `phase_cleanup` emits such a line on a cold cache,
  so without folding, identical code diffs unequal purely on the capture host's locale —
  which would make the golden non-portable to CI. Verified: `check` passes under both
  `LC_ALL=C` and `LC_ALL=en_US.UTF-8`. If you add normalization clauses, keep quote folding
  ahead of the path substitutions.

### Also run

- `bash -n` on each pipeline script + the lib, and `shellcheck` on all three. The image
  build does
  the `bash -n` pass too, but catching it locally is faster.
- One **real** (non-dry-run) build in staging before production. A dry run verifies wiring,
  not a tile build — it never invokes the builder, so it cannot catch a builder/JAR version
  skew.
- If you bumped `LIB_VERSION`, confirm every pipeline script's `EXPECTED_LIB_VERSION`
  moved with it. There are currently two pipeline scripts; missing one fails at startup,
  which is the intent.
