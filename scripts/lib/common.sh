#!/usr/bin/env bash
# ============================================================================
# Shared environment and helpers (sourced by every stage script; never executed
# directly)
#
# Convention: every variable that can be overridden on the command line gets
# its default here; stage scripts only read them. scripts/build.sh parses the
# arguments and exports them.
# ============================================================================
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# ---------------------------------------------------------------- configuration
# shellcheck source=../../config/defaults.sh
source "$REPO_ROOT/config/defaults.sh"
# shellcheck source=../../config/gpu-targets.sh
source "$REPO_ROOT/config/gpu-targets.sh"
# shellcheck source=../../config/sources.sh
source "$REPO_ROOT/config/sources.sh"
# shellcheck source=gpu.sh
source "$REPO_ROOT/scripts/lib/gpu.sh"
# shellcheck source=patch.sh
source "$REPO_ROOT/scripts/lib/patch.sh"

# ---------------------------------------------------------------- run parameters
WORK_DIR="${WORK_DIR:-$REPO_ROOT/work}"
ARCH="${ARCH:-$(uname -m)}"
GPU_ID="${GPU_ID:-$DEFAULT_GPU}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
PROXY_MODE="${PROXY_MODE:-auto}"     # cn | direct | auto
PROXY="${PROXY:-}"                   # 1|0 after resolve_proxy
DRY_RUN="${DRY_RUN:-0}"
BUILD_TYPE="${BUILD_TYPE:-Release}"
COMPONENTS="${COMPONENTS:-ml}"
WHEELHOUSE_DIR="${WHEELHOUSE_DIR:-}"       # offline wheel directory (--wheelhouse)
PYTHON_PACKAGES="${PYTHON_PACKAGES:-torch torchvision torchaudio vllm}"
THEROCK_EXTRA_ARGS="${THEROCK_EXTRA_ARGS:-}"

# Wheel source: auto -> source builds on riscv64, official wheels elsewhere
if [ "${WHEEL_MODE:-auto}" = auto ]; then
  case "$ARCH" in
    riscv64) WHEEL_MODE=source ;;
    *)       WHEEL_MODE=pip ;;
  esac
fi

# Build mode: x86_64/aarch64 default to the official prebuilt tarball;
# riscv64 has no prebuilt artifacts and must build from source
if [ -z "${MODE:-}" ]; then
  case "$ARCH" in
    riscv64) MODE=source ;;
    *)       MODE=prebuilt ;;
  esac
fi

# ---------------------------------------------------------------- GPU resolution
load_gpu "$GPU_ID" || exit 1

# ---------------------------------------------------------------- directory layout
#
# Design choice: the source workspace IS the upstream/therock submodule itself
# (patched in place).
#   - 30 GB of sources are never copied and the submodule .git link stays intact
#   - after patching the submodule shows up as dirty, which is expected
#     (that is what git diff captures into patches)
#   - to return to a pristine upstream: scripts/tools/baseline.sh restore
UPSTREAM_DIR="$REPO_ROOT/upstream"
SRC_TREE="$UPSTREAM_DIR/therock"              # TheRock source workspace (= submodule work tree)
THEROCK_BUILD="$SRC_TREE/build"               # TheRock build directory
DIST_DIR="$THEROCK_BUILD/dist/rocm"           # flattened, complete ROCm SDK
ARTIFACT_DIR="$WORK_DIR/artifacts"            # download/unpack directory in prebuilt mode
TARBALL_DIR="$ARTIFACT_DIR/tarballs"
PREBUILT_INSTALL="$ARTIFACT_DIR/install"
SRC_ROOT="$WORK_DIR/src"                      # framework-side sources (torch/triton/vllm...)
VENV_STACK="$WORK_DIR/venv-stack"             # host-side build point of the in-image Python env
WHEELHOUSE="$WORK_DIR/wheelhouse"             # locally produced wheels
IMAGE_CTX="$WORK_DIR/image-ctx"               # docker build context
LOG_DIR="$WORK_DIR/logs"
BASELINE_STAMP="$WORK_DIR/.baseline"
SOURCE_PINS="$WORK_DIR/.sources-pins"

# ROCm tree to install into the image: dist/rocm in source mode, the unpacked
# tarball in prebuilt mode
rocm_tree() {
  if [ "$MODE" = prebuilt ]; then printf '%s' "$PREBUILT_INSTALL"; else printf '%s' "$DIST_DIR"; fi
}

# Image kind: vllm (with the Python stack) | runtime (ROCm only)
IMAGE_KIND="${IMAGE_KIND:-vllm}"
case "$IMAGE_KIND" in
  vllm|runtime) ;;
  *) echo "[ERROR] unknown IMAGE_KIND: $IMAGE_KIND (expected vllm|runtime)" >&2; exit 1 ;;
esac

# ---------------------------------------------------------------- image naming
BASE_IMAGE="${BASE_IMAGE:-}"
if [ -z "$BASE_IMAGE" ]; then
  case "$ARCH" in
    riscv64) BASE_IMAGE="$RISCV64_BASE_IMAGE" ;;
    aarch64) BASE_IMAGE="$AARCH64_BASE_IMAGE" ;;
    *)       BASE_IMAGE="$X86_64_BASE_IMAGE" ;;
  esac
fi
# artifact naming: rvocs-<kind>-therock<rocm major.minor>-<gpu>-<img arch>:<repo version>
#   rvocs-vllm-therock10.0-r9700-riscv64:v0.1.0
#   rvocs-runtime-therock10.0-r9700-riscv64:v0.1.0  (IMAGE_KIND=runtime)
case "$ARCH" in
  riscv64)        IMG_ARCH=riscv64 ;;
  aarch64|arm64)  IMG_ARCH=arm64 ;;
  *)              IMG_ARCH=amd64 ;;
