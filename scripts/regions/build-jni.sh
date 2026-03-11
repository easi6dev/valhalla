#!/usr/bin/env bash
# =============================================================================
# build-jni.sh  —  Interactive build script for Valhalla JNI bindings
# =============================================================================
# Executes Path B (local Linux build) end-to-end:
#
#   Step 1 — Verify prerequisites (cmake, java, protoc, gradle)
#   Step 2 — Build Valhalla core  (cmake -B build … -DENABLE_JAVA_BINDINGS=ON)
#   Step 3 — Prepare .so resources (versioned copies for JAR classloader)
#   Step 4 — Copy libprotobuf-lite.so from system
#   Step 5 — Generate protobuf headers
#   Step 6 — Build libvalhalla_jni.so via CMake
#   Step 7 — Copy libvalhalla_jni.so into JAR resources
#   Step 8 — Build the Gradle JAR  (-x buildNative -x test)
#   Step 9 — Verify JAR contents
#
# Usage:
#   chmod +x scripts/build-jni.sh
#   ./scripts/build-jni.sh            # full interactive build
#   ./scripts/build-jni.sh --skip-valhalla    # skip Step 2 (core already built)
#   ./scripts/build-jni.sh --skip-cmake       # skip Steps 2+6 (both .so already present)
#   ./scripts/build-jni.sh --yes              # answer "yes" to all prompts
#   ./scripts/build-jni.sh --help
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Resolve canonical paths — works regardless of where the script is invoked from
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
JNI_DIR="${REPO_ROOT}/src/bindings/java"
RESOURCES_LINUX="${JNI_DIR}/src/main/resources/lib/linux-amd64"
LOG_DIR="${REPO_ROOT}/logs"
LOG_FILE="${LOG_DIR}/build-jni-$(date +%Y%m%d-%H%M%S).log"
NPROC=$(nproc 2>/dev/null || echo 4)

# -----------------------------------------------------------------------------
# Colour helpers
# -----------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

log()     { echo -e "$*" | tee -a "${LOG_FILE}"; }
header()  { log "\n${CYAN}${BOLD}══════════════════════════════════════════════════${NC}"; \
            log "${CYAN}${BOLD}  $*${NC}"; \
            log "${CYAN}${BOLD}══════════════════════════════════════════════════${NC}"; }
ok()      { log "${GREEN}  [✓]${NC} $*"; }
info()    { log "${YELLOW}  [i]${NC} $*"; }
step()    { log "${BLUE}  [→]${NC} $*"; }
err()     { log "${RED}  [✗]${NC} $*" >&2; }
die()     { err "$*"; exit 1; }

elapsed() {
    local secs=$(( $(date +%s) - BUILD_START ))
    printf "%dm %02ds" $(( secs/60 )) $(( secs%60 ))
}

# -----------------------------------------------------------------------------
# Flags
# -----------------------------------------------------------------------------
SKIP_VALHALLA=false
SKIP_CMAKE=false
AUTO_YES=false

for arg in "$@"; do
    case "${arg}" in
        --skip-valhalla) SKIP_VALHALLA=true ;;
        --skip-cmake)    SKIP_CMAKE=true; SKIP_VALHALLA=true ;;
        --yes|-y)        AUTO_YES=true ;;
        --help|-h)
            sed -n '3,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) die "Unknown option: ${arg}. Use --help for usage." ;;
    esac
done

# -----------------------------------------------------------------------------
# Prompt helper — respects --yes flag
# -----------------------------------------------------------------------------
confirm() {
    local prompt="$1"
    if [[ "${AUTO_YES}" == true ]]; then
        info "${prompt} → auto-yes"
        return 0
    fi
    echo -e "${YELLOW}${prompt} [Y/n]: ${NC}" >/dev/tty
    read -r response </dev/tty
    [[ -z "${response}" || "${response}" =~ ^[Yy]$ ]]
}

