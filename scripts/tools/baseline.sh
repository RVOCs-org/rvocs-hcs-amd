#!/usr/bin/env bash
# ============================================================================
# Upstream baseline management
#
#   Baseline = the gitlink of the upstream/therock submodule (single source of
#   truth) plus the record in manifest.yaml
#
#   ./scripts/tools/baseline.sh status            # current state at a glance
#   ./scripts/tools/baseline.sh check             # consistency check (CI; non-zero exit = failure)
#   ./scripts/tools/baseline.sh sync              # only query which new upstream tags/commits exist
#   ./scripts/tools/baseline.sh apply [--dry-run] # apply the ref currently in manifest.yaml
#   ./scripts/tools/baseline.sh bump <ref>        # apply <ref> directly and record it in manifest.yaml
#   ./scripts/tools/baseline.sh tag <name>        # snapshot tag: baseline/<name>
#   ./scripts/tools/baseline.sh history           # list all baseline snapshots
#   ./scripts/tools/baseline.sh rollback <rev>    # roll back to a baseline (tag/commit)
#   ./scripts/tools/baseline.sh restore --force   # discard submodule changes, return to the pin
#   ./scripts/tools/baseline.sh clean --yes       # remove the build directory (sources and patches are kept)
#
# Convention: bump/rollback only change the local tree (no push); add --commit to
#             create a commit.
# ============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

MANIFEST="$REPO_ROOT/manifest.yaml"

ok()   { printf '  [ OK ] %s\n' "$*"; }
bad()  { printf '  [FAIL] %s\n' "$*"; }
note() { printf '  [ -- ] %s\n' "$*"; }

manifest_commit() { sed -n 's/^    commit: *\([0-9a-f]\{7,40\}\).*/\1/p' "$MANIFEST" | head -1; }
manifest_ref()    { sed -n 's/^    ref: *\([^ #]*\).*/\1/p' "$MANIFEST" | head -1; }

update_manifest() { # update_manifest <ref> <commit>
  local ref="$1" commit="$2" tmp
  tmp="$(mktemp)"
  awk -v r="$ref" -v c="$commit" '
    /^  therock:/        { inth = 1 }
    inth && /^    ref:/    { sub(/ref:.*/, "ref: " r "                  # tag, branch or commit"); next }
    inth && /^    commit:/ { sub(/commit:.*/, "commit: " c); next }
    { print }
  ' "$MANIFEST" > "$tmp"
  mv "$tmp" "$MANIFEST"
}

resolve_commit() { # resolve_commit <ref> -> commit sha
  local ref="$1" c
  c=$(git -C "$SRC_TREE" rev-parse --verify --quiet "${ref}^{commit}" 2>/dev/null || true)
  if [ -z "$c" ]; then
    log "ref '$ref' is not available locally, trying upstream..."
    git -C "$SRC_TREE" fetch --tags origin >/dev/null 2>&1 || \
      die "cannot reach upstream (network? try --proxy cn)"
    c=$(git -C "$SRC_TREE" rev-parse --verify --quiet "${ref}^{commit}" 2>/dev/null || true)
  fi
  [ -n "$c" ] || die "cannot resolve ref: $ref"
  printf '%s' "$c"
}

cmd_status() {
  local pin head dirty
  pin=$(therock_pin_commit); head=$(therock_head)
  echo "repository  : $REPO_ROOT"
  echo "branch      : $(current_branch)"
  echo "upstream    : $(git -C "$REPO_ROOT" config -f .gitmodules --get submodule.upstream/therock.url 2>/dev/null || echo '?')"
  echo "baseline pin: ${pin:-(not recorded)}"
  echo "manifest ref: $(manifest_ref)"
  if [ -n "$head" ]; then
    echo "submodule   : ${head:0:12}  $(therock_describe)"
  else
    echo "submodule   : (not initialized)"
  fi
  if [ -n "$head" ] && [ -e "$SRC_TREE/.git" ]; then
    dirty=$(git -C "$SRC_TREE" status --porcelain 2>/dev/null | wc -l)
    echo "work tree   : ${dirty} changed file(s) (patches/local edits are expected)"
  fi
  echo "build dir   : $([ -d "$THEROCK_BUILD" ] && du -sh "$THEROCK_BUILD" | awk '{print $1}' || echo '(none)')"
  echo "artifacts   : $([ -d "$DIST_DIR" ] && du -sh "$DIST_DIR" | awk '{print $1}' || echo '(none)')"
  if is_porting_branch; then
    echo "patch layer : patches/$ARCH  ($(patch_components | tr '\n' ' '))"
  else
    echo "patch layer : none (master)"
  fi
}

