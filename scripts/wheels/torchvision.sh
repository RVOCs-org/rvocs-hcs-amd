#!/usr/bin/env bash
# Build the torchvision wheel (torch must already be in the venv)
# Input environment: SRC_ROOT DIST_DIR VENV_STACK WHEELHOUSE GPU_TARGET JOBS
# Output: $WHEELHOUSE/torchvision-*.whl
set -euo pipefail
: "${SRC_ROOT:?}" "${DIST_DIR:?}" "${VENV_STACK:?}" "${WHEELHOUSE:?}" "${GPU_TARGET:?}"

SRC="$SRC_ROOT/torchvision"
[ -d "$SRC" ] || { echo "[wheels/torchvision] source tree missing: $SRC" >&2; exit 1; }

# Remove every leftover from a previous ROCm attempt.
#
# When IS_ROCM is true, setup.py runs hipify in place: it writes vision_hip.cpp,
# io/image/image_hip.cpp and an io/image/hip/ + ops/hip/ directory next to the
# originals, and keeps the originals. setup.py then collects sources with globs
# such as
#   CSRS_DIR.glob("*.cpp")                -> vision.cpp + vision_hip.cpp
#   image_dir.glob("*.cpp")               -> image.cpp + image_hip.cpp
#   image_dir.glob("cpu/*.cpp")           -> decode_gif.cpp ...
# Both copies then get compiled into the same extension, which fails either at
# link time
#   multiple definition of `vision::cuda_version()'
# or, more confusingly, at import time because the same operators are registered
# twice:
#   Tried to register an operator (image::decode_gif(Tensor _0) -> Tensor _0)
#   with the same name and overload name multiple times
# Both happen even when the current build is CPU-only (IS_ROCM=False), because
# the stale files are still on disk. So purge them before every build.
find "$SRC"/torchvision -type f -name '*_hip.cpp' -delete 2>/dev/null || true
find "$SRC"/torchvision -type d -name hip -prune -exec rm -rf {} + 2>/dev/null || true
rm -rf "$SRC"/build
mkdir -p "$WHEELHOUSE"
cd "$SRC"

export MAX_JOBS="${JOBS:-32}"

# CPU-only build is the default (the validated wheel is ~1 MB), and it is the only
# variant that links on a build host without a GPU.
#
# Getting the CPU build right takes care of one non-obvious detail. torchvision
# decides with
#
#     IS_ROCM = (torch.version.hip is not None) and (ROCM_HOME is not None)
#
# where ROCM_HOME comes from torch.utils.cpp_extension._find_rocm_home(). That
# helper falls back to shutil.which("hipcc") when ROCM_HOME / ROCM_PATH /
# HIP_PATH are unset, so *unsetting the variables is not enough*: having
# $DIST_DIR/bin on PATH is already sufficient to make IS_ROCM True. It then
# hipifies csrc/vision.cpp into vision_hip.cpp and links BOTH, failing with
#
#     multiple definition of `vision::cuda_version()'
#
# Therefore the CPU branch below also strips dist from PATH.
if [ "${TORCHVISION_CUDA:-0}" = 1 ]; then
  export FORCE_CUDA=1
  export PYTORCH_ROCM_ARCH="$GPU_TARGET"
  export ROCM_PATH="$DIST_DIR"
  export PATH="$DIST_DIR/bin:$DIST_DIR/lib/llvm/bin:$PATH"
  export LD_LIBRARY_PATH="$DIST_DIR/lib:${LD_LIBRARY_PATH:-}"
else
  unset ROCM_PATH HIP_PATH ROCM_HOME PYTORCH_ROCM_ARCH FORCE_CUDA
  # Strip every dist entry from PATH so that shutil.which("hipcc") returns None.
  _clean_path=$(printf '%s' "${PATH:-}" | tr ':' '\n' | grep -v -F "$DIST_DIR" | paste -sd: -)
  export PATH="$_clean_path"
  # LD_LIBRARY_PATH does not take part in the ROCm detection and is still useful
  # for importing the ROCm build of torch, so it stays.
  export LD_LIBRARY_PATH="$DIST_DIR/lib:${LD_LIBRARY_PATH:-}"
fi
export TORCHVISION_USE_NVJPEG=0
export TORCHVISION_USE_VIDEO_CODEC=0

echo "[wheels/torchvision] pip wheel"
"$VENV_STACK/bin/pip" wheel --no-deps --no-build-isolation -w "$WHEELHOUSE" .
ls -1 "$WHEELHOUSE"/torchvision-*.whl
