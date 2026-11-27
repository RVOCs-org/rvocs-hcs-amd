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

source "$SCRIPT_DIR/lib/dist-dev-artifacts.sh"
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

# ---- pin the GPU architecture ----------------------------------------------
# TheRock expands THEROCK_AMDGPU_FAMILIES into a per-arch target list, but that
# expansion only lives in a local scope: the THEROCK_AMDGPU_TARGETS cache entry
# ends up EMPTY, so subprojects get configured with an empty GPU_TARGETS. Any
# component whose CMakeLists has a built-in default then builds for every GPU it
# knows about - RCCL does exactly that (`GPU_TARGETS` defaults to `DEFAULT_GPUS`
# in projects/rccl/CMakeLists.txt). Measured on this tree (gfx1201 / R9700):
#
#   unpinned : rccl configured with 23 architectures -> 70162 ninja edges,
#              and after ~9 hours gfx1201 still had zero object files,
#   pinned   : rccl configured with gfx1200;gfx1201   -> 5790 ninja edges.
#
# So pin the resolved arch explicitly. Notes:
#   * THEROCK_AMDGPU_DIST_BUNDLE_NAME must be given too, otherwise TheRock
#     aborts with "More than one AMDGPU target bundle selected
#     (gfx120X-all;gfx1201)" - the family and the explicit target are both
#     counted as bundle selections. It only affects artifact naming
#     (therock_artifacts.cmake), not the target set.
#   * Keep the bundle name equal to the family so artifact names stay stable.
#   * A user-supplied -DTHEROCK_AMDGPU_TARGETS in THEROCK_EXTRA_ARGS (below)
#     still wins, since later -D arguments override earlier ones.
#   * THEROCK_PIN_AMDGPU_TARGET=0 restores the old (multi-arch) behaviour.
if [ -n "${GPU_TARGET:-}" ] && [ "${THEROCK_PIN_AMDGPU_TARGET:-1}" = 1 ]; then
  CMAKE_ARGS+=(
    "-DTHEROCK_AMDGPU_TARGETS=$GPU_TARGET"
    "-DTHEROCK_AMDGPU_DIST_BUNDLE_NAME=${GPU_FAMILY:-$GPU_TARGET}"
    "-DTHEROCK_TEST_AMDGPU_TARGETS=$GPU_TARGET"
  )
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
# Keep the build hermetic: a host ROCm install (e.g. /opt/rocm -> rocm7.14.0)
# leaks into sub-projects through find_package(OpenMP) ->
#   CMakeCache: OpenMP_DIR=/opt/rocm/lib/cmake/openmp
#   compile:    -isystem /opt/rocm/lib/clang/20/include
# That older clang resource dir shadows the in-tree clang's <stdint.h> wrapper
# (same include guard, include_next chain breaks) and the device pass dies with
# "unknown type name 'uint64_t'" in __clang_hip_math.h (rocWMMA samples, on any
# machine that has a system ROCm). Hide host ROCm from find_* and scrub the
# env vars; TheRock itself does the same for the amd-llvm sub-build.
if [ -n "${THEROCK_IGNORE_HOST_ROCM:-1}" ]; then
  export CMAKE_IGNORE_PREFIX_PATH="/opt/rocm${CMAKE_IGNORE_PREFIX_PATH:+;$CMAKE_IGNORE_PREFIX_PATH}"
  unset ROCM_PATH ROCM_HOME ROCM_DIR HIP_PATH HIP_DIR 2>/dev/null || true
fi

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
# The explicit -j only steers the outer ninja. TheRock's per-component builds
# (teatime.py -> `cmake --build` without -j) take their parallelism from
# CMAKE_BUILD_PARALLEL_LEVEL, exported from JOBS in lib/common.sh.
log "compiling (parallel=$JOBS, nested=$CMAKE_BUILD_PARALLEL_LEVEL)... log: $LOG_DIR/build.log"
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

