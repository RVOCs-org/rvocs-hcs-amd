#!/usr/bin/env bash
# Stage 5: assemble the build context and build the image
#   vllm    : docker/vllm.Dockerfile (ROCm + venv + vLLM + entrypoint)
#   runtime : docker/runtime.Dockerfile (ROCm only)
#
# Context layout ($IMAGE_CTX):
#   dist/ venv-torch/ wheelhouse/ benchmarks/ patches/ Dockerfile entrypoint.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_cmd docker

TREE=$(rocm_tree)
if [ ! -d "$TREE" ] || [ -z "$(ls -A "$TREE" 2>/dev/null)" ]; then
  if [ "$DRY_RUN" = 1 ]; then
    warn "dry-run: the ROCm tree does not exist yet or is empty: $TREE"
  else
    die "the ROCm tree does not exist or is empty: $TREE
   source   mode: run --stage build first
   prebuilt mode: run --stage fetch first"
  fi
fi

if [ "$IMAGE_KIND" = vllm ] && [ ! -x "$VENV_STACK/bin/python" ]; then
  if [ "$DRY_RUN" = 1 ]; then
    warn "dry-run: the Python environment does not exist yet: $VENV_STACK"
  else
    die "the Python environment does not exist: $VENV_STACK (run --stage wheels first, or reuse one with --venv)"
  fi
fi

CTX="$IMAGE_CTX"
DF="$REPO_ROOT/docker/$([ "$IMAGE_KIND" = vllm ] && echo vllm || echo runtime).Dockerfile"
[ -f "$DF" ] || die "missing Dockerfile: $DF"

# ---------------------------------------------------------------------------
# 1. Assemble the context (cp -al hard links: fast and space efficient; falls
#    back automatically across filesystems)
# ---------------------------------------------------------------------------
link_copy() { # link_copy <src> <dst>
  cp -al "$1" "$2" 2>/dev/null || cp -a "$1" "$2"
}

prepare_ctx() {
  log "assembling build context: $CTX"
  run rm -rf "$CTX"
  run mkdir -p "$CTX"

  log "  dist <- $TREE ($(du -sh "$TREE" 2>/dev/null | awk '{print $1}'))"
  run link_copy "$TREE" "$CTX/dist"

  if [ "$IMAGE_KIND" = vllm ]; then
    log "  venv-torch <- $VENV_STACK"
    run link_copy "$VENV_STACK" "$CTX/venv-torch"

    log "  wheelhouse <- $WHEELHOUSE"
    run mkdir -p "$CTX/wheelhouse"
    [ -d "$WHEELHOUSE" ] && run bash -c "cp -f '$WHEELHOUSE'/*.whl '$CTX/wheelhouse/' 2>/dev/null || true"
    [ -n "$(ls -A "$CTX/wheelhouse" 2>/dev/null)" ] || run touch "$CTX/wheelhouse/.keep"

    # benchmarks: include them when present (the benchmark scripts shipped with vLLM)
    run mkdir -p "$CTX/benchmarks"
    if [ -d "$SRC_ROOT/vllm/benchmarks" ]; then
      log "  benchmarks <- $SRC_ROOT/vllm/benchmarks"
      run bash -c "cp -a '$SRC_ROOT/vllm/benchmarks/.' '$CTX/benchmarks/'"
    fi
    [ -n "$(ls -A "$CTX/benchmarks" 2>/dev/null)" ] || run touch "$CTX/benchmarks/.keep"

    # image-time python patches (patches/<arch>/image/)
    run mkdir -p "$CTX/patches"
    if is_porting_branch && [ -d "$(patch_root)/image" ]; then
      local n
      n=$(find "$(patch_root)/image" -maxdepth 1 -name '*.py' | wc -l)
      [ "$n" -gt 0 ] && log "  patches <- $(patch_root)/image ($n .py files)"
      run bash -c "cp -f '$(patch_root)/image'/*.py '$CTX/patches/' 2>/dev/null || true"
    fi
    [ -n "$(ls -A "$CTX/patches" 2>/dev/null)" ] || run touch "$CTX/patches/.keep"

    run cp -f "$REPO_ROOT/docker/entrypoint.sh" "$CTX/entrypoint.sh"
  else
    run mkdir -p "$CTX/wheelhouse"
    run touch "$CTX/wheelhouse/.keep"
  fi

  run cp -f "$DF" "$CTX/Dockerfile"
  [ -f "$REPO_ROOT/docker/.dockerignore" ] && run cp -f "$REPO_ROOT/docker/.dockerignore" "$CTX/.dockerignore"
  return 0
}

prepare_ctx

# ---------------------------------------------------------------------------
# 2. docker build
# ---------------------------------------------------------------------------
BUILD_ARGS=(
  --build-arg BASE_IMAGE="$BASE_IMAGE"
  --build-arg GFX_TARGET="$GPU_TARGET"
  --build-arg GFX_FAMILY="$GPU_FAMILY"
  --build-arg ROCM_VERSION="$ROCM_VERSION"
  --build-arg TARGET_ARCH="$ARCH"
)

if [ "$IMAGE_KIND" = vllm ]; then
  BUILD_ARGS+=(
    --build-arg STACK_VENV="$STACK_VENV"
    --build-arg HOST_VENV_PREFIX="$VENV_STACK"
    --build-arg RCCL_FIX="$VLLM_RCCL_FIX"
    --build-arg VLLM_DEFAULT_MODEL="$VLLM_DEFAULT_MODEL"
    --build-arg VLLM_DEFAULT_PORT="$VLLM_DEFAULT_PORT"
    --build-arg WITH_GCC="${WITH_GCC:-0}"
  )
  log "building the vLLM image: $IMAGE_TAG"
  log "  base   : $BASE_IMAGE"
  log "  rocm   : $TREE"
  log "  venv   : $VENV_STACK -> $STACK_VENV"
  log "  gfx    : $GPU_TARGET (family $GPU_FAMILY)"
  log "  rccl   : $VLLM_RCCL_FIX (1=write multi-GPU compatibility defaults)"
else
  log "building the runtime image: $IMAGE_TAG"
  log "  base   : $BASE_IMAGE"
  log "  rocm   : $TREE"
  log "  gfx    : $GPU_TARGET (family $GPU_FAMILY)"
fi

run env DOCKER_BUILDKIT=1 docker build \
  --network host \
  --build-context wheelhouse="$CTX/wheelhouse" \
  "${BUILD_ARGS[@]}" \
  -t "$IMAGE_TAG" \
  -f "$CTX/Dockerfile" \
  "$CTX"

log "image built: $IMAGE_TAG"
if [ "$IMAGE_KIND" = vllm ]; then
  cat <<EOF

Deploy example (on the target host; requires the amdgpu driver and a model directory):
  docker run -d --name vllm --network=host --ipc=host \\
    --device=/dev/kfd --device=/dev/dri --group-add video --group-add render \\
    --security-opt seccomp=unconfined \\
    -v /models:/models:ro \\
    -e MODEL_PATH=$VLLM_DEFAULT_MODEL -e PORT=8000 \\
    $IMAGE_TAG

  # 2-GPU tensor parallelism
  docker run ... -e HIP_VISIBLE_DEVICES=0,1 -e EXTRA_ARGS="--tensor-parallel-size 2 --enforce-eager" $IMAGE_TAG
EOF
else
  cat <<EOF

Run example (on the target host):
  docker run --rm -it --device=/dev/kfd --device=/dev/dri \\
    --ipc=host --group-add video --group-add render \\
    --security-opt seccomp=unconfined $IMAGE_TAG rocminfo
EOF
fi
