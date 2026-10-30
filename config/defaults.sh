#!/usr/bin/env bash
# ============================================================================
# Machine-readable defaults (sourced by scripts/lib/common.sh; not executed directly)
# Changing a value here changes the repository-wide default; command-line
# options always take precedence.
# ============================================================================

# ---- target and versions ----
# ---- repository version (VERSION is the single source of truth) ----
AMDG_VERSION="${AMDG_VERSION:-$(tr -d '[:space:]' < "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/VERSION" 2>/dev/null || echo v0.1.0)}"

DEFAULT_GPU="${DEFAULT_GPU:-r9700}"
ROCM_VERSION="${ROCM_VERSION:-10.0.0}"        # matches release.rocm_version in manifest.yaml
RELEASE_CHANNEL="${RELEASE_CHANNEL:-stable}"  # stable|nightly|rc|bkc|dev (prebuilt mode only)

# ---- artifact kind ----
#   vllm    : vLLM inference image (default; can serve models directly)
#   runtime : ROCm user-space runtime only (smaller, no Python stack)
IMAGE_KIND="${IMAGE_KIND:-vllm}"

# ---- wheel source ----
#   auto   : x86_64/aarch64 -> pip (official wheels); riscv64 -> source (build locally)
#   pip    : install torch/torchvision/vllm from the TheRock wheel index
#   source : build triton/torch/torchvision/vllm from the sources in config/sources.sh
WHEEL_MODE="${WHEEL_MODE:-auto}"

# ---- base images ----
X86_64_BASE_IMAGE="${X86_64_BASE_IMAGE:-ubuntu:24.04}"
AARCH64_BASE_IMAGE="${AARCH64_BASE_IMAGE:-ubuntu:24.04}"
# Use the official multi-arch image (it resolves to the riscv64 variant on a
# riscv64 host), matching the validated build; do not use riscv64/ubuntu:*
# (incomplete versions).
RISCV64_BASE_IMAGE="${RISCV64_BASE_IMAGE:-ubuntu:26.04}"

# ---- in-image layout ----
STACK_VENV="${STACK_VENV:-/opt/venv-torch}"   # Python environment path inside the image
VLLM_DEFAULT_MODEL="${VLLM_DEFAULT_MODEL:-/models/Qwen3.5-9B}"
VLLM_DEFAULT_PORT="${VLLM_DEFAULT_PORT:-8000}"
VLLM_RCCL_FIX="${VLLM_RCCL_FIX:-auto}"       # auto|1|0: write multi-GPU NCCL compatibility defaults

# ---- image naming ----
#   rvocs-vllm-therock<rocm major.minor>-<img arch>:<repository version>
#   e.g. rvocs-vllm-therock10.0-riscv64:v0.1.0
# The runtime image follows the same pattern with the rvocs-runtime prefix.
IMAGE_VLLM_PREFIX="${IMAGE_VLLM_PREFIX:-rvocs-vllm-therock}"
IMAGE_RUNTIME_PREFIX="${IMAGE_RUNTIME_PREFIX:-rvocs-runtime-therock}"
IMAGE_NAMESPACE="${IMAGE_NAMESPACE:-amd-therock}"   # legacy value, kept for compatibility

# ---- prebuilt artifact channels (official TheRock multi-arch layout) ----
# tarball name: therock-dist-linux-<bundle>-<version>.tar.gz
# bundle = GPU family (e.g. gfx120X-all) or multiarch
prebuilt_base_url() { # prebuilt_base_url <channel>
  case "$1" in
    stable)  echo "https://stable.repo.amd.com/rocm/core/tarball" ;;
    nightly) echo "https://nightly.repo.amd.com/rocm/core/tarball" ;;
    rc)      echo "https://rc.repo.amd.com/rocm/core/tarball" ;;
    bkc)     echo "https://bkc.repo.amd.com/rocm/core/tarball" ;;
    dev)     echo "https://dev.repo.amd.com/rocm/core/tarball" ;;
    # legacy layout (per-family channels for ROCm <= 7.14)
    legacy-nightly) echo "https://rocm.nightlies.amd.com/v2" ;;
    *) return 1 ;;
  esac
}

prebuilt_python_index() { # prebuilt_python_index <channel>
  case "$1" in
    stable)  echo "https://stable.repo.amd.com/rocm/whl-next/" ;;
    nightly) echo "https://nightly.repo.amd.com/rocm/whl-next/" ;;
    rc)      echo "https://rc.repo.amd.com/rocm/whl-next/" ;;
    bkc)     echo "https://bkc.repo.amd.com/rocm/whl-next/" ;;
    dev)     echo "https://dev.repo.amd.com/rocm/whl-next/" ;;
    *) return 1 ;;
  esac
}

# ---- PyPI mirror (cn mode) ----
PYPI_MIRROR="${PYPI_MIRROR:-https://pypi.tuna.tsinghua.edu.cn/simple}"

# ============================================================================
# Component set presets -> THEROCK_ENABLE_* switches
#   runtime : smallest runnable set (HIP runtime + amdsmi + compiler)
#   ml      : inference/training set (runtime plus BLAS/RAND/SOLVER/SPARSE/FFT/
#             PRIM/MIOpen) - required by torch / vLLM, and the default
#   all     : upstream default, everything (slowest to build)
# Usage: components_flags <preset> -> result in the THEROCK_CMAKE_ARGS array
# ============================================================================
components_flags() {
  local preset="${1:-ml}"
  THEROCK_CMAKE_ARGS=()
  case "$preset" in
    runtime)
      THEROCK_CMAKE_ARGS+=(
        -DTHEROCK_ENABLE_ALL=OFF
        -DTHEROCK_ENABLE_COMPILER=ON
        -DTHEROCK_ENABLE_CORE_RUNTIME=ON
        -DTHEROCK_ENABLE_CORE_AMDSMI=ON
        -DTHEROCK_ENABLE_HIP_RUNTIME=ON
      ) ;;
    ml)
      THEROCK_CMAKE_ARGS+=(
        -DTHEROCK_ENABLE_ALL=OFF
        -DTHEROCK_ENABLE_COMPILER=ON
        -DTHEROCK_ENABLE_CORE_RUNTIME=ON
        -DTHEROCK_ENABLE_CORE_AMDSMI=ON
        -DTHEROCK_ENABLE_HIP_RUNTIME=ON
        -DTHEROCK_ENABLE_PRIM=ON
        -DTHEROCK_ENABLE_BLAS=ON
        -DTHEROCK_ENABLE_RAND=ON
        -DTHEROCK_ENABLE_SOLVER=ON
        -DTHEROCK_ENABLE_SPARSE=ON
        -DTHEROCK_ENABLE_FFT=ON
        -DTHEROCK_ENABLE_ROCWMMA=ON
        # MIOpen is ENABLED here: torch's libtorch_hip references miopen_*
        # symbols, so leaving MIOpen out produces an undefined symbol when
        # importing torch.
        # (The GCC15 <ciso646> #warning versus MIOpen's -Werror is handled by
        #  removing -Werror in patches/riscv64/rocm-libraries/2002.)
        -DTHEROCK_ENABLE_MIOPEN=ON
      ) ;;
    all)
      THEROCK_CMAKE_ARGS+=( -DTHEROCK_ENABLE_ALL=ON ) ;;
    *)
      return 1 ;;
  esac
  return 0
}

components_list() { echo "runtime ml all"; }
