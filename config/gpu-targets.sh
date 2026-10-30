#!/usr/bin/env bash
# ============================================================================
# GPU target table (single source of truth; parsed by scripts/lib/gpu.sh,
# never executed directly)
#
#   gpu_define <id> <therock_family> <gfx_target> "<product name>"
#
#   therock_family : value for THEROCK_AMDGPU_FAMILIES, see the upstream file
#                    cmake/therock_amdgpu_targets.cmake
#   gfx_target     : LLVM/HIP architecture name written to THEROCK_AMDGPU_TARGETS;
#                    it also selects the pip extra (device-<gfx_target>)
#
# To extend: add one line, then run ./scripts/build.sh --gpu <new id> ...
# ============================================================================

declare -A GPU_FAMILY_OF=()
declare -A GPU_TARGET_OF=()
declare -A GPU_PRODUCT_OF=()
GPU_ORDER=()

gpu_define() { # gpu_define <id> <family> <gfx_target> <product>
  GPU_ORDER+=( "$1" )
  GPU_FAMILY_OF["$1"]="$2"
  GPU_TARGET_OF["$1"]="$3"
  GPU_PRODUCT_OF["$1"]="$4"
}

# ---- currently validated target ---------------------------------------------
gpu_define r9700   gfx120X-all  gfx1201  "AMD Radeon AI PRO R9700 (Navi 48 / RDNA4, 32 GB)"

# ---- same architecture / preset but not validated (build products equal gfx120X-all) ----
gpu_define rx9070  gfx120X-all  gfx1201  "AMD Radeon RX 9070 / XT"
gpu_define rx9060  gfx120X-all  gfx1200  "AMD Radeon RX 9060 / XT"

# ---- other architectures (illustrative: extending needs no script changes) --
gpu_define mi300x  gfx94X-dcgpu gfx942   "AMD Instinct MI300X"
gpu_define mi355x  gfx950-dcgpu gfx950   "AMD Instinct MI355X"
gpu_define w7900   gfx110X-all  gfx1100  "AMD Radeon PRO W7900"
