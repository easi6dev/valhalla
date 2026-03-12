#!/usr/bin/env bash
# =============================================================================
# build-tilebuilder-image.sh — Build and optionally push the Valhalla
#                               tile-builder Docker image from source.
# =============================================================================
# Produces an image containing valhalla_build_tiles + valhalla_build_admins
# compiled from this repo, so local C++ changes (e.g. adminbuilder.cc) are
# included. Use this image instead of ghcr.io/valhalla/valhalla:latest in
# your pipeline config.
#
# Usage:
#   ./scripts/build-tilebuilder-image.sh [OPTIONS]
#
# Options:
#   --tag <tag>          Image tag (default: valhalla-tilebuilder:local)
#   --registry <url>     GHCR registry prefix, e.g. ghcr.io/your-org
#                        Combined with --tag: ghcr.io/your-org/valhalla-tilebuilder:local
#   --push               Push image to registry after build (requires --registry)
#   --no-cache           Build without Docker layer cache
#   --concurrency <n>    Parallel make jobs inside Docker (default: auto)
#   -y, --yes            Skip confirmation prompts
#   -h, --help           Show this help
#
# Examples:
#   # Local dev — build only, no push
#   ./scripts/build-tilebuilder-image.sh
#
#   # Tag with git commit hash for traceability
#   ./scripts/build-tilebuilder-image.sh --tag valhalla-tilebuilder:$(git rev-parse --short HEAD)
#
#   # Build and push to GHCR (CI/CD)
#   ./scripts/build-tilebuilder-image.sh \
#     --registry ghcr.io/your-org \
#     --tag valhalla-tilebuilder:latest \
#     --push --yes
#
#   # After building locally, update dev pipeline config and run pipeline:
#   VALHALLA_ENV=dev ./deploy/scripts/run-tile-pipeline.sh singapore
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Paths
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DOCKERFILE="${REPO_ROOT}/docker/Dockerfile.tilebuilder"

# -----------------------------------------------------------------------------
# Colour helpers
# -----------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()    { echo -e "$*"; }
ok()     { log "${GREEN}  [✓]${NC} $*"; }
info()   { log "${YELLOW}  [i]${NC} $*"; }
step()   { log "${CYAN}  [→]${NC} $*"; }
err()    { log "${RED}  [✗]${NC} $*" >&2; }
header() { log "\n${CYAN}${BOLD}══════════════════════════════════════════${NC}"; \
           log "${CYAN}${BOLD}  $*${NC}"; \
           log "${CYAN}${BOLD}══════════════════════════════════════════${NC}"; }
die()    { err "$*"; exit 1; }

# -----------------------------------------------------------------------------
# Defaults
# -----------------------------------------------------------------------------
DEFAULT_TAG="valhalla-tilebuilder:local"
IMAGE_TAG="${DEFAULT_TAG}"
REGISTRY=""
PUSH=false
NO_CACHE=false
CONCURRENCY=""
AUTO_YES=false
BUILD_START=$(date +%s)

# -----------------------------------------------------------------------------
# Parse arguments
# -----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --tag)          IMAGE_TAG="$2";    shift 2 ;;
        --registry)     REGISTRY="$2";    shift 2 ;;
        --push)         PUSH=true;         shift   ;;
        --no-cache)     NO_CACHE=true;     shift   ;;
        --concurrency)  CONCURRENCY="$2"; shift 2 ;;
        -y|--yes)       AUTO_YES=true;     shift   ;;
        -h|--help)
            sed -n '3,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) die "Unknown option: $1. Use --help for usage." ;;
    esac
done

