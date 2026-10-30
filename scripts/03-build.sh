#!/usr/bin/env bash
# Stage 3: TheRock source build (cmake configure + ninja)
#   Artifact: $DIST_DIR (flattened, complete ROCm SDK including .kpack device code)
#
# Note: once TheRock's build directory is configured, do not reconfigure it for a
#       different family. After a baseline/family change, delete build/ or run
#       scripts/tools/baseline.sh clean.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

if [ "$MODE" = prebuilt ]; then
  log "prebuilt mode needs no local compilation, skipping the build stage"
  exit 0
fi

require_cmd cmake
require_cmd ninja

if [ ! -f "$SRC_TREE/CMakeLists.txt" ]; then
  [ "$DRY_RUN" = 1 ] || die "sources not ready: $SRC_TREE (run --stage fetch first)"
  warn "dry-run: sources are not ready yet: $SRC_TREE"
fi

# ---------------------------------------------------------------------------
# Component set -> cmake switches
# ---------------------------------------------------------------------------
components_flags "$COMPONENTS" || die "unknown component set: $COMPONENTS"

CMAKE_ARGS=(
  "-DCMAKE_BUILD_TYPE=$BUILD_TYPE"
  "-DTHEROCK_AMDGPU_FAMILIES=$GPU_FAMILY"
)
CMAKE_ARGS+=( "${THEROCK_CMAKE_ARGS[@]}" )

# riscv64: test targets must be off. BUILD_TESTING=ON pulls in gtest static
# libraries, which triggers a clang/lld bug with GCC-built COMDAT plus exception
# table sections (ld.lld: relocation refers to a symbol in a discarded section
# .LEHB/.LEHE). Set THEROCK_BUILD_TESTING=1 to force tests on when needed.
if [ "$ARCH" = riscv64 ] && [ "${THEROCK_BUILD_TESTING:-0}" != 1 ]; then
  CMAKE_ARGS+=( -DBUILD_TESTING=OFF )
fi

# Extra cmake arguments (space separated), e.g.:
#   THEROCK_EXTRA_ARGS="-DTHEROCK_ENABLE_RCCL=ON -DTHEROCK_BUNDLE_3RDPARTY=OFF"
if [ -n "$THEROCK_EXTRA_ARGS" ]; then
  # shellcheck disable=SC2206
  CMAKE_ARGS+=( $THEROCK_EXTRA_ARGS )
fi

# ccache (optional, speeds up repeated builds significantly)
# Disabled by default on riscv64: the combination of ccache's --offload-compress
# with amdclang device code is unverified on riscv and the validated build does
# not use it. Force it with USE_CCACHE=1.
CCACHE_ON=0
if command -v ccache >/dev/null 2>&1; then
  case "${USE_CCACHE:-auto}" in
    0|off|no)  CCACHE_ON=0 ;;
    1|on|yes)  CCACHE_ON=1 ;;
    *)         [ "$ARCH" = riscv64 ] && CCACHE_ON=0 || CCACHE_ON=1 ;;
  esac
fi
if [ "$CCACHE_ON" = 1 ] && [ "$ARCH" = riscv64 ] && [ "${USE_CCACHE:-auto}" = auto ]; then
  log "ccache stays disabled by default on riscv64 (USE_CCACHE=1 forces it)"
  CCACHE_ON=0
fi
if [ "$CCACHE_ON" = 1 ]; then
  if [ -f "$SRC_TREE/build_tools/setup_ccache.py" ]; then
    # TheRock recommends generating a fixed .ccache configuration with this script
    if [ "$DRY_RUN" != 1 ] && eval "$(python3 "$SRC_TREE/build_tools/setup_ccache.py" 2>/dev/null)"; then
      log "ccache enabled: $(ccache --version | head -1)"
    else
      warn "setup_ccache.py had no effect, using ccache defaults"
    fi
  fi
  CMAKE_ARGS+=(
    -DCMAKE_C_COMPILER_LAUNCHER=ccache
    -DCMAKE_CXX_COMPILER_LAUNCHER=ccache
    -DCMAKE_HIP_COMPILER_LAUNCHER=ccache
  )
fi