# -----------------------------------------------------------------------------
# Trap — print log path on exit
# -----------------------------------------------------------------------------
BUILD_START=$(date +%s)
mkdir -p "${LOG_DIR}"
trap 'echo -e "\n${YELLOW}Full log: ${LOG_FILE}${NC}"' EXIT

# =============================================================================
# HEADER
# =============================================================================
header "Valhalla JNI Build Script"
info "Repo root : ${REPO_ROOT}"
info "JNI dir   : ${JNI_DIR}"
info "Resources : ${RESOURCES_LINUX}"
info "Log file  : ${LOG_FILE}"
info "CPUs      : ${NPROC}"
info "Flags     : skip-valhalla=${SKIP_VALHALLA}  skip-cmake=${SKIP_CMAKE}  auto-yes=${AUTO_YES}"

# =============================================================================
# STEP 1 — Verify prerequisites
# =============================================================================
header "Step 1 — Checking prerequisites"

check_cmd() {
    local cmd="$1" pkg="${2:-$1}"
    if command -v "${cmd}" &>/dev/null; then
        ok "${cmd} found: $(${cmd} --version 2>&1 | head -1)"
    else
        err "${cmd} not found"
        info "Install with: sudo apt-get install ${pkg}"
        return 1
    fi
}

PREREQ_OK=true
check_cmd cmake   cmake         || PREREQ_OK=false
check_cmd java    openjdk-17-jdk || PREREQ_OK=false
check_cmd protoc  protobuf-compiler || PREREQ_OK=false

# Java version check (require 17+)
if command -v java &>/dev/null; then
    JAVA_VER=$(java -version 2>&1 | awk -F'"' '/version/{print $2}' | cut -d'.' -f1)
    if [[ "${JAVA_VER}" -lt 17 ]]; then
        err "Java 17+ required (found Java ${JAVA_VER})"
        PREREQ_OK=false
    else
        ok "Java version: ${JAVA_VER}"
    fi
fi

# Check JAVA_HOME — CMake find_package(JNI) needs it
if [[ -z "${JAVA_HOME:-}" ]]; then
    JAVA_HOME=$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")
    export JAVA_HOME
    info "JAVA_HOME auto-detected: ${JAVA_HOME}"
else
    ok "JAVA_HOME: ${JAVA_HOME}"
fi

# Gradle wrapper
if [[ -f "${JNI_DIR}/gradlew" ]]; then
    ok "gradlew found"
else
    err "gradlew not found in ${JNI_DIR}"
    PREREQ_OK=false
fi

# libprotobuf-lite.so on this system
PROTOBUF_LIB=$(ls /usr/lib/x86_64-linux-gnu/libprotobuf-lite.so.[0-9]* 2>/dev/null \
               | head -1 || true)
if [[ -n "${PROTOBUF_LIB}" ]]; then
    ok "libprotobuf-lite found: ${PROTOBUF_LIB}"
else
    err "libprotobuf-lite.so.* not found in /usr/lib/x86_64-linux-gnu/"
    info "Install with: sudo apt-get install libprotobuf-dev"
    PREREQ_OK=false
fi

[[ "${PREREQ_OK}" == true ]] || die "Fix missing prerequisites then re-run."
ok "All prerequisites satisfied"

# =============================================================================
# STEP 2 — Build Valhalla core (libvalhalla.so)
# =============================================================================
header "Step 2 — Build Valhalla core (libvalhalla.so)"

VALHALLA_BUILD_DIR="${REPO_ROOT}/build"
VALHALLA_SO_BUILT=""

find_built_libvalhalla() {
    # Check cmake build dir first, then installed location
    for candidate in \
        "${VALHALLA_BUILD_DIR}/src/libvalhalla.so.3"* \
        "${VALHALLA_BUILD_DIR}/src/libvalhalla.so"* \
        /usr/local/lib/libvalhalla.so.3 \
        /usr/lib/libvalhalla.so.3; do
        if [[ -f "${candidate}" ]]; then
            echo "${candidate}"
            return 0
        fi
    done
    # Glob for versioned name
    local found
    found=$(ls "${VALHALLA_BUILD_DIR}/src/libvalhalla.so."* 2>/dev/null | head -1 || true)
    [[ -n "${found}" ]] && echo "${found}"
}

