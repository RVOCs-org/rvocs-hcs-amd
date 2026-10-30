#!/usr/bin/env bash
# Build the PyTorch (ROCm) wheel
# Input environment: SRC_ROOT DIST_DIR VENV_STACK WHEELHOUSE GPU_TARGET JOBS
# Output: $WHEELHOUSE/torch-*.whl
set -euo pipefail
: "${SRC_ROOT:?}" "${DIST_DIR:?}" "${VENV_STACK:?}" "${WHEELHOUSE:?}" "${GPU_TARGET:?}"

SRC="$SRC_ROOT/pytorch"
[ -d "$SRC" ] || { echo "[wheels/torch] source tree missing: $SRC" >&2; exit 1; }
mkdir -p "$WHEELHOUSE"
cd "$SRC"

export MAX_JOBS="${JOBS:-32}"
export PYTORCH_ROCM_ARCH="$GPU_TARGET"
export ROCM_PATH="$DIST_DIR"
export PATH="$DIST_DIR/bin:$DIST_DIR/lib/llvm/bin:$PATH"
export LD_LIBRARY_PATH="$DIST_DIR/lib:${LD_LIBRARY_PATH:-}"
export USE_NINJA=0                     # let cmake use its own generator instead of fighting setup.py over -j

# aotriton (the ROCm flash-attention kernels) triggers
#   pip install -r build/aotriton/src/aotriton_runtime/requirements.txt
# by default. That pulls in pandas, and pandas 3.x has no riscv64 wheel while a
# source build fails because the bundled xsimd does not support riscv. So disable
# flash-attention on riscv64; torch then falls back to math/efficient SDPA. Set
# USE_FLASH_ATTENTION=1 to enable it (after solving the pandas issue).
export USE_FLASH_ATTENTION="${USE_FLASH_ATTENTION:-0}"
# Note: torch's CMakeLists only includes aotriton.cmake when
# if(USE_FLASH_ATTENTION OR USE_MEM_EFF_ATTENTION), and USE_MEM_EFF_ATTENTION
# defaults to ON on ROCm, so both must be off to actually bypass aotriton (and
# therefore pandas).
export USE_MEM_EFF_ATTENTION="${USE_MEM_EFF_ATTENTION:-0}"

# HIPIFY: the hip-ified sources must be generated first, otherwise the wheel is incomplete
if [ -f tools/amd_build/build_amd.py ]; then
  echo "[wheels/torch] build_amd.py (HIPIFY code generation)"
  "$VENV_STACK/bin/python" tools/amd_build/build_amd.py
fi

echo "[wheels/torch] cmake configure"
cmake -S . -B build \
  -DCMAKE_BUILD_TYPE=Release \
  -DUSE_ROCM=ON \
  -DCMAKE_INSTALL_PREFIX="$SRC/torch" \
  -DUSE_FLASH_ATTENTION="${USE_FLASH_ATTENTION:-0}" \
  -DUSE_MEM_EFF_ATTENTION="${USE_MEM_EFF_ATTENTION:-0}" \
  -DUSE_MIOPEN="${USE_MIOPEN:-1}" \
  -DUSE_RCCL="${USE_RCCL:-OFF}" \
  -DUSE_NCCL="${USE_NCCL:-OFF}" \
  -DUSE_ROCM_CK_GEMM="${USE_ROCM_CK_GEMM:-OFF}" \
  -DUSE_ROCM_CK_SDPA="${USE_ROCM_CK_SDPA:-OFF}" \
  -DPYTORCH_ROCM_ARCH="$GPU_TARGET" \
  -DROCM_PATH="$DIST_DIR" \
  -DPython_EXECUTABLE="$VENV_STACK/bin/python" \
  -DBUILD_TEST=OFF \
  -DBUILD_BINARY=OFF \
  -DUSE_CUDNN=OFF \
  -DUSE_KINETO=OFF

echo "[wheels/torch] build -j ${MAX_JOBS}"
cmake --build build -j "${MAX_JOBS}"

# Critical: the .so files must be installed into $SRC/torch/lib because
# bdist_wheel packages from there. With a wrong prefix (e.g. /usr/local) the
# wheel ends up without libtorch.so / libtorch_cpu.so / libtorch_global_deps.so
# and importing torch fails outright.
echo "[wheels/torch] cmake install -> $SRC/torch"
cmake --install build

# riscv64: libtorch_hip.so references the libMIOpen C API symbols
# (miopenCreateTensorDescriptor and friends), but the linker's --as-needed
# dropped the DT_NEEDED entry, so dlopen fails at runtime with
#   ImportError: libtorch_hip.so: undefined symbol: miopenCreateTensorDescriptor
# Add the missing NEEDED entry manually (the same class of problem as RCCL
# dropping libroctx64).
if command -v patchelf >/dev/null 2>&1 && [ -f "$SRC/torch/lib/libtorch_hip.so" ]; then
  if ! readelf -d "$SRC/torch/lib/libtorch_hip.so" | grep -q "libMIOpen"; then
    echo "[wheels/torch] patchelf --add-needed libMIOpen.so.1 libtorch_hip.so"
    patchelf --add-needed libMIOpen.so.1 "$SRC/torch/lib/libtorch_hip.so"
  fi
fi

echo "[wheels/torch] bdist_wheel"
"$VENV_STACK/bin/python" setup.py bdist_wheel -d "$WHEELHOUSE"
ls -1 "$WHEELHOUSE"/torch-*.whl
