#!/usr/bin/env bash
# Build the torchvision wheel (torch must already be in the venv)
# Input environment: SRC_ROOT DIST_DIR VENV_STACK WHEELHOUSE GPU_TARGET JOBS
# Output: $WHEELHOUSE/torchvision-*.whl
set -euo pipefail
: "${SRC_ROOT:?}" "${DIST_DIR:?}" "${VENV_STACK:?}" "${WHEELHOUSE:?}" "${GPU_TARGET:?}"

SRC="$SRC_ROOT/torchvision"
[ -d "$SRC" ] || { echo "[wheels/torchvision] source tree missing: $SRC" >&2; exit 1; }
mkdir -p "$WHEELHOUSE"
cd "$SRC"

export MAX_JOBS="${JOBS:-32}"
export PATH="$DIST_DIR/bin:$DIST_DIR/lib/llvm/bin:$PATH"
export LD_LIBRARY_PATH="$DIST_DIR/lib:${LD_LIBRARY_PATH:-}"

# CPU-only build is the default (the validated wheel is ~1 MB), and it is the
# ONLY variant that links on a build host without a GPU.
#
# Do not export ROCM_PATH / HIP_PATH / ROCM_HOME / PYTORCH_ROCM_ARCH here:
# torchvision's setup.py reads ROCM_HOME and concludes "this is a ROCm build"
# (IS_ROCM=True), hipifies csrc/vision.cpp into vision_hip.cpp and then compiles
# BOTH files, so linking fails with
#     multiple definition of `vision::cuda_version()'
# With ROCM_HOME unset it stays a plain CPU build and links fine.
# (This is why the stage used to be skipped with BUILD_TORCHVISION=0 -- but vLLM's
# model-architecture inspection imports torchvision, so it cannot be skipped.)
if [ "${TORCHVISION_CUDA:-0}" = 1 ]; then
  export FORCE_CUDA=1
  export PYTORCH_ROCM_ARCH="$GPU_TARGET"
  export ROCM_PATH="$DIST_DIR"
else
  unset ROCM_PATH HIP_PATH ROCM_HOME PYTORCH_ROCM_ARCH FORCE_CUDA
fi
export TORCHVISION_USE_NVJPEG=0
export TORCHVISION_USE_VIDEO_CODEC=0

echo "[wheels/torchvision] pip wheel"
"$VENV_STACK/bin/pip" wheel --no-deps --no-build-isolation -w "$WHEELHOUSE" .
ls -1 "$WHEELHOUSE"/torchvision-*.whl
