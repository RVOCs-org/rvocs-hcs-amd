#!/usr/bin/env bash
# rvocs-hcs-amd one-shot build entry point (the only command you need to remember)
#
# Usage:
#   ./scripts/build.sh [options]
#
# Stages (--stage; each can run on its own, default all):
#   preflight  environment self-check (disk/memory/toolchain/docker/submodule/patchelf)
#   fetch      fetch sources: source mode pulls TheRock plus framework-side repos
#              (torch/triton/vllm); prebuilt mode only downloads the official
#              ROCm tarball
#   workdir    apply the patches/<arch>/ series
#   build      TheRock: cmake configure + ninja -> build/dist/rocm
#   wheels     build/install the Python stack (torch/triton/torchvision/vLLM) -> venv-stack
#   image      assemble the context and run docker build (vllm or runtime)
#   verify     in-container smoke checks (ROCm/GPU/vllm imports, optional serve smoke)
#   prep       = fetch + workdir (only the editable, already patched sources)
#   all        run every stage in the order dictated by the current mode
#
# Common options:
#   --gpu <id>                target GPU (default r9700; --list-gpus shows all)
#   --family <family>         THEROCK_AMDGPU_FAMILIES when giving a raw gfx arch
#   --mode source|prebuilt    ROCm source (x86 defaults to prebuilt, riscv64 is source-only)
#   --image-kind vllm|runtime artifact kind (default vllm: can serve models directly)
#   --wheel-mode auto|pip|source  Python stack source (x86 defaults to pip, riscv64 to source)
#   --components runtime|ml|all   TheRock component set (default ml)
#   --arch x86_64|aarch64|riscv64 target architecture (default: the host)
#   --wheelhouse <dir>        offline wheel directory (preferred when given)
#   --venv <dir>              reuse an existing Python environment (skips the wheels stage)
#   --rocm-version <v>        version for prebuilt mode (defaults in config/defaults.sh)
#   --channel stable|nightly|rc|bkc|dev
#   --base-image <image>      base image for the artifact
#   --proxy cn|direct|auto    network mode (default auto detection)
#   --workdir <dir>           work directory (default ./work)
#   --jobs <n>                parallelism (default nproc)
#   --image-tag <tag>         custom image name
#   --dry-run                 print the plan and commands only
#   --list-gpus               print the GPU target table
#   -h, --help                show this help
#
# Examples:
#   ./scripts/build.sh                          # one-shot vLLM image (fastest x86 path)
#   ./scripts/build.sh --stage build            # build TheRock only
#   ./scripts/build.sh --stage wheels           # Python stack only
#   ./scripts/build.sh --image-kind runtime     # ROCm base image only
#   ./scripts/build.sh --stage prep --gpu r9700 # riscv64: fetch sources + apply patches
#   ./scripts/build.sh --wheelhouse /wheels     # assemble from offline wheels
#   GPU_RUN=1 ./scripts/build.sh --stage verify # include the GPU smoke test
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Print the comment block at the top of this file as help (adapts to its length
# automatically and never leaks code)
_usage_text() { awk 'NR>1 && /^#/ { sub(/^# ?/,""); print; next } NR>1 { exit }' "$0"; }
usage() { _usage_text; exit 0; }
usage_err() { printf '\033[1;31m[ERROR]\033[0m %s\n\n' "$*" >&2; _usage_text >&2; exit 1; }

# ---------------------------------------------------------------------------
# Phase 1: parse arguments (before sourcing common.sh so defaults can be overridden)
# ---------------------------------------------------------------------------
STAGE=all
LIST_GPUS=0

while [ $# -gt 0 ]; do
  case "$1" in
    --stage)         STAGE="${2:?--stage requires an argument}"; shift 2 ;;
    --gpu)           GPU_ID="${2:?--gpu requires an argument}"; shift 2 ;;
    --family)        GPU_FAMILY_OVERRIDE="${2:?--family requires an argument}"; shift 2 ;;
    --arch)          ARCH="${2:?--arch requires an argument}"; shift 2 ;;
    --mode)          MODE="${2:?--mode requires an argument}"; shift 2 ;;
    --image-kind)    IMAGE_KIND="${2:?--image-kind requires an argument}"; shift 2 ;;
    --wheel-mode)    WHEEL_MODE="${2:?--wheel-mode requires an argument}"; shift 2 ;;
    --components)    COMPONENTS="${2:?--components requires an argument}"; shift 2 ;;
    --proxy)         PROXY_MODE="${2:?--proxy requires an argument}"; shift 2 ;;
    --workdir)       WORK_DIR="${2:?--workdir requires an argument}"; shift 2 ;;
    --jobs)          JOBS="${2:?--jobs requires an argument}"; shift 2 ;;
    --image-tag)     IMAGE_TAG="${2:?--image-tag requires an argument}"; shift 2 ;;
    --rocm-version)  ROCM_VERSION="${2:?--rocm-version requires an argument}"; shift 2 ;;
    --channel)       RELEASE_CHANNEL="${2:?--channel requires an argument}"; shift 2 ;;
    --base-image)    BASE_IMAGE="${2:?--base-image requires an argument}"; shift 2 ;;
    --wheelhouse)    WHEELHOUSE_DIR="${2:?--wheelhouse requires an argument}"; shift 2 ;;
    --venv)          VENV_STACK="${2:?--venv requires an argument}"; SKIP_WHEELS=1; shift 2 ;;
    --build-type)    BUILD_TYPE="${2:?--build-type requires an argument}"; shift 2 ;;
    --dry-run)       DRY_RUN=1; shift ;;
    --list-gpus)     LIST_GPUS=1; shift ;;
    -h|--help)       usage ;;
    *)               usage_err "unknown argument: $1" ;;
  esac
