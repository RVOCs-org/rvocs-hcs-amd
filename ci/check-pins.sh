#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# ci/check-pins.sh - verify upstream pins and patch-series consistency
#
# Design note: section 3 does NOT re-implement patch logic. rvocs-hcs-amd
# already owns the authoritative implementation in scripts/tools/patch.sh
# (status/check, series order, -R applied detection, patch-state fingerprints).
# Duplicating it here produced false negatives (git apply vs patch -p1
# semantics differ), so we delegate and only parse the verdict.
#
# Checks:
#   1. version pins: keys in pins/*.env are full shas / semvers, not floating refs
#   2. upstream checkouts: recorded .pin matches `git rev-parse HEAD` prefix
#   3. patch series: `scripts/tools/patch.sh status` reports no [fail]
#
# Exit: 0 ok (warnings allowed), 1 hard mismatch
# ---------------------------------------------------------------------------
set -uo pipefail

ROOT="${RVOCS_ROOT:-/home/ubuntu/RVOCs-CICD/rvocs-hcs-amd}"
FAIL=0; WARN=0
ok()   { printf '  \033[32mOK\033[0m   %s\n' "$*"; }
bad()  { printf '  \033[1;31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
warn() { printf '  \033[33mWARN\033[0m %s\n' "$*"; WARN=$((WARN+1)); }
sec()  { printf '\n\033[1m%s\033[0m\n' "$*"; }

echo "check-pins: repo=$ROOT"
[ -d "$ROOT" ] || { bad "repo root missing: $ROOT"; echo "summary: fail=$FAIL warn=$WARN"; exit 1; }

sec "1. declared source pins (config/sources.sh src_define ...)"
SRC_SH="$ROOT/config/sources.sh"
if [ ! -f "$SRC_SH" ]; then
  warn "config/sources.sh not found - skipping declared pin validation"
else
  npins=0
  while read -r _ name url ref; do
    case "$name" in ''|\#*) continue ;; esac
    npins=$((npins+1))
    ref="${ref%%#*}"; ref="$(printf '%s' "$ref" | tr -d "\"'")"
    case "$ref" in
      '') bad "$name: empty ref" ; continue ;;
      main|master|dev|latest|HEAD) bad "$name: floating ref '$ref'" ; continue ;;
    esac
    if printf '%s' "$ref" | grep -qE '^[0-9a-f]{40}$'; then
      # full sha: must match the local checkout when one exists
      tree=""
      for cand in "$ROOT/work/src/$name" "$ROOT/upstream/$name" "$ROOT/upstream/therock/$name"; do
        [ -d "$cand/.git" ] && { tree="$cand"; break; }
      done
      if [ -z "$tree" ]; then
        ok "$name: ${ref:0:12} (sha, no local checkout to compare)"
      else
        head="$(git -C "$tree" rev-parse HEAD 2>/dev/null || true)"
        case "$head" in
          "$ref"*) ok "$name: ${ref:0:12} == local HEAD" ;;
          '')      warn "$name: ${ref:0:12} but local HEAD unreadable ($tree)" ;;
          *)       bad "$name: declared ${ref:0:12} != local HEAD ${head:0:12} ($tree)" ;;
        esac
      fi
    elif printf '%s' "$ref" | grep -qE '^v?[0-9]+\.[0-9]+'; then
      ok "$name: $ref (tag)"
    else
      warn "$name: ref '$ref' is neither 40-hex sha nor semver tag"
    fi
  done < <(grep -E '^[[:space:]]*src_define[[:space:]]' "$SRC_SH" 2>/dev/null || true)
  [ "$npins" -eq 0 ] && warn "no src_define entries parsed from config/sources.sh"
fi

sec "2. upstream checkouts match their .pin"
matched=0
for d in "$ROOT"/upstream/*/ "$ROOT"/upstream/*/*/; do
  [ -d "$d/.git" ] || continue
  name="${d#"$ROOT"/upstream/}"; name="${name%/}"
  head="$(git -C "$d" rev-parse HEAD 2>/dev/null || true)"
  [ -z "$head" ] && { warn "$name: unreadable git tree"; continue; }
  pinf=""
  for cand in "$d/.pin" "$ROOT/pins/$name.pin" "$d/../$(basename "$name").pin"; do
    [ -f "$cand" ] && { pinf="$cand"; break; }
  done
  if [ -z "$pinf" ]; then
    warn "$name: HEAD=${head:0:12} but no .pin file to compare"; continue
  fi
  pin="$(head -1 "$pinf" | tr -d '[:space:]')"
  case "$head" in
    "$pin"*) ok "$name: HEAD=${head:0:12} matches pin"; matched=$((matched+1)) ;;
    *)       bad "$name: HEAD=${head:0:12} != pin ${pin:0:12} ($pinf)" ;;
  esac
done
[ "$matched" -eq 0 ] && [ "$FAIL" -eq 0 ] && warn "no upstream/.pin pair verified (nothing checked out?)"

sec "3. patch series (authoritative: scripts/tools/patch.sh check)"
if [ -f "$ROOT/scripts/tools/patch.sh" ]; then
  out="$(cd "$ROOT" && bash scripts/tools/patch.sh check 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/  /' | tail -12
  if printf '%s' "$out" | grep -q 'PATCH_CHECK_OK'; then
    ok "all patch series apply cleanly"
  elif [ "$rc" -ne 0 ]; then
    bad "patch.sh check failed (rc=$rc)"
  else
    warn "patch.sh check finished without PATCH_CHECK_OK marker"
  fi
else
  warn "scripts/tools/patch.sh missing - falling back to per-file dry run"
  shopt -s globstar nullglob
  for p in "$ROOT"/patches/**/*.patch; do
    rel="${p#"$ROOT"/patches/}"; comp="${rel%%/*}"
    target=""
    for cand in "$ROOT/upstream/$comp" "$ROOT/upstream/therock/$comp" "$ROOT/work/src/$comp"; do
      [ -d "$cand" ] && { target="$cand"; break; }
    done
    if [ -z "$target" ]; then warn "$rel: target '$comp' not present, skipped"; continue; fi
    if patch -p1 -R --dry-run -d "$target" -f -s < "$p" >/dev/null 2>&1; then ok "$rel (applied)"
    elif patch -p1 --dry-run -d "$target" -f -s < "$p" >/dev/null 2>&1; then ok "$rel (pending)"
    else bad "$rel: cannot apply onto $target"; fi
  done
fi

printf '\nsummary: fail=%d warn=%d\n' "$FAIL" "$WARN"
[ -n "${GITHUB_STEP_SUMMARY:-}" ] && printf '### check-pins: fail=%d warn=%d\n' "$FAIL" "$WARN" >> "$GITHUB_STEP_SUMMARY"
[ "$FAIL" -eq 0 ] || exit 1
