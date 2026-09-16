#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# build_llama_cpp_cuda.sh
# Fetches/updates the latest llama.cpp source and compiles a
# portable CUDA-enabled build for Linux, then packages the
# binaries into a tar.gz.
#
# Prerequisites on the build host:
#   - git, cmake, nvcc (CUDA toolkit), nproc
#   - strip is optional; it is used to reduce binary size when available
#
# cmake and nvcc are also searched in a few common install locations that are
# not on PATH by default (e.g. ~/.local/bin for a pip --user cmake, and
# /usr/local/cuda/bin for the Ubuntu CUDA .deb toolkit).
#
# The target machine must have CUDA drivers installed.
# Shared libraries (libcudart, libcublas, etc.) are NOT bundled.
# ============================================================

REPO_URL="https://github.com/ggml-org/llama.cpp.git"
SOURCE_DIR="llama.cpp"
BUILD_DIR="build"
DIST_DIR="dist"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
PACKAGE_NAME="llama-cpp-cuda-linux-${TIMESTAMP}.tar.gz"

# ---- helpers ------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info()  { echo -e "${GREEN}==>${NC} $*"; }
warn()  { echo -e "${YELLOW}!!>${NC} $*"; }
error() { echo -e "${RED}XX>${NC} $*" >&2; }

die() {
    error "$*"
    exit 1
}

# ---- 1. prerequisite checks ---------------------------------

info "Checking prerequisites"

# Locate a required tool, probing common non-PATH install locations and
# exposing the directory that contains it before any later command -v check.
find_or_die() {
    local name="$1"
    shift
    if command -v "$name" &>/dev/null; then
        return 0
    fi
    local cand
    for cand in "$@"; do
        if [[ -x "$cand" ]]; then
            PATH="$(dirname "$cand"):$PATH"
            export PATH
            info "  $name found at $cand (not on PATH; using it)"
            return 0
        fi
    done
    return 1
}

find_or_die cmake "$HOME/.local/bin/cmake" /usr/local/bin/cmake || \
    die "'cmake' is not installed or not in PATH. Please install it before running this script."

find_or_die nvcc \
    "${CUDA_HOME:-}/bin/nvcc" \
    "${CUDA_PATH:-}/bin/nvcc" \
    /usr/local/cuda/bin/nvcc \
    /opt/cuda/bin/nvcc || \
    die "'nvcc' (NVIDIA CUDA compiler) is not installed or not in PATH. Install the CUDA toolkit before running this script."

for cmd in git; do
    if ! command -v "$cmd" &>/dev/null; then
        die "'$cmd' is not installed or not in PATH. Please install it before running this script."
    fi
done

if ! command -v nproc &>/dev/null; then
    die "'nproc' is not installed or not in PATH. Please install coreutils."
fi

CMAKE_MIN_VERSION="3.20"
CMAKE_VERSION=$(cmake --version | head -n1 | awk '{print $3}')
info "  cmake version: $CMAKE_VERSION"

# Compare versions (sort -V works on most Linux distros)
LOWER=$(printf '%s\n%s\n' "$CMAKE_MIN_VERSION" "$CMAKE_VERSION" | sort -V | head -n1)
if [[ "$LOWER" != "$CMAKE_MIN_VERSION" ]]; then
    die "CMake $CMAKE_MIN_VERSION or newer is required (found $CMAKE_VERSION)"
fi

info "  git version:   $(git --version)"
info "  nvcc version:  $(nvcc --version | tail -n1)"
if command -v strip &>/dev/null; then
    STRIP_BIN="$(command -v strip)"
    info "  strip:         $STRIP_BIN"
else
    STRIP_BIN=""
    warn "  strip is not installed; binaries will not be stripped."
fi

# ---- 2. source management -----------------------------------

info "Managing llama.cpp source"

if [[ -d "$SOURCE_DIR" ]]; then
    if [[ -d "$SOURCE_DIR/.git" ]]; then
        cd "$SOURCE_DIR"

        # Check for dirty / modified files
        if ! git diff --quiet || ! git diff --cached --quiet; then
            die "Working tree in '$SOURCE_DIR' is dirty. Please stash or discard local changes and re-run."
        fi

        info "  Updating existing repo via git pull --ff-only"
        if ! git pull --ff-only; then
            die "git pull failed. You may need to reset or re-clone manually."
        fi

        cd ..
    else
        die "Directory '$SOURCE_DIR' exists but is not a git repository. Please remove it and re-run."
    fi
else
    info "  Cloning $REPO_URL"
    git clone --depth 1 "$REPO_URL" "$SOURCE_DIR"
fi

cd "$SOURCE_DIR"

# ---- 3. build configuration ---------------------------------

info "Configuring CMake (portable CUDA build)"

cmake -B "$BUILD_DIR" \
    -DGGML_CUDA=ON \
    -DGGML_NATIVE=OFF \
    -DCMAKE_BUILD_TYPE=Release

# ---- 4. compilation -----------------------------------------

info "Compiling (this may take several minutes)"

PARALLEL_JOBS=$(nproc)
cmake --build "$BUILD_DIR" --config Release -j "$PARALLEL_JOBS"

# ---- 5. strip binaries --------------------------------------

info "Stripping release binaries"

BIN_DIR="$BUILD_DIR/bin"
if [[ -n "$STRIP_BIN" && -d "$BIN_DIR" ]]; then
    find "$BIN_DIR" -maxdepth 1 -type f -executable -print0 | while IFS= read -r -d '' binary; do
        "$STRIP_BIN" "$binary" 2>/dev/null || true
    done
elif [[ -z "$STRIP_BIN" ]]; then
    warn "Skipping strip step because 'strip' is not available."
fi

# ---- 6. verification ----------------------------------------

info "Verifying build artifacts"

REQUIRED_BINS=("llama-cli" "llama-server" "llama-quantize")
MISSING=()

for bin in "${REQUIRED_BINS[@]}"; do
    if [[ ! -f "$BIN_DIR/$bin" ]]; then
        MISSING+=("$bin")
    fi
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
    die "Build verification failed - missing binaries: ${MISSING[*]}"
fi

info "  Build successful!"

# ---- 7. packaging -------------------------------------------

info "Packaging binaries"

mkdir -p "../$DIST_DIR"
STAGE_DIR="../$DIST_DIR/llama-cpp-cuda-linux-${TIMESTAMP}"
mkdir -p "$STAGE_DIR/bin"

# Copy all executables from the build bin directory
cp -a "$BIN_DIR/"* "$STAGE_DIR/bin/"

# Create tarball
cd "../$DIST_DIR"
tar -czf "$PACKAGE_NAME" "$(basename "$STAGE_DIR")"

# Clean up stage directory
rm -rf "$(basename "$STAGE_DIR")"

# ---- 8. summary ---------------------------------------------

info "Done!"
echo ""
echo "  Package: $(pwd)/$PACKAGE_NAME"
echo "  Size:    $(du -h "$PACKAGE_NAME" | cut -f1)"
echo ""
echo "  To use on a target Linux machine with CUDA drivers:"
echo "    tar -xzf $PACKAGE_NAME"
echo "    cd llama-cpp-cuda-linux-${TIMESTAMP}/bin"
echo "    ./llama-cli --help"
echo ""
