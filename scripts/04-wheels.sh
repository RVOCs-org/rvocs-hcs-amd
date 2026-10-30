#!/usr/bin/env bash
# Stage 4: Python stack (torch / triton / torchvision / vLLM) -> $VENV_STACK
#
# Two sources (--wheel-mode):
#   pip    : install from the official TheRock wheel index (x86_64/aarch64, minutes)
#   source : build each wheel from the sources in config/sources.sh (required on riscv64)
#
# Artifacts:
#   $VENV_STACK       venv that can be copied into the image as a whole (at $STACK_VENV)
#   $WHEELHOUSE/*.whl archived wheels (at /opt/vllm-wheels in the image, for offline reinstall)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

if [ "$IMAGE_KIND" != vllm ]; then
  log "the runtime image needs no Python stack, skipping"
  exit 0
fi

resolve_proxy
mkdir -p "$WHEELHOUSE" "$SRC_ROOT"

# In source mode the DT_NEEDED entries of torch/triton/vLLM .so files point at
# libraries inside dist/rocm (libMIOpen.so, libamdhip64.so, librocblas.so, ...);
# both compiling and importing need to find them. The image needs the same two
# paths, see LD_LIBRARY_PATH in docker/vllm.Dockerfile.
if [ "$WHEEL_MODE" = source ]; then
  _rt="$(rocm_tree)"
  export LD_LIBRARY_PATH="${_rt}/lib:${_rt}/lib/rocm_sysdeps/lib:${LD_LIBRARY_PATH:-}"
  export ROCM_PATH="$_rt"
  export HIP_PATH="$_rt"
  log "LD_LIBRARY_PATH=$LD_LIBRARY_PATH"
fi

PY="${VENV_STACK}/bin/python"
PIP="${VENV_STACK}/bin/pip"

ensure_venv() {
  if [ ! -x "$PY" ]; then
    log "creating venv: $VENV_STACK"
    run python3 -m venv "$VENV_STACK"
    run "$PIP" install -q -U pip
  fi
}

