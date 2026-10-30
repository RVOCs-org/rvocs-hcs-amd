#!/usr/bin/env bash
# Stage 1: fetch sources / artifacts
#   source   mode: synchronize the upstream/therock submodule, then fetch all
#                  TheRock component sources
#   prebuilt mode: download the official ROCm tarball (per GPU family + version)
#                  and unpack it
#   In both modes, when wheel-mode=source and the artifact is a vllm image, the
#   framework-side sources are fetched too (torch / torchvision / triton / vLLM,
#   see config/sources.sh)
# Idempotent: already prepared steps are skipped, so it can run repeatedly.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

resolve_proxy
require_cmd git
require_cmd curl

# ===========================================================================
# A. Source mode
# ===========================================================================
fetch_sources_mode() {
  [ -f "$REPO_ROOT/.gitmodules" ] || die "missing .gitmodules (incomplete repository)"

  log "syncing the TheRock submodule (pin=$(therock_pin_commit | cut -c1-12))..."
  run git -C "$REPO_ROOT" submodule sync --recursive upstream/therock
  # do not force-overwrite local changes when a work tree already exists; git keeps dirty content
  run git -C "$REPO_ROOT" submodule update --init upstream/therock

  local pin head
  pin=$(therock_pin_commit)
  head=$(therock_head)
  if [ "$DRY_RUN" != 1 ]; then
    [ -n "$head" ] || die "submodule not ready: $SRC_TREE"
    if [ "$head" != "$pin" ]; then
      warn "submodule HEAD(${head:0:12}) != repository pin(${pin:0:12}), synchronizing to the pin"
      run git -C "$SRC_TREE" checkout --detach "$pin"
      run git -C "$SRC_TREE" submodule update --init --recursive
    fi
    log "submodule ready: $(therock_describe)"
  fi

  # ---- build-time Python environment (TheRock's fetch/build tooling needs it) ----
  local venv="$WORK_DIR/venv"
  if [ "$DRY_RUN" != 1 ]; then
    if [ ! -x "$venv/bin/python" ]; then
      log "creating the build venv: $venv"
      python3 -m venv "$venv"
      "$venv/bin/pip" install -q -U pip
    fi
    if [ -f "$SRC_TREE/requirements.txt" ]; then
      log "installing TheRock python dependencies (requirements.txt)..."
      "$venv/bin/pip" install -q -r "$SRC_TREE/requirements.txt"
    fi
  else
    printf '  [dry-run] python3 -m venv %s && pip install -r %s/requirements.txt\n' "$venv" "$SRC_TREE"
  fi

  # ---- component sources (TheRock's own submodules plus upstream patches) ----
  local stamp="$WORK_DIR/.sources-fetched"
  if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$pin" ] && [ -d "$SRC_TREE/rocm-libraries" ]; then
    log "component sources already present (pin=${pin:0:12}), skipping fetch_sources.py"
    log "  to force a refresh: rm $stamp"
    return 0
  fi

  [ -f "$SRC_TREE/build_tools/fetch_sources.py" ] || die "missing build_tools/fetch_sources.py (incomplete submodule?)"

  # Some upstream submodules carry Git LFS pointers; the build does not need the
  # LFS content, so skip the smudge step (otherwise it hangs or fails on
  # restricted networks)
  if command -v git-lfs >/dev/null 2>&1; then
    run git -C "$SRC_TREE" config lfs.fetchexclude "*" 2>/dev/null || true
  fi
  export GIT_LFS_SKIP_SMUDGE=1

  log "fetching TheRock component sources (fetch_sources.py, about 30GB on first run)..."
  if [ "$DRY_RUN" = 1 ]; then
    printf '  [dry-run] cd %s && %s ./build_tools/fetch_sources.py\n' "$SRC_TREE" "$venv/bin/python"
  else
    if ! ( cd "$SRC_TREE" && "$venv/bin/python" ./build_tools/fetch_sources.py ); then
      # Known issue: gh-proxy truncates large repositories (the full rocm-libraries
      # pack is around 9 GB) mid-transfer; git reports "did not receive expected
      # object / invalid index-pack output" and clones cannot be resumed. Fallback:
      # shallow-clone those submodules (--depth 1); the build only needs the pinned
      # commit to exist.
      warn "fetch_sources.py failed (truncation of large packs is a known issue) -> falling back to shallow clones"
      ( cd "$SRC_TREE" && git submodule update --init --depth 1 --recursive ) \
        || die "shallow-clone fallback failed (network?)"
      ( cd "$SRC_TREE" && "$venv/bin/python" ./build_tools/fetch_sources.py ) \
        || die "fetch_sources.py failed a second time"
    fi
    echo "$pin" > "$stamp"
  fi
  log "component sources ready"
}

# ===========================================================================
# B. Prebuilt mode
# ===========================================================================
prebuilt_file_bundle() {
  case "${THEROCK_BUNDLE:-$GPU_FAMILY}" in
    multi-arch|multiarch) echo "multiarch" ;;
    *) echo "${THEROCK_BUNDLE:-$GPU_FAMILY}" ;;
  esac
}