cmd_check() {
  local rc=0 pin head hpin
  # compare against the index (what the next commit records), not HEAD: apply
  # stages the gitlink and the commit usually happens afterwards
  hpin=$(therock_pin_commit)
  pin=$(git -C "$REPO_ROOT" ls-files -s -- upstream/therock 2>/dev/null | awk '$1=="160000"{print $2}')
  head=$(therock_head)

  if [ -n "$pin" ] && [ -n "$hpin" ] && [ "$hpin" != "$pin" ]; then
    warn "gitlink change is staged but not committed yet (HEAD has ${hpin:0:12})"
  fi

  if [ -z "$pin" ]; then bad "no gitlink recorded for upstream/therock"; rc=1
  elif [ -z "$head" ]; then bad "submodule not initialized (--stage fetch)"; rc=1
  elif [ "$pin" != "$head" ]; then bad "submodule HEAD(${head:0:12}) != pin(${pin:0:12})"; rc=1
  else ok "submodule matches the pin (${pin:0:12})"; fi

  mc=$(manifest_commit)
  if [ -z "$mc" ]; then
    bad "manifest.yaml has no commit for upstream.therock (run baseline.sh apply)"; rc=1
  elif [ "${#mc}" -ne 40 ]; then
    bad "manifest.yaml commit '$mc' is not a 40-hex sha (run baseline.sh apply)"; rc=1
  elif [ -n "$pin" ] && [ "$pin" != "$mc" ]; then
    bad "manifest.yaml commit ${mc:0:12} != gitlink ${pin:0:12} (run baseline.sh apply)"; rc=1
  else
    ok "manifest.yaml matches the gitlink (${pin:0:12})"
  fi

  if is_porting_branch; then
    if [ ! -e "$SRC_TREE/.git" ] && [ ! -d "$SRC_TREE/build_tools" ]; then
      note "patch layer present but sources are not fetched; patch checks skipped"
    else
      check_patch_series || rc=1
    fi
  fi

  [ "$rc" = 0 ] && log "BASELINE_CHECK_OK" || warn "BASELINE_CHECK_FAILED"
  return $rc
}

# patch usability, used by cmd_check when the sources are present
check_patch_series() {
  local comp dir series p st nfail=0 ntotal=0
  for comp in $(patch_components); do
    dir=$(patch_component_path "$comp" 2>/dev/null) || { bad "component $comp path does not exist"; nfail=$((nfail + 1)); continue; }
    series="$(patch_root)/$comp/series"
    [ -f "$series" ] || continue
    while IFS= read -r p; do
      case "$p" in ''|'#'*) continue ;; esac
      ntotal=$((ntotal + 1))
      st=$(patch_state "$dir" "$(patch_root)/$comp/$p")
      if [ "$st" = fail ]; then nfail=$((nfail + 1)); bad "patch unusable: $comp/$p"; fi
    done < "$series"
  done
  ok "patch series: $((ntotal - nfail))/$ntotal usable"
  [ "$nfail" -eq 0 ]
}

cmd_sync() {
  resolve_proxy
  if [ ! -e "$SRC_TREE/.git" ]; then
    warn "submodule not initialized, can only query the remote"
    git ls-remote --tags "$(git -C "$REPO_ROOT" config -f .gitmodules --get submodule.upstream/therock.url)" \
      | awk -F/ '{print $NF}' | grep -v '\^{}' | sort -V | tail -10
    return 0
  fi
  log "fetching upstream tags/branches ..."
  git -C "$SRC_TREE" fetch --tags --prune origin
  local cur
  cur=$(git -C "$SRC_TREE" describe --tags --always 2>/dev/null || echo "")
  echo "current: $cur"
  echo "---- 15 most recent upstream tags (new -> old) ----"
  git -C "$SRC_TREE" tag --sort=-creatordate | head -15
  echo "---- behind origin/HEAD? ----"
  git -C "$SRC_TREE" log --oneline --no-decorate HEAD..origin/HEAD 2>/dev/null | head -10 || true
  echo
  echo "upgrade: scripts/tools/baseline.sh bump <tag> --commit"
  echo "rollback: scripts/tools/baseline.sh rollback <tag|baseline/name>"
}

# apply [--dry-run]: move the baseline to whatever manifest.yaml already says.
# manifest.yaml is the single input - edit upstream.therock.ref (tag, branch or
# commit sha) and run apply; the gitlink and the commit: line follow.
cmd_apply() {
  local dry="${1:-}" ref commit old
  ref=$(manifest_ref)
  [ -n "$ref" ] || die "manifest.yaml has no upstream.therock.ref"
  [ -e "$SRC_TREE/.git" ] || die "submodule not initialized, run --stage fetch first"

  old=$(therock_head)
  commit=$(resolve_commit "$ref")
  log "baseline: ${old:0:12} -> ${commit:0:12} ($ref)"

  if [ "$dry" = "--dry-run" ]; then
    printf '  [dry-run] git -C %s checkout --detach %s\n' "$SRC_TREE" "$commit"
    printf '  [dry-run] git -C %s add upstream/therock\n' "$REPO_ROOT"
    printf '  [dry-run] manifest: commit = %s\n' "$commit"
    return 0
  fi

  git -C "$SRC_TREE" checkout --detach "$commit"
  git -C "$REPO_ROOT" add upstream/therock
  update_manifest "$ref" "$commit"
  log "gitlink and manifest.yaml updated (staged, not committed)"
  echo "  next: review 'git status', then commit; patches may need a replay (--stage prep)"
}