# ---------------------------------------------------------------------------
# A. pip mode: official wheels
# ---------------------------------------------------------------------------
wheels_pip() {
  local idx; idx=$(prebuilt_python_index "$RELEASE_CHANNEL" || echo "")
  [ -n "$idx" ] || die "unknown release channel: $RELEASE_CHANNEL"

  # 1) prefer the offline wheelhouse
  if [ -n "$WHEELHOUSE_DIR" ] && [ -d "$WHEELHOUSE_DIR" ]; then
    log "installing from the offline wheelhouse: $WHEELHOUSE_DIR"
    run cp -f "$WHEELHOUSE_DIR"/*.whl "$WHEELHOUSE"/ 2>/dev/null || true
    run "$PIP" install -q --no-index --find-links="$WHEELHOUSE" torch torchvision torchaudio vllm
  else
    log "installing from the TheRock index ($idx)"
    log "  torch[device-$GPU_TARGET] torchvision[device-$GPU_TARGET] torchaudio vllm"
    run "$PIP" install --index-url "$idx" \
      "torch[device-${GPU_TARGET}]" "torchvision[device-${GPU_TARGET}]" torchaudio vllm
    # archive the wheels so the image can be rebuilt offline
    run "$PIP" download -q --no-deps -d "$WHEELHOUSE" \
      --index-url "$idx" "torch[device-${GPU_TARGET}]" "torchvision[device-${GPU_TARGET}]" \
      torchaudio vllm || warn "wheel archiving failed (this does not affect the image build)"
  fi
}

# ---------------------------------------------------------------------------
# B. source mode: build per component, then install
#   The order matters: torch must be in the venv before triton/torchvision/vLLM
#   can build
# ---------------------------------------------------------------------------
build_one() { # build_one <stage>
  # Note: do not write local stage="$1" script="...${stage}..." - within a single
  # local command all words are expanded before assignment, so ${stage} would be
  # undefined under set -u
  local stage="$1"
  local script="$SCRIPT_DIR/wheels/${stage}.sh"
  [ -f "$script" ] || die "missing wheel build script: scripts/wheels/${stage}.sh"
  # Skip the build when the wheel already exists (a torch build takes 2 hours and
  # must not be repeated just because a later component failed)
  if ls "$WHEELHOUSE"/${stage}-*.whl >/dev/null 2>&1 && [ "${FORCE_REBUILD:-0}" != 1 ]; then
    log "---------- $stage wheel already present, skipping (FORCE_REBUILD=1 forces a rebuild) ----------"
    return 0
  fi

  log "---------- building $stage ----------"
  if [ "$DRY_RUN" = 1 ]; then
    printf '  [dry-run] bash %s (SRC_ROOT=%s DIST_DIR=%s)\n' "$script" "$SRC_ROOT" "$(rocm_tree)"
    return 0
  fi
  SRC_ROOT="$SRC_ROOT" DIST_DIR="$(rocm_tree)" VENV_STACK="$VENV_STACK" \
  WHEELHOUSE="$WHEELHOUSE" GPU_TARGET="$GPU_TARGET" ARCH="$ARCH" JOBS="$JOBS" \
    bash "$script" 2>&1 | tee -a "$LOG_DIR/wheels-${stage}.log"
  [ "${PIPESTATUS[0]}" = 0 ] || die "$stage build failed (see $LOG_DIR/wheels-${stage}.log)"
}

# riscv64: libtorch_hip.so references the libMIOpen C API symbols, but the linker's
# --as-needed dropped the DT_NEEDED entry, so importing torch fails with
#   ImportError: libtorch_hip.so: undefined symbol: miopenCreateTensorDescriptor
# Add a NEEDED entry to the installed .so (idempotent; the same class of problem
# as RCCL dropping libroctx64).
fix_torch_miopen_needed() {
  local so
  so=$(ls -d "$VENV_STACK"/lib/python3*/site-packages/torch/lib/libtorch_hip.so 2>/dev/null | head -1 || true)
  [ -n "$so" ] || return 0
  command -v patchelf >/dev/null 2>&1 || { warn "patchelf is missing, skipping the libtorch_hip DT_NEEDED fix"; return 0; }
  if readelf -d "$so" | grep -q "libMIOpen"; then return 0; fi
  log "patchelf --add-needed libMIOpen.so.1 ($so)"
  run patchelf --add-needed libMIOpen.so.1 "$so" || warn "patchelf failed (importing torch may report missing miopen symbols)"
}

install_wheel() { # install_wheel <name-glob>
  local n="$1"
  # --force-reinstall: with the same name and version pip would skip the install
  # and leave a stale, broken wheel in the venv
  run "$PIP" install -q --no-deps --force-reinstall "$WHEELHOUSE"/${n}-*.whl
}

# The order has hard dependencies:
#   torch's setup.py needs build-time deps such as pyyaml/numpy/typing_extensions
#   vLLM needs torch and triton already installed in the venv when it builds
wheels_source() {
  log "installing build-time Python dependencies"
  run "$PIP" install -q -U pip setuptools wheel packaging
  run "$PIP" install -q pyyaml numpy typing_extensions requests filelock jinja2 \
                          sympy networkx cloudpickle cmake ninja pybind11 \
                          setuptools_rust setuptools_scm

  build_one torch
  install_wheel torch
  fix_torch_miopen_needed
  log "torch: $("$PY" -c 'import torch;print(torch.__version__)' 2>/dev/null || echo 'pending check')"

  install_runtime_deps          # needed to build and to run vLLM

  build_one triton
  install_wheel triton

  # With "ROCm torch + no GPU on the build host", torchvision compiles both its
  # hipified vision_hip.cpp and the original vision.cpp, so linking fails with
  #   multiple definition of `vision::cuda_version()'
  # The vLLM core does not depend on torchvision, so skip it by default; enable
  # with BUILD_TORCHVISION=1.
  if [ "${BUILD_TORCHVISION:-0}" = 1 ]; then
    build_one torchvision
    install_wheel torchvision
  else
    log "skipping torchvision (BUILD_TORCHVISION=0; the vLLM core does not need it)"
  fi

  build_one vllm
  install_wheel vllm
}

