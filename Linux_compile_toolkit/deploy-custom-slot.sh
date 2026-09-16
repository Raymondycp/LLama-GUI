#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# deploy-custom-slot.sh
# Deploys a tarball produced by build_llama_cpp_cuda.sh into the
# Llama GUI "Custom" backend slot (llama/custom/), so the freshly
# compiled CUDA build runs without any network download.
#
# Usage:
#   ./deploy-custom-slot.sh [tarball] [slot]
#
#   tarball  Path to llama-cpp-cuda-linux-*.tar.gz. Defaults to the
#            most recent archive in dist/.
#   slot     "custom" (default) or "custom-02".
#
# The script mirrors the app's flat install: binaries and shared
# libraries land in llama/<slot>/bin/, grammars (.gbnf/.json) in
# llama/<slot>/grammars/. config.json is updated exactly like the
# app's "Activate Custom" flow, and an official install that was
# previously active is remembered so it can be restored later.
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

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

# ---- arguments ----------------------------------------------

SLOT="${2:-custom}"
case "$SLOT" in
    custom|custom-02) ;;
    *) die "Unsupported slot '$SLOT'. Expected 'custom' or 'custom-02'." ;;
esac

TARBALL="${1:-}"
if [[ -z "$TARBALL" ]]; then
    TARBALL=$(ls -1 "$SCRIPT_DIR"/dist/llama-cpp-cuda-linux-*.tar.gz 2>/dev/null | sort | tail -n1 || true)
    if [[ -z "$TARBALL" ]]; then
        die "No tarball given and none found in $SCRIPT_DIR/dist/."
    fi
fi
if [[ ! -f "$TARBALL" ]]; then
    die "Tarball not found: $TARBALL"
fi

SLOT_DIR="$REPO_ROOT/llama/$SLOT"

# ---- extraction into a staging dir --------------------------

info "Deploying $(basename "$TARBALL") into llama/$SLOT/"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
tar -xzf "$TARBALL" -C "$TMP_DIR"

SRC_BIN=""
while IFS= read -r cand; do
    if [[ -x "$cand/llama-cli" ]]; then
        SRC_BIN="$cand"
        break
    fi
done < <(find "$TMP_DIR" -type d -name bin)
if [[ -z "$SRC_BIN" ]]; then
    die "No bin/ directory containing llama-cli found inside the tarball."
fi

STAGE_BIN="$SLOT_DIR/.stage-bin"
rm -rf "$STAGE_BIN"
mkdir -p "$STAGE_BIN"
cp -a "$SRC_BIN"/. "$STAGE_BIN"/
chmod 0755 "$STAGE_BIN"/llama-cli "$STAGE_BIN"/llama-server 2>/dev/null || true

# ---- runtime probe before touching the live slot ------------

if ! env LD_LIBRARY_PATH="$STAGE_BIN${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
    "$STAGE_BIN/llama-cli" --version >/dev/null 2>&1; then
    rm -rf "$STAGE_BIN"
    die "llama-cli --version failed. The build needs CUDA drivers that are present and compatible."
fi

# ---- swap into place ----------------------------------------

BACKUP_BIN="$SLOT_DIR/bin.old"
rm -rf "$BACKUP_BIN"
if [[ -d "$SLOT_DIR/bin" ]]; then
    mv "$SLOT_DIR/bin" "$BACKUP_BIN"
fi
mv "$STAGE_BIN" "$SLOT_DIR/bin"
rm -rf "$BACKUP_BIN"
mkdir -p "$SLOT_DIR/grammars"

# ---- activate the custom backend (like the app's flow) -------

PYTHON="${PYTHON:-}"
if [[ -z "$PYTHON" ]]; then
    if [[ -x "$REPO_ROOT/.venv/bin/python" ]]; then
        PYTHON="$REPO_ROOT/.venv/bin/python"
    elif command -v python3 &>/dev/null; then
        PYTHON="$(command -v python3)"
    elif command -v python &>/dev/null; then
        PYTHON="$(command -v python)"
    else
        warn "python not found; config.json not updated. Activate the custom backend in the app instead."
        PYTHON=""
    fi
fi

if [[ -n "$PYTHON" ]]; then
    info "Activating the '$SLOT' custom backend in config.json"
    "$PYTHON" - "$REPO_ROOT/config.json" "$SLOT" <<'PY'
import json
import sys

path, slot = sys.argv[1], sys.argv[2]
try:
    with open(path, encoding="utf-8") as f:
        cfg = json.load(f)
except (OSError, ValueError):
    cfg = {}
if cfg.get("backend") and cfg.get("backend") not in ("custom", "custom-02") and cfg.get("tag"):
    cfg["official_install"] = {
        "backend": cfg["backend"],
        "tag": cfg["tag"],
        "version": cfg.get("version") or cfg["tag"],
    }
cfg["version"] = "custom"
cfg["backend"] = slot
cfg["tag"] = "custom"
with open(path, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
PY
fi

# ---- summary -------------------------------------------------

info "Done!"
echo ""
echo "  Slot:      llama/$SLOT/"
echo "  Backend:   $SLOT (config.json activated)"
echo "  Restart Llama GUI if it is running so the Status page reads the new build."
echo ""