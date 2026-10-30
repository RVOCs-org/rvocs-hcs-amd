#!/usr/bin/env bash
# Build the vLLM wheel (ROCm backend; torch / triton must already be in the venv)
# Input environment: SRC_ROOT DIST_DIR VENV_STACK WHEELHOUSE GPU_TARGET JOBS
# Output: $WHEELHOUSE/vllm-*.whl
set -euo pipefail
: "${SRC_ROOT:?}" "${DIST_DIR:?}" "${VENV_STACK:?}" "${WHEELHOUSE:?}" "${GPU_TARGET:?}"

SRC="$SRC_ROOT/vllm"
[ -d "$SRC" ] || { echo "[wheels/vllm] source tree missing: $SRC" >&2; exit 1; }
mkdir -p "$WHEELHOUSE"
cd "$SRC"

export MAX_JOBS="${JOBS:-32}"
export VLLM_TARGET_DEVICE=rocm
export PYTORCH_ROCM_ARCH="$GPU_TARGET"
export ROCM_PATH="$DIST_DIR"
export PATH="$DIST_DIR/bin:$DIST_DIR/lib/llvm/bin:$PATH"
export LD_LIBRARY_PATH="$DIST_DIR/lib:${LD_LIBRARY_PATH:-}"
export VLLM_USE_PRECOMPILED=0          # force a source build of the kernels

echo "[wheels/vllm] pip wheel ($(git rev-parse --short HEAD 2>/dev/null || echo no-git))"
"$VENV_STACK/bin/pip" wheel --no-deps --no-build-isolation -w "$WHEELHOUSE" .
ls -1 "$WHEELHOUSE"/vllm-*.whl
