#!/usr/bin/env bash
# ============================================================================
# GPU target resolution (sourced by common.sh)
# Design rule: adding a GPU only touches config/gpu-targets.sh; no script changes.
# ============================================================================

# load_gpu <id|gfx_target>
#   sets GPU_ID / GPU_FAMILY / GPU_TARGET / GPU_PRODUCT
#   accepts either a table alias (r9700) or a raw gfx architecture name
#   (gfx1201, in which case --family must supply THEROCK_AMDGPU_FAMILIES)
load_gpu() {
  local id="${1:-}"
  [ -n "$id" ] || { echo "[ERROR] no GPU target given" >&2; return 1; }

  if [ -n "${GPU_TARGET_OF[$id]:-}" ]; then
    GPU_ID="$id"
    GPU_FAMILY="${GPU_FAMILY_OF[$id]}"
    GPU_TARGET="${GPU_TARGET_OF[$id]}"
    GPU_PRODUCT="${GPU_PRODUCT_OF[$id]}"
    return 0
  fi

  # raw gfx architecture name: a family is required (--family or environment)
  case "$id" in
    gfx[0-9]*)
      local fan="${GPU_FAMILY_OVERRIDE:-${GPU_FAMILY:-}}"
      if [ -z "$fan" ]; then
        echo "[ERROR] using a raw architecture '$id' requires --family to provide THEROCK_AMDGPU_FAMILIES" >&2
        echo "        e.g. --gpu $id --family gfx120X-all" >&2
        echo "        known aliases: ${GPU_ORDER[*]}" >&2
        return 1
      fi
      GPU_ID="$id"; GPU_TARGET="$id"; GPU_FAMILY="$fan"; GPU_PRODUCT="custom ($id)"
      return 0 ;;
  esac

  echo "[ERROR] unknown GPU target: $id" >&2
  echo "        available: ${GPU_ORDER[*]}" >&2
  echo "        to add a model see config/gpu-targets.sh" >&2
  return 1
}

gpu_list() {
  local id
  printf '%-10s %-14s %-10s %s\n' "ID" "FAMILY" "GFX" "PRODUCT"
  for id in "${GPU_ORDER[@]}"; do
    printf '%-10s %-14s %-10s %s\n' \
      "$id" "${GPU_FAMILY_OF[$id]}" "${GPU_TARGET_OF[$id]}" "${GPU_PRODUCT_OF[$id]}"
  done
}

gpu_summary() {
  printf '  GPU        : %s\n' "$GPU_PRODUCT"
  printf '  GPU id     : %s\n' "$GPU_ID"
  printf '  gfx target : %s   (THEROCK_AMDGPU_TARGETS / pip extra device-%s)\n' "$GPU_TARGET" "$GPU_TARGET"
  printf '  family     : %s   (THEROCK_AMDGPU_FAMILIES)\n' "$GPU_FAMILY"
}
