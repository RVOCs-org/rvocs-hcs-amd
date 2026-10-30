#!/usr/bin/env bash
# ============================================================================
# Patch tool (per-arch patch layers)
#
#   ./scripts/tools/patch.sh list                   # list patches and their state
#   ./scripts/tools/patch.sh check [--verbose]      # verify they apply cleanly
#   ./scripts/tools/patch.sh status <comp>          # details for one component
#   ./scripts/tools/patch.sh capture <comp> <name>  # capture workspace changes as a new patch
#   ./scripts/tools/patch.sh import <comp> <file|url> <name>   # import an external patch
#   ./scripts/tools/patch.sh revert <comp>          # reverse-apply every patch of that component
#
# Numbering (consistent with series order):
#   <prefix><3-digit sequence>-<name>.patch, where prefix is column 3 of
#   components.map, e.g. therock=1 -> 1001-xxx.patch; rocm-systems=2 -> 2001-xxx.patch.
# ============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

is_porting_branch || die "no patches/ directory in this checkout (the patch layer is required to use this tool)"

require_comp() {
  local comp="$1"
  patch_component_path "$comp" >/dev/null 2>&1 \
    || die "component not declared in components.map: $comp (declared: $(patch_components | tr '\n' ' '))"
}

prefix_of() {
  awk -v c="$1" '/^[[:space:]]*#/ {next} NF>=3 && $1==c {print $3; exit}' "$(patch_root)/components.map"
}

series_of() { echo "$(patch_root)/$1/series"; }

next_number() { # next_number <comp>
  local comp="$1" prefix n=0
  prefix=$(prefix_of "$comp"); [ -n "$prefix" ] || prefix=9
  local s; s=$(series_of "$comp")
  if [ -f "$s" ]; then
    n=$(grep -cE '^[0-9]' "$s" || true)
  fi
  printf '%s%03d' "$prefix" "$((n + 1))"
}

append_series() { # append_series <comp> <file>
  local comp="$1" f="$2" s; s=$(series_of "$comp")
  mkdir -p "$(dirname "$s")"
  touch "$s"
  grep -qxF "$f" "$s" 2>/dev/null || printf '%s\n' "$f" >> "$s"
}

cmd_list() {
  local comp dir series p st
  printf '%-18s %-38s %s\n' "COMPONENT" "PATCH" "STATE"
  for comp in $(patch_components); do
    series=$(series_of "$comp")
    dir=$(patch_component_path "$comp" 2>/dev/null || echo "")
    [ -f "$series" ] || { printf '%-18s %-38s %s\n' "$comp" "(no series)" "-"; continue; }
    while IFS= read -r p; do
      case "$p" in ''|'#'*) continue ;; esac
      if [ -z "$dir" ] || [ ! -d "$dir" ]; then st="no-src"; else st=$(patch_state "$dir" "$(patch_root)/$comp/$p"); fi
      printf '%-18s %-38s %s\n' "$comp" "$p" "$st"
    done < "$series"
  done
}

cmd_check() {
  local verbose="${1:-}" rc=0 comp dir files st n=0
  for comp in $(patch_components); do
    files=$(series_files "$comp")
    [ -n "$files" ] || continue
    dir=$(patch_component_path "$comp" 2>/dev/null || echo "")
    if [ -z "$dir" ] || [ ! -d "$dir" ]; then
      warn "skipping $comp: source directory missing (run --stage fetch first)"
      continue
    fi
    n=$((n + $(printf '%s\n' "$files" | wc -l)))
    st=$(series_state "$comp")
    case "$st" in
      applied) [ "$verbose" = "--verbose" ] && echo "  [applied] $comp ($(printf '%s\n' "$files" | wc -l) patches)" ;;
      pending) echo "  [can apply] $comp ($(printf '%s\n' "$files" | wc -l) patches)" ;;
      *)
        echo "  [conflict] $comp"
        if [ "$verbose" = "--verbose" ]; then
          # shellcheck disable=SC2086
          git -C "$dir" apply --check $files 2>&1 | sed 's/^/           /' | head -6 || true
        fi
        rc=1 ;;
    esac
  done
  echo "$n patches in total"
  [ "$rc" = 0 ] && log "PATCH_CHECK_OK" || warn "PATCH_CHECK_FAILED (fix conflicts or adjust the baseline)"
  return $rc
}

