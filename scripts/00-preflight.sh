#!/usr/bin/env bash
# Stage 0: environment self-check (read-only; reports problems and gives one-line installs)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

FAIL=0
ok()   { printf '  [ OK ] %s\n' "$*"; }
bad()  { printf '  [FAIL] %s\n' "$*"; FAIL=1; }
note() { printf '  [ -- ] %s\n' "$*"; }

echo "== host =="
ok "arch=$(uname -m)  target arch=$ARCH  jobs=$JOBS"
[ "$(uname -m)" = "$ARCH" ] || note "target arch differs from host ($ARCH != $(uname -m)): only reasonable with cross/emulated builds"
mem_total=$(awk '/^MemTotal/ {print int($2/1048576)}' /proc/meminfo 2>/dev/null || echo 0)
if [ "$MODE" = source ]; then
  if [ "$mem_total" -ge 60 ]; then ok "memory ${mem_total}GB"
  else note "memory ${mem_total}GB - lower --jobs on small hosts (amd-llvm linking takes 4-8GB per job)"; fi
else
  ok "memory ${mem_total}GB"
fi

echo "== toolchain =="
for c in git curl tar; do
  command -v "$c" >/dev/null 2>&1 && ok "$c $(command -v "$c")" || bad "missing $c"
done

if [ "$MODE" = source ]; then
  for c in cmake ninja python3; do
    command -v "$c" >/dev/null 2>&1 && ok "$c" || bad "missing $c (sudo apt-get install -y cmake ninja-build python3 python3-venv)"
  done
  # gfortran is often installed with a version suffix (gfortran-15) while TheRock
  # needs an executable named gfortran
  if command -v gfortran >/dev/null 2>&1; then
    ok "gfortran $(command -v gfortran)"
  elif ls /usr/bin/gfortran-* >/dev/null 2>&1; then
    note "only $(basename "$(ls /usr/bin/gfortran-* | head -1)") is present; the gfortran symlink is missing:
         sudo ln -s $(ls /usr/bin/gfortran-* | head -1) /usr/local/bin/gfortran"
  else
    bad "missing gfortran (sudo apt-get install -y gfortran)"
  fi
  if command -v cmake >/dev/null 2>&1; then
    cmake_ver=$(cmake --version | head -1 | awk '{print $3}')
    ok "cmake version $cmake_ver"
  fi
  if command -v ninja >/dev/null 2>&1; then ok "ninja $(ninja --version)"; fi

  # TheRock's sysdeps are built with meson (the docs ask for 1.12.0)
  if command -v meson >/dev/null 2>&1; then
    ok "meson $(meson --version 2>/dev/null)"
  else
    note "missing meson (needed by TheRock sysdeps): pip3 install --user meson && export PATH=\$HOME/.local/bin:\$PATH"
  fi

  # patchelf: TheRock's kpack unpacking needs the build carrying PR#544
  if command -v patchelf >/dev/null 2>&1; then
    note "patchelf $(patchelf --version 2>&1 | awk '{print $2}') - if kpack splitting reports ELF errors, install the pinned upstream build:
         sudo env INSTALL_PREFIX=/usr/local $SRC_TREE/dockerfiles/install_pinned_patchelf.sh"
  else
    note "patchelf is not installed: kpack unpacking will fail. Before building run
         sudo env INSTALL_PREFIX=/usr/local $SRC_TREE/dockerfiles/install_pinned_patchelf.sh"
  fi

  # python dependencies needed by kpack splitting
  if python3 -c 'import msgpack, zstandard' >/dev/null 2>&1; then
    ok "python modules msgpack/zstandard"
  else
    note "missing msgpack or zstandard (needed for kpack splitting): pip3 install --user msgpack zstandard"
  fi
else
  for c in curl tar; do require_cmd "$c"; done
  ok "prebuilt mode: no local compiler needed"
fi

echo "== docker =="
if command -v docker >/dev/null 2>&1; then
  ok "docker $(docker --version 2>/dev/null | awk '{print $3}' | tr -d ,)"
  if docker info >/dev/null 2>&1; then
    ok "docker daemon reachable (BuildKit: $(docker buildx version 2>/dev/null | awk '{print $2}' | head -1))"
  else
    bad "docker daemon unreachable (add your user to the docker group, or use sudo)"
  fi
  docker buildx version >/dev/null 2>&1 || note "installing buildx is recommended (--build-context needs BuildKit >= 0.11)"
else
  bad "missing docker"
fi

echo "== disk =="
if [ "$MODE" = source ]; then
  need=220
else
  need=40
fi
avail=$(df -Pk "$REPO_ROOT" | awk 'NR==2 {print int($4/1048576)}')
if [ "$avail" -ge "$need" ]; then ok "${avail}GB available (>= ${need}GB recommended)"
else bad "${avail}GB available < ${need}GB recommended (a source build needs 200GB+)"; fi

echo "== upstream baseline =="
pin=$(therock_pin_commit)
if [ -z "$pin" ]; then
  bad "no upstream/therock submodule gitlink found (.gitmodules missing or the repository is incomplete)"
else
  ok "pin = ${pin:0:12} ($(git -C "$REPO_ROOT" config -f .gitmodules --get submodule.upstream/therock.url 2>/dev/null || echo '?'))"
  if [ -d "$SRC_TREE/.git" ] || [ -f "$SRC_TREE/.git" ]; then
    head=$(therock_head)
    if [ "$head" = "$pin" ]; then ok "submodule work tree = pin"
    else note "submodule work tree ${head:0:12} != pin ${pin:0:12} (--stage fetch synchronizes it)"; fi
  else
    note "submodule not initialized (--stage fetch clones it)"
  fi
fi

if is_porting_branch; then
  echo "== patch layer =="
  ok "patches/$ARCH (components: $(patch_components | tr '\n' ' '))"
  miss=0
  for comp in $(patch_components); do
    s="$(patch_root)/$comp/series"
    [ -f "$s" ] || { note "component $comp has no series file"; continue; }
    while IFS= read -r p; do
      case "$p" in ''|'#'*) continue ;; esac
      [ -f "$(patch_root)/$comp/$p" ] || { bad "patch file missing: patches/$ARCH/$comp/$p"; miss=1; }
    done < "$s"
  done
  [ "$miss" = 0 ] && ok "every patch referenced by the series is present"
else
  note "this branch has no patches/ (porting layer disabled)"
fi

echo
if [ "$FAIL" = 0 ]; then
  log "PREFLIGHT_OK"
else
  die "PREFLIGHT_FAILED (fix the [FAIL] items above and retry)"
fi
