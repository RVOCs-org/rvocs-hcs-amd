#!/usr/bin/env bash
# ============================================================================
# Patch engine (sourced by common.sh; content lives in patches/<arch>/)
#
# Directory layout:
#   patches/<arch>/components.map      component -> path (TheRock tree / src:<name> / .)
#   patches/<arch>/<component>/series  ordered list (one .patch per line, # comments allowed)
#   patches/<arch>/<component>/NNNN-*.patch
#   patches/<arch>/image/*.py          python patches run at image build time (not via series)
#
# Semantics: same as git format-patch / quilt - git apply in series order.
#           Patches already applied (git apply --check -R succeeds) are skipped,
#           so the whole thing is idempotent and can be replayed.
# ============================================================================

PATCH_ROOT="${PATCH_ROOT:-}"   # evaluated lazily by patch_root()

patch_root() {
  if [ -z "$PATCH_ROOT" ]; then
    PATCH_ROOT="$REPO_ROOT/patches/$ARCH"
  fi
  printf '%s' "$PATCH_ROOT"
}

# component name -> absolute workspace path
patch_component_path() { # patch_component_path <component>
  local comp="$1" map rel
  map="$(patch_root)/components.map"
  [ -f "$map" ] || return 1
  rel=$(awk -v c="$comp" '
    /^[[:space:]]*#/ { next }
    NF < 2 { next }
    $1 == c { print $2; exit }
  ' "$map")
  [ -n "$rel" ] || return 1
  # Path semantics:
  #   .            -> root of the TheRock source tree (upstream/therock)
  #   <path>       -> path relative to the TheRock tree (component submodule)
  #   src:<name>   -> framework-side source (work/src/<name>, see config/sources.sh)
  case "$rel" in
    src:*) printf '%s' "$SRC_ROOT/${rel#src:}" ;;
    .)     printf '%s' "$SRC_TREE" ;;
    *)     printf '%s' "$SRC_TREE/$rel" ;;
  esac
}

patch_components() { # list the components declared in components.map
  local map
  map="$(patch_root)/components.map"
  [ -f "$map" ] || return 0
  awk '/^[[:space:]]*#/ {next} NF>=2 {print $1}' "$map"
}

# .git exists AND actually works (copied work trees often keep a stale gitdir pointer)
_patch_in_repo() { [ -e "$1/.git" ] && git -C "$1" rev-parse --git-dir >/dev/null 2>&1; }

# State of one patch in the target tree: applied | pending | fail
patch_state() { # patch_state <dir> <patchfile>
  local dir="$1" p="$2"
  if _patch_in_repo "$dir"; then
    if git -C "$dir" apply --check -R "$p" >/dev/null 2>&1; then echo applied; return; fi
    if git -C "$dir" apply --check "$p" >/dev/null 2>&1; then echo pending; return; fi
  else
    if patch -p1 -R --dry-run -d "$dir" -f -s < "$p" >/dev/null 2>&1; then echo applied; return; fi
    if patch -p1 --dry-run -d "$dir" -f -s < "$p" >/dev/null 2>&1; then echo pending; return; fi
  fi
  echo fail
}

# Patch files of a series (in order, absolute paths)
series_files() { # series_files <component> -> one absolute path per line
  local comp="$1" series p
  series="$(patch_root)/$comp/series"
  [ -f "$series" ] || return 0
  while IFS= read -r p; do
    case "$p" in ''|'#'*) continue ;; esac
    printf '%s\n' "$(patch_root)/$comp/$p"
  done < "$series"
}

# Patch state stamp: records the fact that a component's series has been applied.
# Why it is needed: when several patches touch the same file, checking them one by
# one with `git apply -R` misjudges later patches as "not applied" because earlier
# ones changed the context; and `git apply --check p1 p2` is not composable either
# (each patch is validated against the original tree). So idempotency is decided by
# a fingerprint of the series contents, and the stamps are cleared whenever the
# submodule is realigned/restored.
patch_state_file() { printf '%s/.patch-state/%s' "$WORK_DIR" "$1"; }

series_signature() { # series_signature <component> -> sha256 (empty without patches)
  local files
  files=$(series_files "$1")
  [ -n "$files" ] || { printf ''; return; }
  # shellcheck disable=SC2086
  cat $files | sha256sum | awk '{print $1}'
}

