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
if [ -f "$SCRIPT_DIR/../ci/lib/inputs.sh" ]; then
  # shellcheck source=../ci/lib/inputs.sh
  source "$SCRIPT_DIR/../ci/lib/inputs.sh"
fi

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
  # Reuse a wheel only when the content it was built from is unchanged. A bare
  # "wheel file exists" check silently kept stale wheels (e.g. a torch built
  # before RCCL landed), while an mtime/pin based check rebuilt 2 hours for a
  # no-op. The stamp records a content fingerprint instead (ci/lib/inputs.sh).
  local fp stampf stampd="$WHEELHOUSE/.stamps"
  # NOTE: the third argument must be the TheRock *source* work tree. It used to be
  # "$(rocm_tree)" (the install prefix), which is not a git work tree, so
  # upstream_fp degenerated to a constant and an upstream source change never
  # invalidated the wheels (found 2026-11-26 while seeding stamps).
  fp="$(wheel_fp "$REPO_ROOT" "$stage" "${SRC_TREE:-$REPO_ROOT/upstream/therock}")"
  stampf="$stampd/$stage.fp"
  mkdir -p "$stampd"
  if ls "$WHEELHOUSE"/${stage}-*.whl >/dev/null 2>&1 && [ "${FORCE_REBUILD:-0}" != 1 ]; then
    if [ -f "$stampf" ] && [ "$(cat "$stampf")" = "$fp" ]; then
      log "---------- $stage wheel up to date (inputs unchanged fp=$fp), skipping (FORCE_REBUILD=1 forces a rebuild) ----------"
      return 0
    fi
    if [ -f "$stampf" ]; then
      log "---------- $stage inputs changed (fp $(cat "$stampf") -> $fp), rebuilding ----------"
    else
      log "---------- $stage wheel present but no input stamp yet -> adopting it (fp=$fp) ----------"
      printf '%s\n' "$fp" > "$stampf"
      return 0
    fi
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
  printf '%s\n' "$fp" > "$stampf"
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

# riscv64 / TheRock: this torch was built with USE_MIOPEN=0, but its generated
# HIP code still calls the at::native::miopen_* wrappers, so importing torch
# fails with
#   ImportError: libtorch_hip.so: undefined symbol:
#     _ZN2at6native28miopen_convolution_transposeERKNS_6TensorES3_...
# The runtime image already solves this the same way (a 14 KB shim installed as
# /opt/rocm/lib/libMIOpen.so.1, see docker/miopen-stub/). torch/lib/ is searched
# before the ROCm lib dirs (libtorch_hip.so carries a DT_NEEDED entry for
# libMIOpen.so.1), so dropping the shim there makes the host-side import check
# resolve exactly like the image does. Text models served by vLLM never call the
# MIOpen convolution/batch-norm entry points.
install_miopen_stub() {
  local src="$SCRIPT_DIR/../docker/miopen-stub/libMIOpen.so.1" dst rt
  [ -f "$src" ] || { warn "MIOpen shim missing: $src (importing torch will fail)"; return 0; }
  # torch/lib (searched via $ORIGIN) and dist/rocm/lib (LD_LIBRARY_PATH, and the
  # layout the image ships) both need the shim: the real 473 MB MIOpen does not
  # export the at::native::miopen_* wrappers, and whenever it is found first the
  # import fails with "undefined symbol ...miopen_convolution_transpose".
  dst=$(ls -d "$VENV_STACK"/lib/python3*/site-packages/torch/lib 2>/dev/null | head -1 || true)
  if [ -n "$dst" ] && ! cmp -s "$src" "$dst/libMIOpen.so.1"; then
    log "installing MIOpen shim -> $dst/libMIOpen.so.1 (torch built with USE_MIOPEN=0)"
    run cp -f "$src" "$dst/libMIOpen.so.1"
  fi
  rt="$(rocm_tree)"
  if [ -f "$rt/lib/libMIOpen.so.1.0" ] && ! cmp -s "$src" "$rt/lib/libMIOpen.so.1.0"; then
    log "installing MIOpen shim -> $rt/lib/libMIOpen.so.1.0 (matches the image layout)"
    run cp -f "$src" "$rt/lib/libMIOpen.so.1.0"
  fi
  return 0
}