cmd_status() {
  local comp="${1:-}"; [ -n "$comp" ] || die "usage: patch.sh status <comp>"
  require_comp "$comp"
  local dir series p
  dir=$(patch_component_path "$comp")
  echo "component: $comp"
  echo "path     : $dir"
  echo "git      : $([ -e "$dir/.git" ] && git -C "$dir" rev-parse --short HEAD 2>/dev/null || echo 'not a git work tree')"
  series=$(series_of "$comp")
  [ -f "$series" ] && while IFS= read -r p; do
    case "$p" in ''|'#'*) continue ;; esac
    printf '  %-38s %s\n' "$p" "$(patch_state "$dir" "$(patch_root)/$comp/$p")"
  done < "$series"
}

cmd_capture() {
  local comp="${1:-}" name="${2:-}"
  [ -n "$comp" ] && [ -n "$name" ] || die "usage: patch.sh capture <comp> <name>"
  require_comp "$comp"
  local dir; dir=$(patch_component_path "$comp")
  [ -e "$dir/.git" ] || die "component directory is not a git work tree, cannot capture a diff: $dir"
  git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || die "invalid git work tree: $dir"

  local untracked; untracked=$(git -C "$dir" status --porcelain | grep -c '^??' || true)
  if [ "${untracked:-0}" -gt 0 ]; then
    warn "$untracked untracked file(s) will not be part of the patch (for new files, run git -C $dir add -N <file> first)"
  fi

  local num file
  num=$(next_number "$comp")
  file="$(patch_root)/$comp/${num}-${name}.patch"
  [ -e "$file" ] || mkdir -p "$(dirname "$file")"

  git -C "$dir" diff HEAD --no-color --no-ext-diff --binary > "$file"
  [ -s "$file" ] || { rm -f "$file"; die "nothing to capture, workspace is unchanged ($dir)"; }
  append_series "$comp" "$(basename "$file")"
  log "patch written: ${file#$REPO_ROOT/}  ($(wc -l < "$file") lines)"
  log "appended to series: $(series_of "$comp")"
}

cmd_import() {
  local comp="${1:-}" src="${2:-}" name="${3:-}"
  [ -n "$comp" ] && [ -n "$src" ] && [ -n "$name" ] || die "usage: patch.sh import <comp> <file|url> <name>"
  require_comp "$comp"
  local dir tmp num; dir=$(patch_component_path "$comp")
  [ -d "$dir" ] || die "source directory missing: $dir (run --stage fetch first)"

  tmp=$(mktemp)
  case "$src" in
    http://*|https://*)
      resolve_proxy
      log "downloading patch: $(gh_url "$src")"
      curl -fsSL "$(gh_url "$src")" -o "$tmp" || die "download failed: $src" ;;
    *) cp "$src" "$tmp" ;;
  esac

  if ! git -C "$dir" apply --check "$tmp" 2>/dev/null; then
    if [ "$(patch_state "$dir" "$tmp")" = applied ]; then
      warn "this patch appears to be already applied"
    else
      git -C "$dir" apply --check -v "$tmp" 2>&1 | sed 's/^/  /' || true
      die "patch does not apply to $comp (baseline mismatch? use patch.sh capture to produce an adapted version first)"
    fi
  fi

  num=$(next_number "$comp")
  local file="$(patch_root)/$comp/${num}-${name}.patch"
  mkdir -p "$(dirname "$file")"
  mv "$tmp" "$file"
  append_series "$comp" "$(basename "$file")"
  log "imported: ${file#$REPO_ROOT/}"
}

cmd_revert() {
  local comp="${1:-}"; [ -n "$comp" ] || die "usage: patch.sh revert <comp>"
  require_comp "$comp"
  local dir; dir=$(patch_component_path "$comp")
  local series; series=$(series_of "$comp")
  [ -f "$series" ] || { log "no series, nothing to do"; return 0; }
  while IFS= read -r p; do
    case "$p" in ''|'#'*) continue ;; esac
    if [ "$(patch_state "$dir" "$(patch_root)/$comp/$p")" = applied ]; then
      log "reverting $comp/$p"
      git -C "$dir" apply -R "$(patch_root)/$comp/$p" || warn "revert failed: $p"
    fi
  done < <(tac "$series")
}

case "${1:-}" in
  list)    cmd_list ;;
  check)   shift; cmd_check "${1:-}" ;;
  status)  shift; cmd_status "${1:-}" ;;
  capture) shift; cmd_capture "${1:-}" "${2:-}" ;;
  import)  shift; cmd_import "${1:-}" "${2:-}" "${3:-}" ;;
  revert)  shift; cmd_revert "${1:-}" ;;
  -h|--help|"") awk 'NR>1 && /^#/ { sub(/^# ?/,""); print; next } NR>1 { exit }' "$0" ;;
  *) die "unknown subcommand: $1 (see --help)" ;;
esac