if [[ "${SKIP_VALHALLA}" == true ]]; then
    info "--skip-valhalla: skipping Valhalla core build"
    VALHALLA_SO_BUILT=$(find_built_libvalhalla || true)
    if [[ -z "${VALHALLA_SO_BUILT}" ]]; then
        # Fall back to what's already in resources
        VALHALLA_SO_BUILT=$(ls "${RESOURCES_LINUX}/libvalhalla.so."* 2>/dev/null | head -1 || true)
        [[ -n "${VALHALLA_SO_BUILT}" ]] && info "Using existing resource: ${VALHALLA_SO_BUILT}"
    fi
    [[ -n "${VALHALLA_SO_BUILT}" ]] || die "No libvalhalla.so found. Remove --skip-valhalla to build it."
    ok "libvalhalla.so: ${VALHALLA_SO_BUILT}"
else
    # Check if already built and ask user
    EXISTING_SO=$(find_built_libvalhalla || true)
    if [[ -n "${EXISTING_SO}" ]]; then
        info "Existing libvalhalla.so found: ${EXISTING_SO}"
        if ! confirm "Rebuild Valhalla core? (takes several minutes)"; then
            ok "Using existing build"
            VALHALLA_SO_BUILT="${EXISTING_SO}"
        fi
    fi

    if [[ -z "${VALHALLA_SO_BUILT:-}" ]]; then
        step "Configuring Valhalla with CMake..."
        info "cmake -B build -DCMAKE_BUILD_TYPE=Release -DENABLE_JAVA_BINDINGS=ON \\"
        info "      -DENABLE_TESTS=OFF -DENABLE_PYTHON_BINDINGS=OFF -DENABLE_NODE_BINDINGS=OFF"

        cmake -B "${VALHALLA_BUILD_DIR}" \
            -DCMAKE_BUILD_TYPE=Release \
            -DENABLE_JAVA_BINDINGS=ON \
            -DENABLE_TESTS=OFF \
            -DENABLE_PYTHON_BINDINGS=OFF \
            -DENABLE_NODE_BINDINGS=OFF \
            -S "${REPO_ROOT}" \
            2>&1 | tee -a "${LOG_FILE}"

        ok "CMake configure complete"

        step "Building Valhalla core with ${NPROC} parallel jobs..."
        info "cmake --build build --config Release -j${NPROC}"

        cmake --build "${VALHALLA_BUILD_DIR}" --config Release -j"${NPROC}" \
            2>&1 | tee -a "${LOG_FILE}"

        VALHALLA_SO_BUILT=$(find_built_libvalhalla || true)
        [[ -n "${VALHALLA_SO_BUILT}" ]] || die "CMake build succeeded but libvalhalla.so not found. Check ${LOG_FILE}"

        ok "Valhalla core built: ${VALHALLA_SO_BUILT} (elapsed: $(elapsed))"
    fi
fi

# =============================================================================
# STEP 3 — Prepare .so resource files (versioned copies)
# =============================================================================
header "Step 3 — Prepare .so resource files"

info "Resources dir: ${RESOURCES_LINUX}"
ls -lh "${RESOURCES_LINUX}/" | tee -a "${LOG_FILE}" || true

# Ensure the versioned base file is in resources
RESOURCE_VERSIONED=$(ls "${RESOURCES_LINUX}/libvalhalla.so."* 2>/dev/null | head -1 || true)

if [[ -z "${RESOURCE_VERSIONED}" ]]; then
    step "Copying ${VALHALLA_SO_BUILT} → resources..."
    cp "${VALHALLA_SO_BUILT}" "${RESOURCES_LINUX}/"
    RESOURCE_VERSIONED="${RESOURCES_LINUX}/$(basename "${VALHALLA_SO_BUILT}")"
    ok "Copied: ${RESOURCE_VERSIONED}"
