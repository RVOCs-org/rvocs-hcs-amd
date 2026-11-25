#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# ci/ci-sync.sh - make $RVOCS_ROOT match the CI commit, or explain why not.
#
# Why: the build host keeps a persistent source tree (with a 19 GB upstream/ and
# warm ccache) instead of a fresh checkout per job. GitHub Actions' checkout
# action cannot be used here because codeload.github.com is blocked on this
# network, so each job calls this script instead.
#
# Policy: never destroy local build state.
#   - already at target            -> exit 0
#   - tracked files modified       -> warn, keep current tree, exit 0
#   - target commit available      -> detached checkout, exit 0
#   - target commit not available  -> warn, keep current tree, exit 0
#
# Env: RVOCS_ROOT (default /home/ubuntu/RVOCs-CICD/rvocs-hcs-amd), GITHUB_SHA
# ---------------------------------------------------------------------------
set -euo pipefail

R="${RVOCS_ROOT:-/home/ubuntu/RVOCs-CICD/rvocs-hcs-amd}"
CUR=""
TARGET="${GITHUB_SHA:-}"

if [ ! -d "$R/.git" ]; then
  echo "::error::RVOCS_ROOT is not a git repository: $R"
  exit 1
fi

CUR="$(git -C "$R" rev-parse HEAD)"
TARGET="${TARGET:-$CUR}"
DIRTY="$(git -C "$R" status --porcelain --untracked-files=no | wc -l | tr -d ' ')"

echo "root=$R"
echo "current=$CUR"
echo "target=$TARGET"
echo "tracked_dirty=$DIRTY"

if [ "$CUR" = "$TARGET" ]; then
  echo "sync=already_at_target"
  exit 0
fi

if [ "$DIRTY" -ne 0 ]; then
  echo "::warning::tracked files are modified in $R; keeping current tree ($CUR) instead of switching to $TARGET"
  echo "sync=skipped_dirty"
  exit 0
fi

git -C "$R" fetch --no-tags --prune origin '+refs/heads/*:refs/remotes/origin/*' >/dev/null 2>&1 \
  || echo "::warning::git fetch failed (network?); trying local object store only"

if git -C "$R" cat-file -e "${TARGET}^{commit}" 2>/dev/null; then
  git -C "$R" checkout --detach "$TARGET" >/dev/null 2>&1
  echo "sync=switched"
  echo "checked_out=$(git -C "$R" rev-parse HEAD)"
else
  echo "::warning::commit $TARGET is not present locally; keeping current tree ($CUR)"
  echo "sync=skipped_missing_commit"
fi

exit 0
