#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# ci/stage.sh - CI-aware wrapper around rvocs-hcs-amd/scripts/build.sh
#
# Why this exists:
#   scripts/build.sh knows HOW to build; it does not know about CI concerns
#   (resume, locking, guards, logs, summaries, artifacts). This wrapper adds:
#     1. resumability  - .stage_done/<stage>.<key> markers; the key is a
#                        content fingerprint of what THIS stage consumes
#                        (ci/lib/inputs.sh), not HEAD/pin/mtime; changed => rebuild
#     2. locking       - CI_CPU_LOCK serialises CPU stages (single 121G host),
#                        CI_GPU_LOCK guarantees exclusive access to /dev/kfd
#     3. guards        - refuse to start when disk/memory headroom is unsafe
#                        (a killed build at minute 90 is worse than a fast fail)
#     4. evidence      - per-run log file, ALERT line on failure, JSON summary,
#                        $GITHUB_STEP_SUMMARY block, image digest
#
# Usage:
#   ci/stage.sh <stage> [options]
#     stage: preflight|prep|fetch|workdir|build|wheels|image|verify|all
#   options:
#     --force              ignore .stage_done marker
#     --tag <image:tag>    image tag for image/verify stages
#     --jobs <n>           parallelism (default: $INNER_JOBS or 64)
#     --timeout <sec>      hard wall-clock limit for the stage (default 0=none)
#     --dry-run            print the resolved command only
#     --no-guard           skip disk/memory guards
#
# Environment (all optional):
#   RVOCS_ROOT      repo root            (default /home/ubuntu/RVOCs-CICD/rvocs-hcs-amd)
#   RVOCS_WORK      work dir             (default $RVOCS_ROOT/work)
#   MIN_DISK_GB     required free disk   (default 120)
#   MIN_MEM_GB      required free memory (default 40)
#   CI_CPU_LOCK     default /var/lock/rvocs-ci.lock
#   CI_GPU_LOCK     default /var/lock/rvocs-gpu.lock
#   IMAGE_TAG       default rvocs-vllm-therock10.0-r9700-riscv64:sha-<12>
#   ARCH/GPU/KIND/  forwarded to build.sh as --arch/--gpu/--image-kind/--wheel-mode
#   WHEEL_MODE
#
# Exit codes: 0 ok/skip, 1 stage failed, 2 guard refused, 3 bad usage
# ---------------------------------------------------------------------------
set -euo pipefail

STAGE=""
FORCE=0
DRY=0
GUARD=1
JOBS="${INNER_JOBS:-64}"
TIMEOUT=0
IMAGE_TAG_ARG=""

die()  { printf '\033[1;31m[ci/stage]\033[0m %s\n' "$*" >&2; exit "${2:-1}"; }
info() { printf '\033[1;36m[ci/stage]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[ci/stage]\033[0m %s\n' "$*"; }

[ $# -ge 1 ] || die "usage: $0 <stage> [--force] [--tag X] [--jobs N] [--timeout S] [--dry-run]" 3
case "$1" in -h|--help) sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;; esac
STAGE="$1"; shift

while [ $# -gt 0 ]; do
  case "$1" in
    --force)    FORCE=1; shift ;;
    --dry-run)  DRY=1; shift ;;
    --no-guard) GUARD=0; shift ;;
    --tag)      IMAGE_TAG_ARG="${2:?--tag needs a value}"; shift 2 ;;
    --jobs)     JOBS="${2:?--jobs needs a value}"; shift 2 ;;
    --timeout)  TIMEOUT="${2:?--timeout needs a value}"; shift 2 ;;
    *) die "unknown option: $1" 3 ;;
  esac
done

case "$STAGE" in
  preflight|prep|fetch|workdir|build|wheels|image|verify|all) ;;
  *) die "invalid stage '$STAGE' (preflight|prep|fetch|workdir|build|wheels|image|verify|all)" 3 ;;
esac