else
    ok "Versioned libvalhalla.so found: ${RESOURCE_VERSIONED}"
fi

# Create .so.3 if missing
if [[ ! -f "${RESOURCES_LINUX}/libvalhalla.so.3" ]]; then
    step "Creating libvalhalla.so.3 (copy of $(basename "${RESOURCE_VERSIONED}"))..."
    cp "${RESOURCE_VERSIONED}" "${RESOURCES_LINUX}/libvalhalla.so.3"
    ok "Created: ${RESOURCES_LINUX}/libvalhalla.so.3"
else
    ok "libvalhalla.so.3 already present"
fi

# Create bare .so if missing (needed by findVersionedLib fallback)
if [[ ! -f "${RESOURCES_LINUX}/libvalhalla.so" ]]; then
    step "Creating libvalhalla.so (copy of $(basename "${RESOURCE_VERSIONED}"))..."
    cp "${RESOURCE_VERSIONED}" "${RESOURCES_LINUX}/libvalhalla.so"
    ok "Created: ${RESOURCES_LINUX}/libvalhalla.so"
else
    ok "libvalhalla.so already present"
fi

info "Resources after Step 3:"
ls -lh "${RESOURCES_LINUX}/" | tee -a "${LOG_FILE}"

# =============================================================================
# STEP 4 — Copy libprotobuf-lite.so from system
# =============================================================================
header "Step 4 — Copy libprotobuf-lite.so from system"

PROTOBUF_DEST_NAME="$(basename "${PROTOBUF_LIB}")"
PROTOBUF_DEST="${RESOURCES_LINUX}/${PROTOBUF_DEST_NAME}"

if [[ -f "${PROTOBUF_DEST}" ]]; then
    ok "Already present: ${PROTOBUF_DEST}"
else
    step "Copying ${PROTOBUF_LIB} → ${RESOURCES_LINUX}/"
    cp "${PROTOBUF_LIB}" "${RESOURCES_LINUX}/"
    ok "Copied: ${PROTOBUF_DEST}"
fi

# =============================================================================
# STEP 5 — Generate protobuf headers
# =============================================================================
header "Step 5 — Generate protobuf headers"

PROTO_OUT="${REPO_ROOT}/build/src/valhalla/proto"
PROTO_SRC="${REPO_ROOT}/proto"

if [[ -d "${PROTO_OUT}" ]] && [[ -n "$(ls -A "${PROTO_OUT}" 2>/dev/null)" ]]; then
    ok "Proto headers already generated: ${PROTO_OUT}"
    if confirm "Re-generate protobuf headers?"; then
        rm -rf "${PROTO_OUT}"
    fi
fi

