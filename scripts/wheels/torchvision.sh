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
export PYTORCH_ROCM_ARCH="$GPU_TARGET"
export ROCM_PATH="$DIST_DIR"
export PATH="$DIST_DIR/bin:$DIST_DIR/lib/llvm/bin:$PATH"
export LD_LIBRARY_PATH="$DIST_DIR/lib:${LD_LIBRARY_PATH:-}"
# A CPU-only build is the default (matching the validated build: the wheel is
# only 1.2 MB). Set TORCHVISION_CUDA=1 to build the GPU extensions, which needs
# a usable GPU on the build host.
if [ "${TORCHVISION_CUDA:-0}" = 1 ]; then export FORCE_CUDA=1; fi
export TORCHVISION_USE_NVJPEG=0
export TORCHVISION_USE_VIDEO_CODEC=0

echo "[wheels/torchvision] pip wheel"
"$VENV_STACK/bin/pip" wheel --no-deps --no-build-isolation -w "$WHEELHOUSE" .
ls -1 "$WHEELHOUSE"/torchvision-*.whl