fetch_prebuilt_mode() {
  local bundle base fname url tarball
  bundle=$(prebuilt_file_bundle)
  base=$(prebuilt_base_url "$RELEASE_CHANNEL") \
    || die "unknown release channel: $RELEASE_CHANNEL (expected stable|nightly|rc|bkc|dev)"
  fname="therock-dist-linux-${bundle}-${ROCM_VERSION}.tar.gz"
  url="$base/$fname"
  tarball="$TARBALL_DIR/$fname"

  mkdir -p "$TARBALL_DIR"

  if [ -f "$tarball" ] && [ -s "$tarball" ]; then
    log "tarball already present: $tarball"
  elif [ "$DRY_RUN" = 1 ]; then
    printf '  [dry-run] curl -fL --retry 3 -C - -o %s %s\n' "$tarball" "$url"
    printf '  [dry-run] tar -xf %s -C %s\n' "$tarball" "$PREBUILT_INSTALL"
    return 0
  else
    log "downloading the ROCm tarball: $url"
    if ! curl -fsIL --connect-timeout 20 "$url" >/dev/null 2>&1; then
      warn "URL is not available: $url"
      warn "browse the index page to confirm the version and bundle name:"
      warn "  $base/"
      warn "  e.g. therock-dist-linux-gfx120X-all-10.0.0.tar.gz"
      die "prebuilt artifact download failed (try --rocm-version / --channel / THEROCK_BUNDLE)"
    fi
    run curl -fL --retry 3 --connect-timeout 20 -C - -o "$tarball" "$url"
  fi

  # Unpack (the tarball already contains the install tree: bin/ lib/ include/ .kpack/ ...)
  if [ -d "$PREBUILT_INSTALL/lib" ] && [ -f "$PREBUILT_INSTALL/.amd-therock-unpacked" ]; then
    log "already unpacked: $PREBUILT_INSTALL"
  else
    log "unpacking to $PREBUILT_INSTALL ..."
    run rm -rf "$PREBUILT_INSTALL"
    run mkdir -p "$PREBUILT_INSTALL"
    run tar -xf "$tarball" -C "$PREBUILT_INSTALL"
    [ "$DRY_RUN" = 1 ] || { [ -d "$PREBUILT_INSTALL/lib" ] || die "no lib/ after unpacking (unexpected tarball layout)"; }
    [ "$DRY_RUN" = 1 ] || : > "$PREBUILT_INSTALL/.amd-therock-unpacked"
  fi

  if [ "$DRY_RUN" != 1 ]; then
    local kp
    kp=$(ls -1 "$PREBUILT_INSTALL/.kpack" 2>/dev/null | grep -c -- "$GPU_TARGET" || true)
    log "unpacked: $(du -sh "$PREBUILT_INSTALL" | awk '{print $1}'), kpack entries for $GPU_TARGET: ${kp:-0}"
  fi
}

# ===========================================================================
# C. Framework-side sources (torch / torchvision / triton / vLLM)
#    Only needed when building the Python stack from source; x86_64 pip mode
#    skips this entirely.
# ===========================================================================
fetch_framework_sources() {
  [ "$IMAGE_KIND" = vllm ] || { log "the runtime image needs no framework sources, skipping"; return 0; }
  [ "$WHEEL_MODE" = source ] || { log "wheel-mode=pip needs no framework sources, skipping"; return 0; }

  mkdir -p "$SRC_ROOT"
  [ "$DRY_RUN" = 1 ] || : > "$SOURCE_PINS.tmp"
  local name dir url ref head
  for name in "${SRC_ORDER[@]}"; do
    dir="$(src_dir "$name")"
    url="$(src_url "$name")"
    ref="$(src_ref "$name")"
    [ -n "$url" ] || die "config/sources.sh does not define source: $name"

    if [ ! -d "$dir/.git" ]; then
      log "cloning $name <- $url"
      run git clone --filter=blob:none --no-checkout "$url" "$dir"
    else
      log "$name already present, updating the remote"
      run git -C "$dir" remote set-url origin "$url"
    fi

    log "  checkout $ref"
    if ! run git -C "$dir" rev-parse --verify --quiet "${ref}^{commit}" >/dev/null; then
      run git -C "$dir" fetch --tags origin || warn "fetch $name failed (network?)"
    fi
    run git -C "$dir" checkout -q "$ref" || die "$name cannot be checked out at $ref"
    head=$(git -C "$dir" rev-parse HEAD 2>/dev/null || echo "?")
    log "  $name @ ${head:0:12} ($ref)"
    printf '%s=%s\n' "$name" "$head" >> "$SOURCE_PINS.tmp"
  done
  [ "$DRY_RUN" = 1 ] || mv -f "$SOURCE_PINS.tmp" "$SOURCE_PINS"
  log "framework sources ready: $SRC_ROOT"
}

# ===========================================================================
case "$MODE" in
  source)   fetch_sources_mode ;;
  prebuilt) fetch_prebuilt_mode ;;
esac

fetch_framework_sources

log "fetch done (mode=$MODE, wheel-mode=$WHEEL_MODE)"