series_state() { # series_state <component> -> applied | pending | missing
  local comp="$1" dir sig sf
  dir=$(patch_component_path "$comp" 2>/dev/null) || { echo missing; return; }
  [ -d "$dir" ] || { echo missing; return; }
  [ -n "$(series_files "$comp")" ] || { echo applied; return; }
  sig=$(series_signature "$comp")
  sf=$(patch_state_file "$comp")
  if [ -f "$sf" ] && [ "$(cat "$sf")" = "$sig" ]; then echo applied; return; fi
  echo pending
}

clear_patch_state() { rm -rf "$WORK_DIR/.patch-state"; }

# Apply one component's series (idempotent: already applied series are skipped by stamp)
apply_component_series() { # apply_component_series <component> [--strict]
  local comp="$1" strict="${2:-}"
  local dir files n p state sig sf rc=0
  dir=$(patch_component_path "$comp") || { warn "components.map does not declare component: $comp"; return 0; }
  [ -d "$dir" ] || { warn "source directory of component $comp does not exist: $dir (run --stage fetch first)"; return 0; }
  files=$(series_files "$comp")
  [ -n "$files" ] || return 0
  n=$(printf '%s\n' "$files" | wc -l)

  sig=$(series_signature "$comp")
  sf=$(patch_state_file "$comp")
  if [ -f "$sf" ] && [ "$(cat "$sf")" = "$sig" ]; then
    log "  [applied] $comp ($n patches)"
    return 0
  fi

  log "  [apply]   $comp series ($n patches)"
  for p in $files; do
    # already in the tree (later patches change the context, so "skipped" is only reported per patch)
    state=$(patch_state "$dir" "$p")
    if [ "$state" = applied ]; then
      log "    [present] $(basename "$p")"
      continue
    fi
    if run git -C "$dir" apply --whitespace=nowarn "$p" 2>/dev/null; then
      continue
    fi
    if run git -C "$dir" apply --3way "$p" 2>/dev/null; then
      log "    [3way]   $(basename "$p")"
      continue
    fi
    [ "$strict" = "--strict" ] && die "patch does not apply: $comp/$(basename "$p") (baseline drift?)"
    warn "  [failed]  $comp/$(basename "$p")"
    rc=1
  done

  if [ "$rc" = 0 ] && [ "$DRY_RUN" != 1 ]; then
    mkdir -p "$(dirname "$sf")"
    printf '%s' "$sig" > "$sf"
  fi
  return $rc
}

# Apply the series of every component
apply_patch_series() { # apply_patch_series [--strict]
  local comp rc=0
  is_porting_branch || { log "no patches/ directory in this checkout (patch layer disabled), skipping patches"; return 0; }
  log "applying patch series: patches/$ARCH"
  for comp in $(patch_components); do
    apply_component_series "$comp" "${1:-}" || rc=1
  done
  return $rc
}

# Reverse-apply every patch (to get back to a clean upstream tree)
revert_patch_series() {
  local comp dir series p
  is_porting_branch || return 0
  for comp in $(patch_components); do
    dir=$(patch_component_path "$comp") || continue
    series="$(patch_root)/$comp/series"
    [ -f "$series" ] || continue
    # reverse order
    while IFS= read -r p; do
      case "$p" in ''|'#'*) continue ;; esac
      [ -f "$(patch_root)/$comp/$p" ] || continue
      if [ "$(patch_state "$dir" "$(patch_root)/$comp/$p")" = applied ]; then
        log "  [revert] $comp/$p"
        run git -C "$dir" apply -R "$(patch_root)/$comp/$p" 2>/dev/null || true
      fi
    done < <(tac "$series")
  done
}

# Fingerprint of the patch layer (tells whether work/ matches the current baseline + patches)
patch_series_hash() {
  is_porting_branch || { echo "no-patches"; return; }
  {
    for comp in $(patch_components); do
      series="$(patch_root)/$comp/series"
      [ -f "$series" ] || continue
      echo "== $comp"
      cat "$series"
    done
    find "$(patch_root)" -name '*.patch' -type f | sort | xargs -r sha256sum
  } | sha256sum | awk '{print $1}'
}

baseline_stamp() { # the baseline state we should currently be in
  printf 'therock=%s\npatch_arch=%s\npatch_series=%s\n' \
    "$(therock_pin_commit)" "$ARCH" "$(patch_series_hash)"
}