if [[ ! -d "${PROTO_OUT}" ]] || [[ -z "$(ls -A "${PROTO_OUT}" 2>/dev/null)" ]]; then
    mkdir -p "${PROTO_OUT}"
    step "Running protoc on $(ls "${PROTO_SRC}"/*.proto 2>/dev/null | wc -l) .proto files..."
    protoc \
        --proto_path="${PROTO_SRC}" \
        --cpp_out="${PROTO_OUT}" \
        "${PROTO_SRC}"/*.proto \
        2>&1 | tee -a "${LOG_FILE}"
    ok "Protobuf headers generated: ${PROTO_OUT}"
    info "Files: $(ls "${PROTO_OUT}" | head -5 | tr '\n' '  ')..."
fi

# =============================================================================
# STEP 6 — Build libvalhalla_jni.so with CMake
# =============================================================================
header "Step 6 — Build libvalhalla_jni.so"

JNI_CMAKE_BUILD="${JNI_DIR}/build"
JNI_SO_OUTPUT="${JNI_CMAKE_BUILD}/libs/native/libvalhalla_jni.so"

if [[ "${SKIP_CMAKE}" == true ]]; then
    info "--skip-cmake: skipping JNI CMake build"
    [[ -f "${JNI_SO_OUTPUT}" ]] || [[ -f "${RESOURCES_LINUX}/libvalhalla_jni.so" ]] \
        || die "libvalhalla_jni.so not found. Remove --skip-cmake to build it."
    [[ -f "${JNI_SO_OUTPUT}" ]] && ok "Existing JNI .so: ${JNI_SO_OUTPUT}"
else
    if [[ -f "${JNI_SO_OUTPUT}" ]]; then
        info "Existing libvalhalla_jni.so found: ${JNI_SO_OUTPUT}"
        if ! confirm "Rebuild libvalhalla_jni.so?"; then
            ok "Using existing JNI library"
        else
            rm -rf "${JNI_CMAKE_BUILD}"
        fi
    fi

    if [[ ! -f "${JNI_SO_OUTPUT}" ]]; then
        step "Configuring JNI CMake build..."
        info "cmake -B build -S . -DCMAKE_BUILD_TYPE=Release -DVALHALLA_SOURCE_DIR=${REPO_ROOT}"

        cmake -B "${JNI_CMAKE_BUILD}" \
            -S "${JNI_DIR}" \
            -DCMAKE_BUILD_TYPE=Release \
            -DVALHALLA_SOURCE_DIR="${REPO_ROOT}" \
            2>&1 | tee -a "${LOG_FILE}"

        ok "JNI CMake configure complete"

        step "Building libvalhalla_jni.so with ${NPROC} parallel jobs..."
        info "cmake --build build --config Release -j${NPROC}"

        cmake --build "${JNI_CMAKE_BUILD}" --config Release -j"${NPROC}" \
            2>&1 | tee -a "${LOG_FILE}"

        [[ -f "${JNI_SO_OUTPUT}" ]] \
            || die "Build completed but ${JNI_SO_OUTPUT} not found. Check ${LOG_FILE}"

        ok "libvalhalla_jni.so built (elapsed: $(elapsed))"
        info "Size: $(du -h "${JNI_SO_OUTPUT}" | cut -f1)"
    fi
fi

# =============================================================================
# STEP 7 — Copy libvalhalla_jni.so into JAR resources
# =============================================================================
header "Step 7 — Copy libvalhalla_jni.so into resources"

JNI_SO_SRC="${JNI_SO_OUTPUT}"
# If --skip-cmake and output doesn't exist, it's already in resources
if [[ ! -f "${JNI_SO_SRC}" ]]; then
    JNI_SO_SRC=""
fi

if [[ -n "${JNI_SO_SRC}" ]]; then
    step "Copying ${JNI_SO_SRC} → ${RESOURCES_LINUX}/libvalhalla_jni.so"
    cp "${JNI_SO_SRC}" "${RESOURCES_LINUX}/libvalhalla_jni.so"
    ok "Copied libvalhalla_jni.so"
else
    [[ -f "${RESOURCES_LINUX}/libvalhalla_jni.so" ]] \
        && ok "libvalhalla_jni.so already in resources" \
        || die "libvalhalla_jni.so missing from both build output and resources"
fi

info "Final resources:"
ls -lh "${RESOURCES_LINUX}/" | tee -a "${LOG_FILE}"

# =============================================================================
# STEP 8 — Build the Gradle JAR
# =============================================================================
header "Step 8 — Build Gradle JAR"

step "Running ./gradlew clean build -x buildNative -x test"
info "Working dir: ${JNI_DIR}"

cd "${JNI_DIR}"
chmod +x gradlew

./gradlew clean build -x buildNative -x test \
    2>&1 | tee -a "${LOG_FILE}"

ok "Gradle build complete (elapsed: $(elapsed))"

# Find the JAR
JAR_FILE=$(ls "${JNI_DIR}/build/libs/"*valhalla*.jar 2>/dev/null \
           | grep -v 'javadoc\|sources' | head -1 || true)

[[ -n "${JAR_FILE}" ]] || die "JAR not found in ${JNI_DIR}/build/libs/. Check ${LOG_FILE}"
ok "JAR created: ${JAR_FILE}"
info "JAR size: $(du -h "${JAR_FILE}" | cut -f1)"

# =============================================================================
# STEP 9 — Verify JAR contents
# =============================================================================
header "Step 9 — Verify JAR contents"

step "Checking bundled native libraries..."
JAR_LIBS=$(unzip -l "${JAR_FILE}" 2>/dev/null | grep -E "\.(so|dll|dylib)" || true)

if [[ -z "${JAR_LIBS}" ]]; then
    die "No native libraries found inside the JAR. Something went wrong with processResources."
fi

log "${JAR_LIBS}"

# Check required Linux entries (must match Actor.kt getRequiredLibraries() load order)
REQUIRED=(
    "lib/linux-amd64/libvalhalla_jni.so"
    "lib/linux-amd64/libvalhalla.so"
    "lib/linux-amd64/libvalhalla.so.3"
)
MISSING=()
for entry in "${REQUIRED[@]}"; do
    if echo "${JAR_LIBS}" | grep -q "${entry}"; then
        ok "  present: ${entry}"
    else
        err "  MISSING: ${entry}"
        MISSING+=("${entry}")
    fi
done

# libprotobuf-lite.so.* — Actor.kt loads this first; exact version varies by system
PROTOBUF_IN_JAR=$(echo "${JAR_LIBS}" | grep -E "lib/linux-amd64/libprotobuf-lite\.so\." || true)
if [[ -n "${PROTOBUF_IN_JAR}" ]]; then
    ok "  present: $(echo "${PROTOBUF_IN_JAR}" | awk '{print $NF}' | head -1)"
else
    err "  MISSING: lib/linux-amd64/libprotobuf-lite.so.* (required for Linux load order)"
    MISSING+=("lib/linux-amd64/libprotobuf-lite.so.*")
fi

# Check Windows DLLs are present (build may target multi-platform JARs)
WIN_REQUIRED=(
    "lib/win32-x86-64/zlib1.dll"
    "lib/win32-x86-64/lz4.dll"
    "lib/win32-x86-64/libcurl.dll"
    "lib/win32-x86-64/abseil_dll.dll"
    "lib/win32-x86-64/libprotobuf-lite.dll"
    "lib/win32-x86-64/valhalla_jni.dll"
)
WIN_MISSING=0
for entry in "${WIN_REQUIRED[@]}"; do
    if echo "${JAR_LIBS}" | grep -q "${entry}"; then
        ok "  present: ${entry}"
    else
        info "  absent : ${entry} (Windows DLL — skip if Linux-only build)"
        (( WIN_MISSING++ )) || true
    fi
done
[[ ${WIN_MISSING} -gt 0 ]] && info "${WIN_MISSING} Windows DLL(s) absent — expected for Linux-only builds"

if [[ ${#MISSING[@]} -gt 0 ]]; then
    err "JAR is missing ${#MISSING[@]} required native librar(y|ies)."
    die "Re-run without --skip-cmake flags to rebuild from scratch."
fi

# =============================================================================
# SUMMARY
# =============================================================================
header "Build Complete"
ok "JAR : ${JAR_FILE}"
ok "Log : ${LOG_FILE}"
ok "Time: $(elapsed)"
echo ""
info "Next steps:"
echo "  1. Run JNI tests:"
echo "       cd ${JNI_DIR} && ./gradlew test"
echo ""
echo "  2. Publish to local Maven:"
echo "       cd ${JNI_DIR} && ./gradlew publishToMavenLocal"
echo ""
echo "  3. Use in another Gradle project:"
echo "       implementation(files(\"${JAR_FILE}\"))"
echo ""