# vLLM runtime dependencies (the source stack bypasses setup.py dependency
# resolution, so they must be installed explicitly)
install_runtime_deps() {
  local idx="${PIP_INDEX_URL:-https://pypi.org/simple}"
  log "installing vLLM runtime dependencies ($idx)"
  # Use vLLM's own requirements - a hand-maintained subset always misses something
  # (cbor2 for example) - but drop:
  #   torch/triton and friends: otherwise pip replaces our self-built wheels
  #   opencv-python-headless / mistral_common[image]: no riscv64 wheel and a
  #     source build takes hours; install mistral_common without the [image] extra
  #     (Mistral text models keep working)
  local reqs="$SRC_ROOT/vllm/requirements" filtered="$WORK_DIR/vllm-requirements.txt"
  if [ -f "$reqs/common.txt" ]; then
    grep -v -E '^(torch|triton|torchvision|torchaudio|pytorch|opencv-python-headless|mistral_common)' \
      "$reqs/common.txt" > "$filtered" || true
    run "$PIP" install -q --index-url "$idx" -r "$filtered" \
      || warn "some vLLM common dependencies failed (continuing; only optional features are affected)"
  fi
  # Safety net plus explicit additions (these are hard requirements on the vLLM
  # start-up path; without them the server does not come up):
  #   cbor2       : vllm.utils.hashing
  #   pycountry   : needed by mistral_common's language_code; vLLM imports it
  #                 unconditionally through transformers.MistralCommonBackend
  #   mistral_common (without [image]): Mistral-family models without pulling opencv
  run "$PIP" install -q --index-url "$idx" \
    numpy fastapi uvicorn pydantic tokenizers safetensors huggingface_hub \
    psutil requests tqdm msgspec partial_json_parser cloudpickle typing-inspection \
    jsonschema openai prometheus-fastapi-instrumentator sentencepiece \
    transformers cbor2 pycountry mistral_common || true
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
ensure_venv
case "$WHEEL_MODE" in
  pip)    wheels_pip ;;
  source)
    if [ -d "$SRC_ROOT" ] && [ -n "$(ls -A "$SRC_ROOT" 2>/dev/null)" ]; then
      :
    elif [ "$DRY_RUN" = 1 ]; then
      warn "dry-run: framework sources are not fetched yet ($SRC_ROOT), showing the plan only"
    else
      die "framework sources not fetched: $SRC_ROOT (run --stage fetch first)"
    fi
    wheels_source ;;
esac

# Verification
if [ "$DRY_RUN" != 1 ]; then
  log "verifying imports ..."
  "$PY" - <<'PYEOF'
import os
import sys
# torchvision is skipped by default (BUILD_TORCHVISION=0), so check it only when built
mods = ["torch", "triton", "vllm"]
if os.environ.get("BUILD_TORCHVISION", "0") == "1":
    mods.insert(1, "torchvision")
missing = []
for m in mods:
    try:
        __import__(m)
    except Exception as e:                     # noqa: BLE001
        missing.append(f"{m}: {type(e).__name__}: {e}")
if missing:
    print("WHEELS_IMPORT_FAILED")
    for m in missing:
        print("  " + m)
    sys.exit(1)
import torch, vllm, triton
print("WHEELS_IMPORT_OK", torch.__version__, "hip=" + str(torch.version.hip),
      "triton=" + triton.__version__, "vllm=" + vllm.__version__)
PYEOF
  log "Python stack ready: $VENV_STACK ($(du -sh "$VENV_STACK" | awk '{print $1}'))"
fi

log "wheels done"
