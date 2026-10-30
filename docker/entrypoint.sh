#!/bin/bash
# ============================================================================
# vLLM image entrypoint
#
#   no arguments             -> vllm serve $MODEL_PATH (default model, default port)
#   serve/bench/... subcmd   -> passed straight to vllm
#   bash|sh|sleep            -> executed as-is (keeps the container alive for docker exec)
#
# Environment:
#   MODEL_PATH  default model path (default /models/Qwen3.5-9B)
#   PORT        listening port (default 8000)
#   GPU_UTIL    --gpu-memory-utilization (default 0.92)
#   MAX_LEN     --max-model-len (default 8192)
#   EXTRA_ARGS  extra arguments appended to the serve command
#   SKIP_MM_PROFILING  1=add --skip-mm-profiling (faster startup for multimodal models)
# ============================================================================
set -e

VENV="${STACK_VENV:-/opt/venv-torch}"
export ROCM_PATH="${ROCM_PATH:-/opt/rocm}"
export LD_LIBRARY_PATH="${ROCM_PATH}/lib:${ROCM_PATH}/lib/llvm/lib:${LD_LIBRARY_PATH:-}"
export PATH="${ROCM_PATH}/bin:${ROCM_PATH}/lib/llvm/bin:${VENV}/bin:${PATH}"

# Platform-specific multi-GPU defaults (written at build time when applicable)
[ -s /opt/stack/rccl_fix.env ] && . /opt/stack/rccl_fix.env

MODEL="${MODEL_PATH:-/models/Qwen3.5-9B}"

if [ "$#" -gt 0 ]; then
  case "$1" in
    /bin/bash|bash|/bin/sh|sh|sleep) exec "$@" ;;   # keep-alive / interactive
    *) exec "$VENV/bin/vllm" "$@" ;;
  esac
fi

ARGS=(
  serve "$MODEL"
  --host "${HOST:-0.0.0.0}"
  --port "${PORT:-8000}"
  --gpu-memory-utilization "${GPU_UTIL:-0.92}"
  --max-model-len "${MAX_LEN:-8192}"
)
[ "${SKIP_MM_PROFILING:-1}" = 1 ] && ARGS+=( --skip-mm-profiling )
# shellcheck disable=SC2206
[ -n "${EXTRA_ARGS:-}" ] && ARGS+=( ${EXTRA_ARGS} )

exec "$VENV/bin/vllm" "${ARGS[@]}"