# Use the SYSTEM python3 explicitly, not the venv from the fetch stage:
# if CMake resolves Python3_EXECUTABLE from the venv, hipBLASLt fails while
# generating Tensile device libraries because rocisa (nanobind) reports a leaked
# function at interpreter exit, so tensilelite-device-libraries-TensileLogic.stamp
# never gets produced. The reference implementation (103) also uses /usr/bin/python3.
SYSTEM_PYTHON="${SYSTEM_PYTHON:-/usr/bin/python3}"
[ -x "$SYSTEM_PYTHON" ] || SYSTEM_PYTHON="$(command -v python3)"
CMAKE_ARGS+=( "-DPython3_EXECUTABLE=$SYSTEM_PYTHON" )

# meson is installed into ~/.local/bin (pip --user) and non-interactive shells do
# not have that on PATH, while THEROCK_BUNDLE_SYSDEPS=ON configures check for it
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) export PATH="$HOME/.local/bin:$PATH" ;;
esac
command -v meson >/dev/null 2>&1 || warn "meson not found on PATH (needed when THEROCK_BUNDLE_SYSDEPS=ON): pip3 install --user meson"

log "build python: $SYSTEM_PYTHON (system interpreter, not the venv)"

# ---------------------------------------------------------------------------
# configure
# ---------------------------------------------------------------------------
CACHE="$THEROCK_BUILD/CMakeCache.txt"
if [ -f "$CACHE" ]; then
  cached_family=$(sed -n 's/^THEROCK_AMDGPU_FAMILIES[^=]*=//p' "$CACHE" | head -1)
  if [ -n "$cached_family" ] && [ "$cached_family" != "$GPU_FAMILY" ]; then
    die "the build directory is configured for family=$cached_family, which differs from $GPU_FAMILY derived from --gpu.
   TheRock cannot reconfigure an existing build directory for a different family. Run:
      scripts/tools/baseline.sh clean        # removes build/ (sources and patches are kept)
   then run --stage build again"
  fi
  if [ "${RECONFIGURE:-0}" = 1 ]; then
    log "RECONFIGURE=1 -> reconfiguring the existing build directory (needed after component changes)"
    log "  ${CMAKE_ARGS[*]}"
    run cmake -B "$THEROCK_BUILD" -GNinja "$SRC_TREE" "${CMAKE_ARGS[@]}"
  else
    log "build directory already configured ($THEROCK_BUILD), skipping configure"
    log "  after changing component switches (--components / THEROCK_EXTRA_ARGS) re-run with RECONFIGURE=1"
  fi
else
  log "configure: family=$GPU_FAMILY  components=$COMPONENTS"
  log "  ${CMAKE_ARGS[*]}"
  run cmake -B "$THEROCK_BUILD" -GNinja "$SRC_TREE" "${CMAKE_ARGS[@]}"
fi

# ---------------------------------------------------------------------------
# build
# ---------------------------------------------------------------------------
log "compiling (parallel=$JOBS)... log: $LOG_DIR/build.log"
if [ "$DRY_RUN" = 1 ]; then
  printf '  [dry-run] cmake --build %s -j %s\n' "$THEROCK_BUILD" "$JOBS"
else
  cmake --build "$THEROCK_BUILD" -j "$JOBS" 2>&1 | tee -a "$LOG_DIR/build.log"
fi

# ---------------------------------------------------------------------------
# result checks
# ---------------------------------------------------------------------------
if [ "$DRY_RUN" != 1 ]; then
  [ -d "$DIST_DIR" ] || die "build artifact not found: $DIST_DIR"
  log "build artifact: $DIST_DIR ($(du -sh "$DIST_DIR" | awk '{print $1}'))"
  if [ -d "$DIST_DIR/.kpack" ]; then
    n=$(ls -1 "$DIST_DIR/.kpack" | grep -c -- "$GPU_TARGET" || true)
    log "  device code kpack ($GPU_TARGET): ${n:-0} entries"
    [ "${n:-0}" -gt 0 ] || warn "no kpack for $GPU_TARGET, check whether THEROCK_AMDGPU_FAMILIES=$GPU_FAMILY is correct"
  else
    warn "$DIST_DIR/.kpack not found (older TheRock may inline device code in the .so files)"
  fi
fi

log "build done"