# If registry given, prefix the tag with it
if [[ -n "${REGISTRY}" ]]; then
    # Strip trailing slash from registry
    REGISTRY="${REGISTRY%/}"
    # If tag already contains a slash (i.e. user gave full path), use as-is
    if [[ "${IMAGE_TAG}" != */* ]]; then
        IMAGE_TAG="${REGISTRY}/${IMAGE_TAG}"
    fi
fi

# Convenience: also derive an GHCR-compatible latest tag when a registry is set
LATEST_TAG=""
if [[ -n "${REGISTRY}" ]]; then
    IMAGE_NAME="${IMAGE_TAG%%:*}"   # everything before the colon
    LATEST_TAG="${IMAGE_NAME}:latest"
fi

elapsed() {
    local secs=$(( $(date +%s) - BUILD_START ))
    printf "%dm %02ds" $(( secs/60 )) $(( secs%60 ))
}

confirm() {
    local prompt="$1"
    if [[ "${AUTO_YES}" == true ]]; then
        info "${prompt} → auto-yes"
        return 0
    fi
    echo -e "${YELLOW}  ${prompt} [Y/n]: ${NC}" >/dev/tty
    read -r response </dev/tty
    [[ -z "${response}" || "${response}" =~ ^[Yy]$ ]]
}

# -----------------------------------------------------------------------------
# Header
# -----------------------------------------------------------------------------
header "Valhalla Tile Builder — Docker Image Build"
info "Repo root  : ${REPO_ROOT}"
info "Dockerfile : ${DOCKERFILE}"
info "Image tag  : ${IMAGE_TAG}"
[[ -n "${LATEST_TAG}" ]] && info "Latest tag : ${LATEST_TAG}"
info "Push       : ${PUSH}"
info "No-cache   : ${NO_CACHE}"

# -----------------------------------------------------------------------------
# Prerequisite checks
# -----------------------------------------------------------------------------
header "Checking prerequisites"

[[ -f "${DOCKERFILE}" ]] || die "Dockerfile not found: ${DOCKERFILE}"
ok "Dockerfile found"

command -v docker &>/dev/null || die "Docker not found. Install Docker Desktop or Docker Engine."
ok "Docker found: $(docker --version)"

# Check Docker daemon is running
docker info &>/dev/null || die "Docker daemon is not running. Start Docker first."
ok "Docker daemon is running"

# If pushing, verify registry login
if [[ "${PUSH}" == true ]]; then
    [[ -n "${REGISTRY}" ]] || die "--push requires --registry to be set."
    step "Verifying registry login for ${REGISTRY}..."
    if ! docker login "${REGISTRY}" --username "${GITHUB_ACTOR:-}" --password-stdin \
            <<< "${GITHUB_TOKEN:-}" 2>/dev/null; then
        # docker login failure is non-fatal here — warn and let push fail naturally
        info "docker login returned non-zero (token may not be set yet — will try anyway)"
    else
        ok "Registry login OK"
    fi
fi

# Show what will be included in the build context
info "Git commit : $(git -C "${REPO_ROOT}" rev-parse --short HEAD 2>/dev/null || echo 'unknown')"
info "Dirty files: $(git -C "${REPO_ROOT}" status --porcelain 2>/dev/null | wc -l | tr -d ' ') modified"

echo ""
if ! confirm "Build Docker image '${IMAGE_TAG}' now?"; then
    info "Cancelled."
    exit 0
fi

# -----------------------------------------------------------------------------
# Build
# -----------------------------------------------------------------------------
header "Building Docker image"

DOCKER_BUILD_ARGS=(
    docker build
    --file "${DOCKERFILE}"
    --tag  "${IMAGE_TAG}"
)

[[ -n "${LATEST_TAG}" ]] && DOCKER_BUILD_ARGS+=(--tag "${LATEST_TAG}")
[[ "${NO_CACHE}" == true ]] && DOCKER_BUILD_ARGS+=(--no-cache)
[[ -n "${CONCURRENCY}" ]] && DOCKER_BUILD_ARGS+=(--build-arg "CONCURRENCY=${CONCURRENCY}")

# Add git commit as a label for traceability
GIT_COMMIT=$(git -C "${REPO_ROOT}" rev-parse HEAD 2>/dev/null || echo "unknown")
DOCKER_BUILD_ARGS+=(--label "org.opencontainers.image.revision=${GIT_COMMIT}")
DOCKER_BUILD_ARGS+=(--label "org.opencontainers.image.created=$(date -u +%Y-%m-%dT%H:%M:%SZ)")
DOCKER_BUILD_ARGS+=(--label "org.opencontainers.image.source=local-build")

# Context is repo root so all COPY directives in Dockerfile resolve correctly
DOCKER_BUILD_ARGS+=("${REPO_ROOT}")

step "Running: ${DOCKER_BUILD_ARGS[*]}"
echo ""

"${DOCKER_BUILD_ARGS[@]}"

ok "Image built successfully (elapsed: $(elapsed))"

# -----------------------------------------------------------------------------
# Verify built image
# -----------------------------------------------------------------------------
header "Verifying built image"

step "Running valhalla_build_tiles --version inside image..."
TILES_VER=$(docker run --rm "${IMAGE_TAG}" valhalla_build_tiles --version 2>&1 | head -1 || true)
if [[ -n "${TILES_VER}" ]]; then
    ok "valhalla_build_tiles: ${TILES_VER}"
else
    err "valhalla_build_tiles --version produced no output"
    die "Image verification failed. Check build output above."
fi

step "Running valhalla_build_admins --version inside image..."
ADMINS_VER=$(docker run --rm "${IMAGE_TAG}" valhalla_build_admins --version 2>&1 | head -1 || true)
if [[ -n "${ADMINS_VER}" ]]; then
    ok "valhalla_build_admins: ${ADMINS_VER}"
else
    err "valhalla_build_admins --version produced no output"
    die "Image verification failed."
fi

ok "Image verification passed"

# -----------------------------------------------------------------------------
# Push (optional)
# -----------------------------------------------------------------------------
if [[ "${PUSH}" == true ]]; then
    header "Pushing to registry"

    step "Pushing ${IMAGE_TAG}..."
    docker push "${IMAGE_TAG}"
    ok "Pushed: ${IMAGE_TAG}"

    if [[ -n "${LATEST_TAG}" ]]; then
        step "Pushing ${LATEST_TAG}..."
        docker push "${LATEST_TAG}"
        ok "Pushed: ${LATEST_TAG}"
    fi
fi

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
header "Done"
ok "Image : ${IMAGE_TAG}"
[[ -n "${LATEST_TAG}" ]] && ok "Latest: ${LATEST_TAG}"
ok "Time  : $(elapsed)"
echo ""
info "Next steps:"
echo ""
echo "  1. Update your pipeline config to use this image:"
echo "       VALHALLA_DOCKER_IMAGE=${IMAGE_TAG}"
echo ""
echo "  2. Run a dev tile pipeline build:"
echo "       VALHALLA_ENV=dev ./deploy/scripts/run-tile-pipeline.sh singapore --dry-run"
echo "       VALHALLA_ENV=dev ./deploy/scripts/run-tile-pipeline.sh singapore"
echo ""
if [[ "${PUSH}" == false && -n "${REGISTRY}" ]]; then
    echo "  3. Push to GHCR when ready:"
    echo "       ./scripts/build-tilebuilder-image.sh \\"
    echo "         --registry ${REGISTRY} \\"
    echo "         --tag ${IMAGE_TAG##*/} \\"
    echo "         --push --yes"
    echo ""
fi
if [[ "${PUSH}" == true ]]; then
    echo "  3. Update staging/prod pipeline config (via SSM or secrets manager):"
    echo "       VALHALLA_DOCKER_IMAGE=${IMAGE_TAG}"
    echo ""
fi
