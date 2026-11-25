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

# Memory safety for the compiler subproject (OOM post-mortem 2026-11-25).
# At -j64 the LLVM/flang compile peaked past 121 GB: one cc1plus compiling flang
# objects holds ~2.7 GB RSS, the kernel OOM-killed compilers at 17:27 and the
# whole host wedged (sshd stopped forking, the CI job lost its runner). TheRock
# forwards these two knobs into the amd-llvm subproject, whose ninja ignores the
# top-level -j:
#   FLANG_PARALLEL_COMPILE_JOBS  cap concurrent flang compiles (the memory hog)
#   LLVM_PARALLEL_LINK_JOBS      cap concurrent lld links (also memory heavy)
FLANG_COMPILE_JOBS="${FLANG_COMPILE_JOBS:-24}"
LLVM_LINK_JOBS="${LLVM_LINK_JOBS:-8}"
CMAKE_ARGS+=(
  "-DFLANG_PARALLEL_COMPILE_JOBS=$FLANG_COMPILE_JOBS"
  "-DLLVM_PARALLEL_LINK_JOBS=$LLVM_LINK_JOBS"
)
if [ "${DRY_RUN:-0}" != 1 ] && [ -f "$THEROCK_BUILD/CMakeCache.txt" ]; then
  for kv in "FLANG_PARALLEL_COMPILE_JOBS=$FLANG_COMPILE_JOBS" "LLVM_PARALLEL_LINK_JOBS=$LLVM_LINK_JOBS"; do
    k="${kv%%=*}"; v="${kv#*=}"
    cv="$(sed -n "s/^${k}:[A-Z]*=//p" "$THEROCK_BUILD/CMakeCache.txt" | head -1)"
    if [ "$cv" != "$v" ]; then
      RECONFIGURE=1
      log "cache $k='$cv' -> '$v' -> forcing RECONFIGURE=1"
    fi
  done
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
# gfx1201-only: pin subproject DEFAULT_GPUS
# ---------------------------------------------------------------------------
# THEROCK_AMDGPU_TARGETS only reaches subprojects that honour it. hipBLASLt
# derives its architecture list from DEFAULT_GPUS, which comes from the
# gfx120X-all family in cmake/therock_amdgpu_targets.cmake. Measured 2026-11-25:
# a CI run configured hipBLASLt with "gfx1200;gfx1201" and regenerated the whole
# Tensile device library for both arches. Drop gfx1200 from that family so
# DEFAULT_GPUS has exactly one member; that changes a cache input, so force a
# reconfigure. Idempotent, and only active when the target is gfx1201.
if [ "${GPU_TARGET:-}" = gfx1201 ] && [ "${THEROCK_PIN_AMDGPU_TARGET:-1}" = 1 ]; then
  pin_out="$("$SCRIPT_DIR/tools/gfx1201-only.sh" "$SRC_TREE/cmake/therock_amdgpu_targets.cmake" 2>&1)" || {
    warn "gfx1201-only: could not patch therock_amdgpu_targets.cmake; hipBLASLt may build gfx1200 too"
    pin_out=""
  }
  [ -n "$pin_out" ] && printf '%s
' "$pin_out" | sed 's/^/  /'
  case "$pin_out" in
    *CHANGED=1*) RECONFIGURE=1; log "gfx1201-only: family list changed -> forcing RECONFIGURE=1" ;;
  esac
fi

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
# Memory-aware clamp. Measured 2026-11-25 on this host: one cc1plus compiling
# LLVM/flang objects peaks at ~2.7 GB RSS; with -j64 that is >170 GB and the
# kernel OOM-killed compilers at 17:27, which wedged the whole box (sshd could
# not fork, the CI job lost its runner). Budget 80% of MemAvailable at 3 GB per
# concurrent compiler so the build degrades in speed instead of dying.
if [ "$DRY_RUN" != 1 ]; then
  mem_gb=$(awk '/MemAvailable/{printf "%d",$2/1024/1024}' /proc/meminfo)
  safe_jobs=$(( mem_gb * 80 / 100 / 3 ))
  [ "$safe_jobs" -lt 4 ] && safe_jobs=4
  if [ "$JOBS" -gt "$safe_jobs" ]; then
    log "clamp parallel $JOBS -> $safe_jobs (MemAvailable ${mem_gb}G, ~3G per compiler)"
    JOBS=$safe_jobs
  fi
fi

log "compiling (parallel=$JOBS)... log: $LOG_DIR/build.log"
# Sub-build parallelism -------------------------------------------------------
# Each subproject is built by `cmake --build <dir>` with no -j (verified in
# build/logs/*_build.log: the EXEC line is plain `cmake --build <dir>`), so
# every concurrently running subproject spawns its own full-machine job set.
# Measured 2026-11-25 22:40: rccl + composable_kernel + hipBLASLt + rocFFT were
# running together -> 247 clang processes on 80 cores, load 160, 0% idle, while
# composable_kernel only finished 1.3 of 1015 edges per minute. `cmake --build`
# honours CMAKE_BUILD_PARALLEL_LEVEL from the environment, so one shared value
# keeps the SUM of sub-builds near the core count (and bounds memory as well).
# Override with THEROCK_SUBPROJECT_JOBS=<n>; 0 leaves the old behaviour.
if [ "${THEROCK_SUBPROJECT_JOBS:-24}" != 0 ]; then
  export CMAKE_BUILD_PARALLEL_LEVEL="${THEROCK_SUBPROJECT_JOBS:-24}"
  log "sub-build parallelism: CMAKE_BUILD_PARALLEL_LEVEL=$CMAKE_BUILD_PARALLEL_LEVEL (sum over subprojects; THEROCK_SUBPROJECT_JOBS=$THEROCK_SUBPROJECT_JOBS)"
fi

# Progress heartbeat ---------------------------------------------------------
# The top-level ninja advances once per whole subproject, so hours can pass
# without a new line in build.log (2026-11-25: hipBLASLt Tensile launched 50198
# assembly tasks and printed nothing for ~2 h, which looked like a hang). Append
# one line every 5 min with each subproject's own edge counter plus memory/load,
# so "slow" can be told apart from "dead".
if [ "$DRY_RUN" != 1 ]; then
  (
    while :; do
      sleep 300
      line="$(date +%H:%M:%S) heartbeat"
      for f in "$THEROCK_BUILD"/logs/*_build.log; do
        [ -f "$f" ] || continue
        p="$(grep -aoE '\[[0-9]+/[0-9]+\]' "$f" | tail -1)"
        [ -n "$p" ] && line="$line $(basename "$f" _build.log)=$p"
      done
      line="$line mem=$(awk '/MemTotal/{t=$2}/MemAvailable/{a=$2}END{printf "%dG/%dG",(t-a)/1048576,t/1048576}' /proc/meminfo)"
      line="$line load=$(cut -d' ' -f1 /proc/loadavg)"
      printf '%s\n' "$line" >> "$LOG_DIR/build.heartbeat.log"
    done
  ) &
  HB_PID=$!
  trap 'kill "$HB_PID" 2>/dev/null || true' EXIT
fi

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

ensure_dist_dev_artifacts
log "build done"