cmd_bump() {
  local ref="${1:-}" do_commit="${2:-}"
  [ -n "$ref" ] || die "usage: baseline.sh bump <ref> [--commit]"
  [ -e "$SRC_TREE/.git" ] || die "submodule not initialized, run --stage fetch first"
  local commit old
  old=$(therock_head)
  commit=$(resolve_commit "$ref")
  log "switching the upstream baseline: ${old:0:12} -> ${commit:0:12} ($ref)"
  git -C "$SRC_TREE" checkout --detach "$commit"
  git -C "$SRC_TREE" submodule update --init --recursive
  update_manifest "$ref" "$commit"
  git -C "$REPO_ROOT" add upstream/therock "$MANIFEST"
  log "manifest.yaml and the submodule gitlink updated (staged, not committed)"
  if [ "$do_commit" = "--commit" ]; then
    git -C "$REPO_ROOT" commit -m "baseline: bump therock to $ref ($commit)"
    log "committed"
  fi
  cat <<EOF

Next steps:
  1) replay patches and check conflicts: ./scripts/build.sh --stage prep
  2) fix broken patches one by one:     ./scripts/tools/patch.sh check --verbose
  3) full build and acceptance:         ./scripts/build.sh --stage all
  4) snapshot the baseline:             ./scripts/tools/baseline.sh tag <date or version>
EOF
}

cmd_rollback() {
  local rev="${1:-}"
  [ -n "$rev" ] || die "usage: baseline.sh rollback <tag|commit|baseline/name>"
  if git -C "$REPO_ROOT" rev-parse --verify --quiet "refs/tags/$rev" >/dev/null 2>&1; then
    log "rolling back from baseline snapshot: $rev"
    git -C "$REPO_ROOT" checkout "$rev" -- "$MANIFEST" upstream/therock
    git -C "$REPO_ROOT" submodule update --init upstream/therock
    git -C "$REPO_ROOT" add upstream/therock "$MANIFEST"
    log "rolled back to $(manifest_ref) / $(therock_head)"
  else
    cmd_bump "$rev" "${2:-}"
  fi
  warn "the patches in the work tree may not match the older baseline, run ./scripts/tools/patch.sh check"
}

cmd_tag() {
  local name="${1:-}"
  [ -n "$name" ] || die "usage: baseline.sh tag <name> (e.g. 2026-10-21-rocm10.0)"
  [ -z "$(git -C "$REPO_ROOT" tag -l "baseline/$name")" ] || die "tag already exists: baseline/$name"
  local pin; pin=$(therock_pin_commit)
  git -C "$REPO_ROOT" tag -a "baseline/$name" \
    -m "therock=$(manifest_ref) ($pin) gpu=${GPU_ID} patches=$(patch_series_hash | cut -c1-12)"
  log "baseline snapshot created: baseline/$name -> ${pin:0:12}"
  log "rollback command: scripts/tools/baseline.sh rollback baseline/$name"
}

cmd_history() {
  git -C "$REPO_ROOT" for-each-ref --sort=-creatordate --format='%(refname:short)  %(creatordate:short)  %(subject)' \
    refs/tags/baseline/ || true
}

cmd_restore() {
  [ "${1:-}" = "--force" ] || die "restore discards every change inside the submodule (including applied patches). Add --force to confirm"
  [ -e "$SRC_TREE/.git" ] || die "submodule not initialized"
  git -C "$SRC_TREE" checkout -- .
  git -C "$SRC_TREE" submodule update --init --recursive
  git -C "$SRC_TREE" clean -fd -e build -e .cpmcache 2>/dev/null || true
  rm -f "$BASELINE_STAMP"
  rm -rf "$WORK_DIR/.patch-state"     # patch stamps become void with the work tree reset
  log "restored to the clean pin $(therock_pin_commit | cut -c1-12) state (build/ is kept)"
}

cmd_clean() {
  [ "${1:-}" = "--yes" ] || die "clean deletes $THEROCK_BUILD. Add --yes to confirm"
  rm -rf "$THEROCK_BUILD"
  rm -f "$BASELINE_STAMP"
  log "build directory removed: $THEROCK_BUILD (sources and patches are kept)"
}

case "${1:-}" in
  status)   cmd_status ;;
  check)    cmd_check ;;
  sync)     cmd_sync ;;
  apply)    shift; cmd_apply "${1:-}" ;;
  bump)     shift; cmd_bump "${1:-}" "${2:-}" ;;
  tag)      shift; cmd_tag "${1:-}" ;;
  history)  cmd_history ;;
  rollback) shift; cmd_rollback "${1:-}" "${2:-}" ;;
  restore)  shift; cmd_restore "${1:-}" ;;
  clean)    shift; cmd_clean "${1:-}" ;;
  -h|--help|"") awk 'NR>1 && /^#/ { sub(/^# ?/,""); print; next } NR>1 { exit }' "$0" ;;
  *) die "unknown subcommand: $1 (see --help)" ;;
esac