done

# ---------------------------------------------------------------------------
# Phase 2: load the shared environment (GPU resolution, paths, defaults)
# ---------------------------------------------------------------------------
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

if [ "$LIST_GPUS" = 1 ]; then gpu_list; exit 0; fi

mkdir -p "$WORK_DIR" "$LOG_DIR"

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
case "$ARCH" in
  x86_64|aarch64|riscv64) ;;
  *) die "unsupported arch: $ARCH (expected x86_64|aarch64|riscv64)" ;;
esac

case "$MODE" in
  source|prebuilt) ;;
  *) die "unknown --mode: $MODE (expected source|prebuilt)" ;;
esac

case "$WHEEL_MODE" in
  auto|pip|source) ;;
  *) die "unknown --wheel-mode: $WHEEL_MODE (expected auto|pip|source)" ;;
esac

if [ "$ARCH" = riscv64 ] && [ "$MODE" = prebuilt ]; then
  die "no official prebuilt artifacts exist for riscv64, use --mode source (already the default)"
fi

if [ "$IMAGE_KIND" = vllm ] && [ "$MODE" = prebuilt ] && [ "$WHEEL_MODE" != pip ]; then
  die "prebuilt mode only works with --wheel-mode pip (source wheels need --mode source)"
fi

components_flags "$COMPONENTS" || die "unknown --components: $COMPONENTS (choices: $(components_list))"

# ---------------------------------------------------------------------------
# Stage orchestration
# ---------------------------------------------------------------------------
ALL_STAGES=""
[ "$MODE" = source ] && ALL_STAGES="$ALL_STAGES fetch workdir"
[ "$MODE" = prebuilt ] && ALL_STAGES="$ALL_STAGES fetch"
[ "$MODE" = source ] && ALL_STAGES="$ALL_STAGES build"
if [ "$IMAGE_KIND" = vllm ] && [ "${SKIP_WHEELS:-0}" != 1 ]; then
  ALL_STAGES="$ALL_STAGES wheels"
fi
ALL_STAGES="preflight$ALL_STAGES image verify"

stage_script() {
  case "$1" in
    preflight) echo "00-preflight.sh" ;;
    fetch)     echo "01-fetch.sh" ;;
    workdir)   echo "02-workdir.sh" ;;
    build)     echo "03-build.sh" ;;
    wheels)    echo "04-wheels.sh" ;;
    image)     echo "05-image.sh" ;;
    verify)    echo "06-verify.sh" ;;
    *)         return 1 ;;
  esac
}

run_stage() {
  local s="$1" script
  script=$(stage_script "$s") || die "unknown stage: $s"
  log "========== stage: $s =========="
  if [ "$DRY_RUN" = 1 ]; then
    bash "$SCRIPT_DIR/$script" || warn "stage $s returned non-zero (dry-run keeps printing the remaining plan)"
    log "stage finished (dry-run): $s"
  elif bash "$SCRIPT_DIR/$script" 2>&1 | tee -a "$LOG_DIR/build.log"; then
    log "stage finished: $s"
  else
    die "stage failed: $s (see $LOG_DIR/build.log and the output above)"
  fi
}

banner() {
  echo "============================================================"
  echo " rvocs-hcs-amd  |  TheRock -> ${IMAGE_KIND} image"
  echo "============================================================"
  gpu_summary
  printf '  %-13s: %s\n' "arch" "$ARCH"
  printf '  %-13s: %s\n' "ROCm source" "$MODE"
  printf '  %-13s: %s (%s)\n' "Python stack" \
    "$([ "$IMAGE_KIND" = vllm ] && echo "$WHEEL_MODE" || echo 'not needed')" \
    "$([ "$IMAGE_KIND" = vllm ] && echo "venv -> $STACK_VENV" || echo 'the runtime image has no Python')"
  printf '  %-13s: %s\n' "components" "$COMPONENTS"
  printf '  %-13s: %s (%s)\n' "ROCm version" "$ROCM_VERSION" "$RELEASE_CHANNEL"
  printf '  %-13s: %s\n' "workdir" "$WORK_DIR"
  printf '  %-13s: %s\n' "image tag" "$IMAGE_TAG"
  printf '  %-13s: %s\n' "branch" "$(current_branch)"
  if is_porting_branch; then
    printf '  %-13s: patches/%s\n' "patch layer" "$ARCH"
  else
    printf '  %-13s: none (master branch)\n' "patch layer"
  fi
  printf '  %-13s: %s\n' "stages" "$ALL_STAGES"
  echo "============================================================"
}

banner

if [ "$DRY_RUN" = 1 ]; then
  warn "dry-run: only printing the commands that would run, nothing is changed"
fi

case "$STAGE" in
  all)
    for s in $ALL_STAGES; do run_stage "$s"; done
    log "all done. image: $IMAGE_TAG"
    ;;
  prep)
    run_stage fetch
    if [ "$MODE" = source ]; then
      run_stage workdir
      log "source workspace ready (patched): $SRC_TREE"
      log "after editing, capture the changes with scripts/tools/patch.sh capture, then --stage build"
    else
      log "prebuilt mode has no workdir stage; artifacts are ready: $TARBALL_DIR"
    fi
    ;;
  *)
    case " $ALL_STAGES " in
      *" $STAGE "*) ;;
      *) die "current mode ($MODE / $IMAGE_KIND) does not support --stage $STAGE; available: prep $ALL_STAGES" ;;
    esac
    run_stage "$STAGE"
    ;;
esac