# ---------------------------------------------------------------------------
# rccl-tests (NCCL benchmark tools: all_reduce_perf, ...)
# ---------------------------------------------------------------------------
# Not part of the TheRock build graph: rccl is configured with BUILD_TESTS=OFF
# and rocm-systems never adds the rccl-tests subproject, so the *_perf tools
# are missing from the dist. Build them from the in-tree source project
# against $DIST_DIR and install into it - 05-image.sh copies the dist tree
# wholesale, so the tools ship in the images automatically.
# ROCM_PATH must be explicit: rccl-tests' toolchain file and its
# CMAKE_INSTALL_PREFIX both default to /opt/rocm (host install). GPU_TARGETS
# must be pinned, otherwise the project compiles for every arch in its
# DEFAULT_GPUS list (14 targets).
if [ "${BUILD_RCCL_TESTS:-1}" = 1 ]; then
  RCCL_TESTS_SRC="$SRC_TREE/rocm-systems/projects/rccl-tests"
  RCCL_TESTS_BUILD="$THEROCK_BUILD/rccl-tests"
  if [ ! -f "$RCCL_TESTS_SRC/CMakeLists.txt" ]; then
    warn "rccl-tests sources not found: $RCCL_TESTS_SRC (skipping)"
  elif [ "$DRY_RUN" = 1 ]; then
    printf '  [dry-run] cmake -B %s -GNinja -S %s -DROCM_PATH=%s -DGPU_TARGETS=%s -DUSE_MPI=OFF\n' \
      "$RCCL_TESTS_BUILD" "$RCCL_TESTS_SRC" "$DIST_DIR" "$GPU_TARGET"
  else
    log "building rccl-tests -> $DIST_DIR/bin (log: $LOG_DIR/rccl-tests.log)"
    cmake -B "$RCCL_TESTS_BUILD" -GNinja -S "$RCCL_TESTS_SRC" \
      -DCMAKE_BUILD_TYPE=Release \
      -DROCM_PATH="$DIST_DIR" \
      -DCMAKE_INSTALL_PREFIX="$DIST_DIR" \
      -DCMAKE_INSTALL_RPATH="\$ORIGIN/../lib" \
      -DGPU_TARGETS="$GPU_TARGET" \
      -DUSE_MPI=OFF \
      2>&1 | tee -a "$LOG_DIR/rccl-tests.log"
    cmake --build "$RCCL_TESTS_BUILD" -j "$JOBS" 2>&1 | tee -a "$LOG_DIR/rccl-tests.log"
    cmake --install "$RCCL_TESTS_BUILD" 2>&1 | tee -a "$LOG_DIR/rccl-tests.log"
    # cmake's install-time RPATH rewrite leaves the host-absolute build path
    # ($DIST_DIR/lib) in the binaries; rewrite to the portable $ORIGIN-relative
    # form the rest of the dist tree uses, so the tools also run without
    # LD_LIBRARY_PATH set (e.g. bare `docker exec ... /opt/rocm/bin/*_perf`).
    if command -v patchelf >/dev/null 2>&1; then
      for t in "$DIST_DIR"/bin/*_perf; do
        patchelf --set-rpath '$ORIGIN/../lib' "$t" 2>>"$LOG_DIR/rccl-tests.log" || true
      done
    else
      warn "patchelf not found: rccl-tests keep a host-absolute RUNPATH (image ENV LD_LIBRARY_PATH still resolves it)"
    fi
    n=$(find "$DIST_DIR/bin" -maxdepth 1 -type f -name '*_perf' | wc -l)
    if [ "${n:-0}" -gt 0 ]; then
      log "rccl-tests installed: $n perf tools in $DIST_DIR/bin"
    else
      warn "rccl-tests install produced no *_perf tools, check $LOG_DIR/rccl-tests.log"
    fi
  fi
fi

ensure_dist_dev_artifacts
log "build done"