install_wheel() { # install_wheel <name-glob>
  local n="$1"
  # --force-reinstall: with the same name and version pip would skip the install
  # and leave a stale, broken wheel in the venv
  run "$PIP" install -q --no-deps --force-reinstall "$WHEELHOUSE"/${n}-*.whl
}

# Multi-GPU capability check.
# torch must carry the NCCL backend (on ROCm it is provided by RCCL). If it does
# not, torch.distributed.is_nccl_available() is False and vLLM's tensor-parallel
# (>1) silently falls back to gloo, whose all-reduce cannot be captured into a
# CUDA graph -> "hipErrorStreamCaptureUnsupported: operation not permitted when
# stream is capturing" -> the server fails to start with --compilation-config.
# Single-card (TP=1) serving is unaffected, so this is a warning, not an error.
check_torch_nccl() {
  local out
  out=$("$PY" -c 'import torch.distributed as d; print(d.is_nccl_available())' 2>/dev/null || echo "unknown")
  if [ "$out" = "True" ]; then
    log "torch NCCL backend: available (vLLM tensor-parallel > 1 supported)"
  else
    warn "torch has NO NCCL backend (torch.distributed.is_nccl_available()=$out)"
    warn "  -> vLLM tensor-parallel (>1) falls back to gloo; CUDA graph capture then fails"
    warn "     with 'hipErrorStreamCaptureUnsupported'. Build ROCm with RCCL and rebuild"
    warn "     torch with USE_NCCL=1 to enable multi-GPU. Single-card (TP=1) is unaffected."
  fi
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
  install_miopen_stub
  check_torch_nccl
  log "torch: $("$PY" -c 'import torch;print(torch.__version__)' 2>/dev/null || echo 'pending check')"

  install_runtime_deps          # needed to build and to run vLLM

  build_one triton
  install_wheel triton

  # torchvision is REQUIRED at serving time, not optional: vLLM's model
  # architecture inspection imports it, and without it the server fails with
  #   Error in inspecting model architecture 'Qwen3_5ForConditionalGeneration'
  # (observed on a real machine with a v0.2.0 image that skipped this stage).
  # scripts/wheels/torchvision.sh builds a CPU-only wheel on purpose -- it must
  # NOT see ROCM_HOME, otherwise setup.py hipifies vision.cpp and the link dies
  # on "multiple definition of `vision::cuda_version()'".
  if [ "${BUILD_TORCHVISION:-1}" = 1 ]; then
    build_one torchvision
    install_wheel torchvision
  else
    warn "skipping torchvision (BUILD_TORCHVISION=0) -- vLLM model inspection will fail"
  fi

  build_one vllm
  install_wheel vllm
}

