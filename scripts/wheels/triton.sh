#!/usr/bin/env bash
# Build the Triton wheel (reusing the LLVM shipped with TheRock)
# Input environment: SRC_ROOT DIST_DIR VENV_STACK WHEELHOUSE GPU_TARGET JOBS
# Output: $WHEELHOUSE/triton-*.whl
set -euo pipefail
: "${SRC_ROOT:?}" "${DIST_DIR:?}" "${VENV_STACK:?}" "${WHEELHOUSE:?}"

SRC="$SRC_ROOT/triton"
[ -d "$SRC" ] || { echo "[wheels/triton] source tree missing: $SRC" >&2; exit 1; }
mkdir -p "$WHEELHOUSE"
cd "$SRC"

# Non-NVIDIA platform: point the CUDA tool paths at non-existent placeholders so
# setup.py does not fail while probing for them
export TRITON_PTXAS_PATH=/tmp/triton-skip
export TRITON_PTXAS_BLACKWELL_PATH=/tmp/triton-skip
export TRITON_CUOBJDUMP_PATH=/tmp/triton-skip
export TRITON_NVDISASM_PATH=/tmp/triton-skip
export TRITON_CUDACRT_PATH=/tmp/triton-skip
export TRITON_CUDART_PATH=/tmp/triton-skip
export TRITON_CUPTI_INCLUDE_PATH=/tmp/triton-skip
export TRITON_CUPTI_LIB_PATH=/tmp/triton-skip
export MAX_JOBS="${JOBS:-32}"
export LLVM_SYSPATH="$DIST_DIR/lib/llvm"      # use ROCm's LLVM instead of rebuilding it
export ROCM_PATH="$DIST_DIR"
export PATH="$DIST_DIR/bin:$DIST_DIR/lib/llvm/bin:$PATH"

"$VENV_STACK/bin/pip" install -q --upgrade pip setuptools wheel cmake ninja pybind11

# triton's setup.py downloads nlohmann/json with urllib directly (github.com is
# not reachable here):
#   https://github.com/nlohmann/json/releases/download/v3.11.3/include.zip
# It honours the JSON_SYSPATH environment variable pointing at an unpacked header
# directory, so fetch it once up front.
if [ -z "${JSON_SYSPATH:-}" ] || [ ! -d "${JSON_SYSPATH:-/nonexistent}" ]; then
  json_dir="$SRC/.deps/json"
  mkdir -p "$json_dir"
  if [ ! -f "$json_dir/include/nlohmann/json.hpp" ]; then
    echo "[wheels/triton] prefetching nlohmann/json (gh-proxy)"
    curl -fL --retry 3 --connect-timeout 20 -o "$json_dir/include.zip" \
      "https://gh-proxy.com/https://github.com/nlohmann/json/releases/download/v3.11.3/include.zip" \
      || curl -fL --retry 3 -o "$json_dir/include.zip" \
           "https://github.com/nlohmann/json/releases/download/v3.11.3/include.zip"
    ( cd "$json_dir" && unzip -q -o include.zip )
  fi
  export JSON_SYSPATH="$json_dir/include"
fi
echo "[wheels/triton] JSON_SYSPATH=$JSON_SYSPATH"

echo "[wheels/triton] pip wheel (LLVM_SYSPATH=$LLVM_SYSPATH)"
"$VENV_STACK/bin/pip" wheel --no-deps --no-build-isolation -w "$WHEELHOUSE" .
ls -1 "$WHEELHOUSE"/triton-*.whl
