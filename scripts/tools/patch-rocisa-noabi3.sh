#!/bin/bash
# patch-rocisa-noabi3.sh <repo-root>
# Work around a reproducible SIGSEGV in TensileLite kernel generation on
# riscv64 + Python 3.14: rocisa's nanobind stable-ABI module _rocisa.abi3.so
# (built by AMD clang 23) crashes in libstdc++ __dynamic_cast from rocIsaPass(),
# killing loky workers ~185 s into "Generating assembly kernels" (2026-11-26,
# twice, with only 10-15G RSS -> not memory pressure). Rebuilding the extension
# WITHOUT the stable ABI fixes it (verified: 50198-kernel generation completed,
# 0 segfaults). Idempotent: safe to run before every build.
set -uo pipefail
ROOT="${1:-.}"
H="$ROOT/upstream/therock/build/math-libs/BLAS/hipBLASLt/build"
log(){ echo "[patch-rocisa] $*"; }
[ -f "$H/CMakeCache.txt" ] || { log "hipBLASLt not configured yet; skip"; exit 0; }
CD="$H/CMakeCache.txt"
if grep -q '^ROCISA_USE_STABLE_ABI:BOOL=ON' "$CD" 2>/dev/null; then
  cp -a "$CD" "$CD.rocisa-bak" 2>/dev/null || true
  sed -i 's/^ROCISA_USE_STABLE_ABI:BOOL=ON/ROCISA_USE_STABLE_ABI:BOOL=OFF/' "$CD"
  log "CMakeCache: ROCISA_USE_STABLE_ABI ON -> OFF"
fi
RS="$H/tensilelite/rocisa/rocisa"
if ! ls "$RS"/_rocisa.cpython-*.so >/dev/null 2>&1; then
  log "rebuilding rocisa extension without the stable ABI"
  TGT="$( cd "$H" && ninja -t targets all 2>/dev/null | grep -o 'tensilelite/rocisa/rocisa/_rocisa\.cpython[^:]*\.so' | head -1 )"
  [ -n "$TGT" ] || { log "ERROR: non-abi3 target not found in build.ninja"; exit 1; }
  ( cd "$H" && timeout 3600 ninja "$TGT" >/tmp/rocisa-rebuild.log 2>&1 ) || { log "ERROR: rebuild failed, see /tmp/rocisa-rebuild.log"; exit 1; }
fi
if [ -f "$RS/_rocisa.abi3.so" ]; then
  mv -f "$RS/_rocisa.abi3.so" "$RS/_rocisa.abi3.so.disabled"
  log "disabled stale _rocisa.abi3.so"
fi
PYTHONPATH="$H/tensilelite/rocisa:$H/tensilelite" python3 -c "import rocisa, rocisa.asmpass" 2>/dev/null \
  || { log "ERROR: rocisa import failed after workaround"; exit 1; }
log "OK: rocisa loaded from $(basename "$(ls "$RS"/_rocisa.cpython-*.so | head -1)")"
exit 0