ROOT="${RVOCS_ROOT:-/home/ubuntu/RVOCs-CICD/rvocs-hcs-amd}"
WORK="${RVOCS_WORK:-$ROOT/work}"
STATE="$WORK/.stage_done"
LOGD="$WORK/logs"
ALERT_DIR="${RVOCS_ROOT:-$(dirname "$ROOT")}/logs"
CPU_LOCK="${CI_CPU_LOCK:-/var/lock/rvocs-ci.lock}"
GPU_LOCK="${CI_GPU_LOCK:-/var/lock/rvocs-gpu.lock}"
MIN_DISK_GB="${MIN_DISK_GB:-120}"
MIN_MEM_GB="${MIN_MEM_GB:-40}"
ARCH="${ARCH:-riscv64}"
GPU="${GPU_TARGET:-r9700}"
KIND="${IMAGE_KIND:-vllm}"
WHEEL_MODE="${WHEEL_MODE:-source}"

[ -x "$ROOT/scripts/build.sh" ] || die "build.sh not found or not executable: $ROOT/scripts/build.sh"
mkdir -p "$STATE" "$LOGD" "$ALERT_DIR"

# ---------------------------------------------------------------- identity --
# A marker is valid only for the exact input set that produced it. The key is
# content-addressed (ci/lib/inputs.sh): the file contents of the paths THIS stage
# consumes, plus the upstream source tree and the build parameters. It is not
# keyed on this repo's HEAD, on a bare upstream commit id, or on mtimes, so a
# re-checkout, a `git submodule update`, or an edit to ANOTHER stage's scripts
# cannot invalidate a finished build (2026-11-26: three manual marker migrations,
# and every scripts/ edit put the 142-minute build back on the table).
# shellcheck source=lib/inputs.sh
source "$(dirname "$0")/lib/inputs.sh"

_key() {
  local fp
  fp="$(stage_fp "$ROOT" "$STAGE" "$ROOT/upstream/therock")"
  printf '%s' "${fp}-${ARCH}-${GPU}-${KIND}-${WHEEL_MODE}" | sha256sum | cut -c1-16
}
KEY="$(_key)"
HEAD_SHORT="$(git -C "$ROOT" rev-parse --short=12 HEAD 2>/dev/null || echo nogit)"
MARKER="$STATE/$STAGE.$KEY"
TAG="${IMAGE_TAG_ARG:-${IMAGE_TAG:-rvocs-vllm-therock10.0-r9700-riscv64:sha-$HEAD_SHORT}}"

# ------------------------------------------------------------------ resume --
if [ "$STAGE" != "verify" ] && [ "$FORCE" != 1 ] && [ -f "$MARKER" ]; then
  info "SKIP $STAGE: marker hit ($(basename "$MARKER")), inputs unchanged"
  echo "SKIP key=$KEY tag=$TAG (marker $(cat "$MARKER" 2>/dev/null || echo present))"
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] && printf '### %s: skipped (cache hit)\n- key: `%s`\n- image: `%s`\n' "$STAGE" "$KEY" "$TAG" >> "$GITHUB_STEP_SUMMARY"
  exit 0
fi

# ------------------------------------------------------------------ guards --
avail_disk_gb() { df -BG --output=avail "$WORK" 2>/dev/null | tail -1 | tr -dc '0-9'; }
avail_mem_gb()  { awk '/MemAvailable/ {printf "%d", $2/1024/1024}' /proc/meminfo; }
if [ "$GUARD" = 1 ] && [ "$STAGE" != "verify" ]; then
  D="$(avail_disk_gb)"; M="$(avail_mem_gb)"
  info "guards: disk=${D}G (need ${MIN_DISK_GB}G) mem=${M}G (need ${MIN_MEM_GB}G)"
  [ "${D:-0}" -ge "$MIN_DISK_GB" ] || { echo "REFUSED disk ${D}G < ${MIN_DISK_GB}G"; exit 2; }
  [ "${M:-0}" -ge "$MIN_MEM_GB" ]  || { echo "REFUSED mem ${M}G < ${MIN_MEM_GB}G"; exit 2; }
fi

# ----------------------------------------------------------------- command --
CMD=("$ROOT/scripts/build.sh" --stage "$STAGE" --arch "$ARCH" --gpu "$GPU"
     --image-kind "$KIND" --image-tag "$TAG" --jobs "$JOBS")
[ "$STAGE" = "wheels" ] && CMD+=(--wheel-mode "$WHEEL_MODE")
[ -n "${WHEELHOUSE_DIR:-}" ] && CMD+=(--wheelhouse "$WHEELHOUSE_DIR")
[ -n "${VENV_STACK:-}" ] && CMD+=(--venv "$VENV_STACK")
[ "$DRY" = 1 ] && CMD+=(--dry-run)