# vLLM runtime dependencies (the source stack bypasses setup.py dependency
# resolution, so they must be installed explicitly)
install_runtime_deps() {
  local idx="${PIP_INDEX_URL:-https://pypi.org/simple}"
  log "installing vLLM runtime dependencies ($idx)"
  # Most of vLLM's binary dependencies have no riscv64 wheel on PyPI, so pip
  # falls back to building them from sdist. Measured on this machine that costs
  # roughly an hour: numpy ~11 min, pillow ~12, grpcio ~10, apache-tvm-ffi ~7.5,
  # sentencepiece ~4.5, cryptography ~3.6, cbor2 ~2.7, cffi/harmony/uvloop ~2
  # each, tiktoken ~1.7, outlines_core ~1.4, pyyaml ~1, psutil <1.
  #
  # RuyiRepo publishes prebuilt manylinux_2_38_riscv64 wheels for most of them,
  # so install the exact versions this image was validated with, using --no-deps
  # (version resolution stays with the requirements pass below) and
  # --only-binary=:all: (never silently fall back to an sdist here).
  #
  # Deliberately NOT taken from RuyiRepo:
  #   grpcio   - repository stops at 1.85.0rc1; the validated build is 1.85.1
  #   psutil   - repository stops at 6.0.0; validated is 7.2.2 and it compiles
  #              in well under a minute
  #   xgrammar / vllm / torch / triton / torchvision
  #            - no usable riscv64 wheel anywhere (xgrammar/vllm), or the
  #              available wheel is the CPU build (torch/triton)
  # Set USE_RUYIREPO=0 to reproduce the old from-source behaviour.
  local ruyi="${RUYIREPO_INDEX:-https://ruyirepo.ruyicommunity.cn/pypi/simple/}"
  RUYI_PREINSTALL_OK=0
  if [ "${USE_RUYIREPO:-1}" = 1 ]; then
    log "pre-installing riscv64 wheels from RuyiRepo"
    if run "$PIP" install -q --index-url "$ruyi" --no-deps --only-binary=:all: \
        numpy==2.5.4 \
        pillow==13.0.0 \
        pyyaml==6.0.3 \
        cbor2==6.2.0.post2 \
        tiktoken==0.14.0 \
        sentencepiece==0.2.2 \
        cryptography==50.0.2 \
        cffi==2.1.1 \
        openai-harmony==0.0.8 \
        outlines-core==0.2.14 \
        uvloop==0.23.0 \
        apache-tvm-ffi==0.1.15.post2; then
      RUYI_PREINSTALL_OK=1
      log "RuyiRepo pre-install ok (12 packages, no source build)"
    else
      warn "RuyiRepo pre-install failed; falling back to PyPI/source builds"
    fi
  else
    log "RuyiRepo pre-install disabled (USE_RUYIREPO=0)"
  fi
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
  #   xgrammar / apache-tvm-ffi:
  #                 vllm/parser/harmony.py imports xgrammar at module level, and
  #                 xgrammar needs tvm_ffi. They are NOT installed by the
  #                 requirements pass above: vLLM pins them with a
  #                 "platform_machine == 'x86_64' or ... 'aarch64'" marker that
  #                 has no riscv64, so pip silently skips them. Only sdist
  #                 exists for riscv64, so this compiles both from source.
  run "$PIP" install -q --index-url "$idx" \
    numpy fastapi uvicorn pydantic tokenizers safetensors huggingface_hub \
    psutil requests tqdm msgspec partial_json_parser cloudpickle typing-inspection \
    jsonschema openai prometheus-fastapi-instrumentator sentencepiece \
    transformers cbor2 pycountry mistral_common || true
  # xgrammar has no riscv64 wheel on either index, so it is always a source
  # build; apache-tvm-ffi comes from RuyiRepo when that succeeded above.
  if [ "${RUYI_PREINSTALL_OK:-0}" = 1 ]; then
    run "$PIP" install --index-url "$idx" xgrammar \
      || warn "xgrammar install failed -- vLLM import of parser/harmony will fail"
  else
    run "$PIP" install --index-url "$idx" apache-tvm-ffi xgrammar \
      || warn "xgrammar/tvm_ffi install failed -- vLLM import of parser/harmony will fail"
  fi
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
  # Re-apply the two torch fix-ups immediately before verification: a later pip
  # step (vLLM dependency resolution) can force-reinstall torch and silently drop
  # both the libMIOpen DT_NEEDED entry and the shim, which is exactly how the
  # 2026-11-26 import failures happened after the earlier fixed-up install.
  # Both helpers are idempotent.
  fix_torch_miopen_needed
  install_miopen_stub
  "$PY" - <<'PYEOF'
import sys
# Everything here is a hard requirement at serving time, so check it always.
# These two in particular were missed by earlier builds and only showed up on a
# real machine:
#   torchvision    -> vLLM model architecture inspection
#                     ("Error in inspecting model architecture 'Qwen3_5...'")
#   xgrammar       -> vllm/parser/harmony.py imports it at module level, and it
#                     in turn needs tvm_ffi (imported under the name tvm_ffi)
# The last entry exercises vLLM's real import path instead of just the package
# name, which is what actually breaks in the field.
mods = [
    "torch",
    "torchvision",
    "triton",
    "xgrammar",
    "tvm_ffi",
    "vllm",
    "vllm.parser.harmony",
]
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