esac
THEROCK_TAG=$(printf '%s' "$ROCM_VERSION" | awk -F. '{print $1"."$2}')
case "$IMAGE_KIND" in
  runtime) IMAGE_REPO="${IMAGE_RUNTIME_PREFIX}${THEROCK_TAG}-${GPU_ID}-${IMG_ARCH}" ;;
  *)       IMAGE_REPO="${IMAGE_VLLM_PREFIX}${THEROCK_TAG}-${GPU_ID}-${IMG_ARCH}" ;;
esac
IMAGE_TAG="${IMAGE_TAG:-${IMAGE_REPO}:${AMDG_VERSION}}"

# Multi-GPU NCCL compatibility defaults (needed on RISC-V KFD; auto -> riscv64 only)
if [ "${VLLM_RCCL_FIX}" = auto ]; then
  case "$ARCH" in
    riscv64) VLLM_RCCL_FIX=1 ;;
    *)       VLLM_RCCL_FIX=0 ;;
  esac
fi

export REPO_ROOT WORK_DIR LOG_DIR ARCH GPU_ID GPU_FAMILY GPU_TARGET GPU_PRODUCT \
       MODE JOBS PROXY_MODE DRY_RUN BUILD_TYPE COMPONENTS PYTHON_PACKAGES \
       ROCM_VERSION RELEASE_CHANNEL BASE_IMAGE IMAGE_TAG THEROCK_EXTRA_ARGS \
       IMAGE_KIND WHEEL_MODE SRC_ROOT VENV_STACK WHEELHOUSE IMAGE_CTX STACK_VENV \
       VLLM_DEFAULT_MODEL VLLM_DEFAULT_PORT VLLM_RCCL_FIX WHEELHOUSE_DIR \
       AMDG_VERSION IMG_ARCH IMAGE_REPO

# ---------------------------------------------------------------- logging
log()  { printf '\033[1;32m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1 (install: sudo apt-get install -y $2 2>/dev/null || echo $1)"
}

# Disk space check (GB)
require_disk() { # require_disk <GB> <path>
  local need="$1" path="${2:-$REPO_ROOT}" avail
  avail=$(df -Pk "$path" | awk 'NR==2 {print int($4/1048576)}')
  [ "$avail" -ge "$need" ] || die "insufficient disk space: $path has ${avail}GB < required ${need}GB"
}

# Common execution wrapper: only prints when DRY_RUN=1
run() {
  if [ "${DRY_RUN:-0}" = 1 ]; then
    printf '  [dry-run] %s\n' "$*"
    return 0
  fi
  "$@"
}

# ---------------------------------------------------------------- network proxy
gh_url() { # gh_url <https://github.com/...>
  if [ "${PROXY:-0}" = 1 ]; then echo "https://gh-proxy.com/$1"; else echo "$1"; fi
}

# Resolve and freeze PROXY=1|0; GIT_CONFIG_* lets every git subprocess (including
# the git calls inside fetch_sources.py) inherit insteadOf without polluting the
# user's global configuration.
resolve_proxy() {
  [ -n "${PROXY:-}" ] && return 0
  case "$PROXY_MODE" in
    cn)     PROXY=1 ;;
    direct) PROXY=0 ;;
    auto)
      if curl -fsSI -m 8 https://github.com >/dev/null 2>&1; then
        PROXY=0
      else
        PROXY=1
        warn "github.com is unreachable, enabling mirror mode (gh-proxy + Tsinghua PyPI)"
      fi ;;
    *) die "unknown --proxy mode: $PROXY_MODE (expected cn|direct|auto)" ;;
  esac
  export PROXY
  if [ "$PROXY" = 1 ]; then
    export GIT_CONFIG_COUNT=1
    export GIT_CONFIG_KEY_0="url.https://gh-proxy.com/https://github.com/.insteadOf"
    export GIT_CONFIG_VALUE_0="https://github.com/"
    export PIP_INDEX_URL="$PYPI_MIRROR"
    export PIP_EXTRA_INDEX_URL="$PYPI_MIRROR"
    export UV_INDEX_URL="$PYPI_MIRROR"
    export UV_DEFAULT_INDEX="$PYPI_MIRROR"
  fi
}

# ---------------------------------------------------------------- upstream pin
therock_pin_commit() { # read the gitlink recorded by this repository
  git -C "$REPO_ROOT" ls-tree HEAD upstream/therock 2>/dev/null | awk '{print $3}'
}

therock_head() { # current commit of the submodule (empty when not initialized)
  # without the guard, git -C would walk up and report the parent repository commit
  [ -e "$SRC_TREE/.git" ] || { echo ""; return 0; }
  git -C "$SRC_TREE" rev-parse HEAD 2>/dev/null || echo ""
}

therock_describe() {
  local commit; commit=$(therock_head)
  if [ -z "$commit" ]; then
    echo "(not initialized)"
  elif [ ! -e "$SRC_TREE/.git" ]; then
    echo "$commit"
  else
    git -C "$SRC_TREE" describe --tags --always 2>/dev/null || echo "$commit"
  fi
}

# ---------------------------------------------------------------- branch checks
current_branch() { git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown"; }
is_porting_branch() { [ -d "$REPO_ROOT/patches" ]; }
patch_arch_dir() { echo "$REPO_ROOT/patches/$ARCH"; }

# ---------------------------------------------------------------- framework sources
src_dir() { printf '%s/%s' "$SRC_ROOT" "$1"; }     # src_dir pytorch
src_url() { printf '%s' "${SRC_URL[$1]:-}"; }
src_ref() { printf '%s' "${SRC_REF[$1]:-}"; }