if [ "$DRY" = 1 ]; then
  printf 'DRY-RUN: key=%s\n  %s\n' "$KEY" "${CMD[*]}"
  exit 0
fi

# ------------------------------------------------------------------ locking --
LOCK_FD_PATH="$CPU_LOCK"
[ "$STAGE" = "verify" ] && LOCK_FD_PATH="$GPU_LOCK"
# The caller may already hold this lock (the workflow takes /var/lock/rvocs-gpu.lock
# around the whole GPU step). Taking it twice in the same process tree deadlocks:
#   flock -w 3600 hangs until timeout (observed 2026-11-27, 58 min wasted).
if [ "${RVOCS_LOCK_HELD:-0}" != 1 ]; then
  exec 9>"$LOCK_FD_PATH" 2>/dev/null || die "cannot open lock file $LOCK_FD_PATH (need sudo once: touch + chown)"
  if ! flock -w 3600 9; then die "lock timeout: another $STAGE holds $LOCK_FD_PATH"; fi
fi
info "lock acquired: $LOCK_FD_PATH"

# --------------------------------------------------------------------- run --
LOG="$LOGD/ci-$STAGE-$(date +%Y%m%d-%H%M%S).log"
START=$(date +%s)
info "stage=$STAGE key=$KEY tag=$TAG jobs=$JOBS log=$LOG"
set +e
if [ "$STAGE" = "verify" ]; then
  ( export GPU_RUN=1; [ "$TIMEOUT" -gt 0 ] && exec timeout "$TIMEOUT" "${CMD[@]}" || exec "${CMD[@]}" ) 2>&1 | tee "$LOG"
else
  ( [ "$TIMEOUT" -gt 0 ] && exec timeout "$TIMEOUT" "${CMD[@]}" || exec "${CMD[@]}" ) 2>&1 | tee "$LOG"
fi
RC=${PIPESTATUS[0]}
set -e
DUR=$(( $(date +%s) - START ))

# ---------------------------------------------------------------- evidence --
if [ "$RC" -ne 0 ]; then
  printf '%s ci/stage FAILED stage=%s rc=%s dur=%ss key=%s log=%s\n' \
    "$(date '+%F %T')" "$STAGE" "$RC" "$DUR" "$KEY" "$LOG" >> "$ALERT_DIR/ALERT"
  warn "FAILED stage=$STAGE rc=$RC dur=${DUR}s; tail of log:"
  tail -25 "$LOG" >&2 || true
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] && printf '### %s: FAILED (rc=%s, %ss)\n```\n%s\n```\n' \
    "$STAGE" "$RC" "$DUR" "$(tail -15 "$LOG")" >> "$GITHUB_STEP_SUMMARY"
  exit 1
fi

[ "$STAGE" != "verify" ] && printf 'ok %s %s\n' "$(date '+%F %T')" "$HEAD_SHORT" > "$MARKER"

DIGEST=""
if [ "$STAGE" = "image" ] || [ "$STAGE" = "verify" ]; then
  DIGEST="$(docker image inspect --format '{{index .RepoDigests 0}}' "$TAG" 2>/dev/null || echo local-only)"
  printf '%s\n' "$DIGEST" > "$WORK/image-digest.txt"
fi

cat > "$WORK/ci-summary.json" <<JSON
{"stage":"$STAGE","key":"$KEY","commit":"$HEAD_SHORT","tag":"$TAG",
 "digest":"$DIGEST","duration_s":$DUR,"rc":$RC,"log":"$LOG"}
JSON

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    printf '### %s: OK (%ss)\n' "$STAGE" "$DUR"
    printf -- '- commit: `%s`  key: `%s`\n' "$HEAD_SHORT" "$KEY"
    printf -- '- image: `%s`\n' "$TAG"
    [ -n "$DIGEST" ] && printf -- '- digest: `%s`\n' "$DIGEST"
    printf -- '- log: `%s`\n' "$LOG"
  } >> "$GITHUB_STEP_SUMMARY"
fi
info "OK stage=$STAGE dur=${DUR}s"
exit 0
