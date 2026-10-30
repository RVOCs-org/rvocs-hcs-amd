#!/usr/bin/env bash
# Stage 6: image acceptance (in-container smoke checks)
#   GPU independent: ROCm layout, shared libraries, kpack, Python stack imports,
#                    vllm command, entrypoint
#   GPU dependent  : with GPU_RUN=1 mount /dev/kfd and /dev/dri, then check
#                    rocminfo and that torch sees the device
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_cmd docker
if [ "$DRY_RUN" != 1 ]; then
  docker image inspect "$IMAGE_TAG" >/dev/null 2>&1 || die "image does not exist: $IMAGE_TAG (run --stage image first)"
fi

GPU_ARGS=()
if [ "${GPU_RUN:-0}" = 1 ]; then
  [ -e /dev/kfd ] || die "no /dev/kfd on this host, cannot run the GPU smoke test"
  GPU_ARGS=(--device=/dev/kfd --device=/dev/dri --ipc=host
            --group-add video --group-add render --security-opt seccomp=unconfined)
  log "GPU smoke test enabled (mounting /dev/kfd and /dev/dri)"
fi

INNER=$(cat <<'EOS'
set -u
fail=0
check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then echo "  [ OK ] $d"; else echo "  [FAIL] $d"; fail=1; fi; }
soft()  { local d="$1"; shift; if "$@" >/dev/null 2>&1; then echo "  [ OK ] $d"; else echo "  [ -- ] $d"; fi; }

echo "== system =="
echo "  arch : $(uname -m)   expected: ${EXPECT_ARCH:-?}"
check "arch matches" test "$(uname -m)" = "${EXPECT_ARCH:-$(uname -m)}"
echo "  os   : $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")"

echo "== ROCm install tree =="
check "/opt/rocm/bin"             test -d /opt/rocm/bin
check "rocminfo"                  test -x /opt/rocm/bin/rocminfo
check "hipconfig"                 test -x /opt/rocm/bin/hipconfig
check "libamdhip64"               bash -c 'ls /opt/rocm/lib/libamdhip64.so* >/dev/null 2>&1'
check "libhsa-runtime64"          bash -c 'ls /opt/rocm/lib/libhsa-runtime64.so* >/dev/null 2>&1'
echo "  version marker: $(cat /opt/rocm/.amd-therock-version 2>/dev/null || echo '(none)')"

echo "== device code kpack =="
if [ -d /opt/rocm/.kpack ]; then
  n=$(ls /opt/rocm/.kpack | grep -c -- "${EXPECT_GFX:-}" || true)
  check "kpack entries for ${EXPECT_GFX} (${n})" test "${n:-0}" -gt 0
else
  echo "  [ -- ] no .kpack directory (legacy layout)"
fi

echo "== dynamic linking =="
missing=$(ldd /opt/rocm/lib/libamdhip64.so* 2>/dev/null | grep -c 'not found' || true)
check "libamdhip64 dependencies complete" test "${missing:-0}" -eq 0

if [ "${IMAGE_KIND:-vllm}" = "vllm" ]; then
  V="${STACK_VENV:-/opt/venv-torch}"
  echo "== Python stack ($V) =="
  check "venv python executable"   test -x "$V/bin/python"
  check "vllm command"             test -x "$V/bin/vllm"
  check "entrypoint script"        test -x /entrypoint.sh
  check "import torch"             "$V/bin/python" -c 'import torch'
  check "import torchvision"       "$V/bin/python" -c 'import torchvision'
  check "import triton"            "$V/bin/python" -c 'import triton'
  check "import vllm"              "$V/bin/python" -c 'import vllm'
  check "torch is the ROCm build"  "$V/bin/python" -c 'import torch,sys; sys.exit(0 if torch.version.hip else 1)'
  # The vllm CLI infers the device type (torch.cuda / amdsmi), which necessarily
  # fails without a GPU: "Failed to infer device type". That is a host limitation,
  # not an image defect.
  if [ -e /dev/kfd ] || [ -e /dev/dri ]; then
    check "vllm --version"        "$V/bin/vllm" --version
    check "vllm serve argument parse" "$V/bin/vllm" serve --help
  else
    soft "vllm --version"         "$V/bin/vllm" --version
    soft "vllm serve argument parse"  "$V/bin/vllm" serve --help
    echo "  [NOTE] no /dev/kfd or /dev/dri in the container: the vllm CLI cannot infer the device type, so the two checks above are soft"
  fi
  echo "  versions: $("$V/bin/python" -c 'import torch,vllm,triton;print("torch",torch.__version__,"| triton",triton.__version__,"| vllm",vllm.__version__)' 2>/dev/null)"
  soft "bash keep-alive passthrough" bash -c 'timeout 2 /entrypoint.sh bash -c "echo ok" | grep -q ok'
  soft "benchmarks bundled"          test -d /opt/vllm/benchmarks
  soft "wheel archive"               bash -c 'ls /opt/vllm-wheels/*.whl >/dev/null 2>&1'
fi

echo "== tools =="
soft "rocm-smi"   test -f /opt/rocm/bin/rocm-smi
soft "amd-smi"    test -f /opt/rocm/bin/amd-smi

if [ "${GPU_RUN:-0}" = 1 ]; then
  echo "== GPU (needs /dev/kfd) =="
  if /opt/rocm/bin/rocminfo >/tmp/rocminfo.txt 2>&1; then
    if grep -q "gfx" /tmp/rocminfo.txt; then
      echo "  [ OK ] rocminfo detected: $(grep -o 'gfx[0-9a-z]*' /tmp/rocminfo.txt | sort -u | tr '\n' ' ')"
    else
      echo "  [FAIL] rocminfo reported no gfx agent"; fail=1
    fi
    if [ -n "${EXPECT_GFX:-}" ] && ! grep -q "${EXPECT_GFX}" /tmp/rocminfo.txt; then
      echo "  [FAIL] expected architecture ${EXPECT_GFX} not found"; fail=1
    fi
  else
    echo "  [FAIL] rocminfo failed"; sed -n '1,20p' /tmp/rocminfo.txt; fail=1
  fi
  if [ "${IMAGE_KIND:-vllm}" = "vllm" ]; then
    V="${STACK_VENV:-/opt/venv-torch}"
    if "$V/bin/python" -c 'import torch; assert torch.cuda.is_available(); print("  [ OK ] torch sees GPU:", torch.cuda.get_device_name(0))' 2>/tmp/torchgpu.txt; then :; else
      echo "  [FAIL] torch does not see a GPU"; sed -n '1,10p' /tmp/torchgpu.txt; fail=1
    fi
  fi
fi

echo
if [ "$fail" = 0 ]; then echo "VERIFY_OK"; else echo "VERIFY_FAILED"; exit 1; fi
EOS
)

log "verifying image: $IMAGE_TAG (kind=$IMAGE_KIND)"
run docker run --rm "${GPU_ARGS[@]}" \
  -e EXPECT_ARCH="$ARCH" \
  -e EXPECT_GFX="$GPU_TARGET" \
  -e GPU_RUN="${GPU_RUN:-0}" \
  -e IMAGE_KIND="$IMAGE_KIND" \
  -e STACK_VENV="$STACK_VENV" \
  --entrypoint /bin/bash "$IMAGE_TAG" -c "$INNER"

log "verification passed"
