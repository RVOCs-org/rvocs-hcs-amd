#!/usr/bin/env bash
# ci/lib/inputs.sh - content-addressed stage fingerprints.
#
# Why this exists (measured 2026-11-26):
#   The old key hashed `git -C upstream/therock rev-parse HEAD`, i.e. a COMMIT ID,
#   and the whole patches/docker/scripts tree for every stage. Consequences:
#     * a pin bump to a commit whose tree is identical (re-point, re-clone,
#       cherry-pick onto a new base) invalidated a finished 142-minute build;
#     * editing scripts/04-wheels.sh - which the TheRock build never reads -
#       also invalidated it (three manual marker migrations that day).
#   The key must depend on the CONTENT a stage consumes, nothing else.
#
# Rules enforced here:
#   * file contents only (find | sort | sha256sum | sha256sum) - never mtimes;
#   * upstream is hashed as a git TREE (blob ids), never as a commit id, so
#     identical content at a different commit reuses the marker;
#   * the path set is scoped per stage: a wheels/image/CI edit cannot touch the
#     build key, and a docs commit upstream cannot trigger a rebuild;
#   * `ci/` itself is part of every key, so changing this file invalidates all.
#
# shellcheck shell=bash

_ihash() { sha256sum | cut -c1-16; }

_hash_paths() { # _hash_paths <root> <path...>  -> 16 hex chars
  local root="$1"; shift
  [ $# -gt 0 ] || { echo empty; return 0; }
  ( cd "$root" 2>/dev/null && \
    find "$@" -type f ! -name '*.bak*' ! -name '*~' ! -name '*.orig' -print0 2>/dev/null \
      | sort -z | xargs -0 -r sha256sum 2>/dev/null ) | _ihash
}

# Upstream source identity: the content tree of the paths TheRock's build reads.
# Docs / tests / examples / dockerfiles / .github / skills are excluded on
# purpose - they cannot change a single compiled object, so they must not force a
# rebuild. Submodule gitlinks are part of ls-tree output, so component pins are
# still covered (and they change exactly when the components change).
upstream_fp() { # upstream_fp <therock-tree>
  local t="${1:-}"
  [ -n "$t" ] && [ -d "$t" ] || { echo nopin; return 0; }
  git -C "$t" ls-tree -r HEAD -- \
      base compiler core comm-libs dctools debug-tools emulation external-builds \
      math-libs media-libs ml-libs profiler third-party cmake build_tools \
      CMakeLists.txt FLAGS.cmake BUILD_TOPOLOGY.toml CMakePresets.json \
      requirements.txt rocm-libraries rocm-systems 2>/dev/null | _ihash
}

# Per-stage path sets. Keep a stage's own scripts in its set, and keep the
# scripts of OTHER stages out of it.
_stage_paths() { # _stage_paths <stage> -> space separated paths (repo-relative)
  case "$1" in
    preflight)  echo "ci" ;;
    fetch|workdir|prep)
                echo "patches config scripts/build.sh scripts/01-fetch.sh scripts/02-workdir.sh scripts/lib ci" ;;
    build)      echo "patches config scripts/build.sh scripts/03-build.sh scripts/lib scripts/tools ci" ;;
    wheels)     echo "patches config scripts/build.sh scripts/04-wheels.sh scripts/lib scripts/wheels ci" ;;
    image)      echo "docker config scripts/build.sh scripts/05-image.sh scripts/lib ci" ;;
    verify)     echo "docker config scripts/build.sh scripts/06-verify.sh scripts/lib ci" ;;
    all)        echo "patches docker config scripts ci" ;;
    *)          echo "patches docker config scripts ci" ;;   # unknown stage: fail safe (rebuild)
  esac
}

# Per-component wheel fingerprint: the shared inputs plus THAT component's build
# script only, so editing scripts/wheels/triton.sh cannot force a torch rebuild.
wheel_fp() { # wheel_fp <repo-root> <component> [therock-tree]
  local root="$1" comp="$2" tr="${3:-$1/upstream/therock}"
  printf '%s-%s-%s' "$(upstream_fp "$tr")" \
    "$(_hash_paths "$root" patches config scripts/build.sh scripts/04-wheels.sh scripts/lib "scripts/wheels/$comp.sh")" \
    "$comp" | _ihash
}

stage_fp() { # stage_fp <repo-root> <stage> [therock-tree]
  local root="$1" stage="$2" tr="${3:-$1/upstream/therock}" paths
  paths="$(_stage_paths "$stage")"
  # shellcheck disable=SC2086
  printf '%s-%s' "$(upstream_fp "$tr")" "$(_hash_paths "$root" $paths)" | _ihash
}
