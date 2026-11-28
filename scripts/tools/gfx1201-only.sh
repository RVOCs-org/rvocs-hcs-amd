#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# gfx1201-only.sh - stop subprojects from building gfx1200 alongside gfx1201.
#
# Why: THEROCK_AMDGPU_TARGETS only reaches subprojects that honour it.
# hipBLASLt/Tensile derives its architecture list from DEFAULT_GPUS, and
# cmake/therock_amdgpu_targets.cmake puts gfx1200 and gfx1201 in the same
# gfx120X-all family. Measured 2026-11-25: a CI run on this host configured
#         [hipBLASLt configure] -- Architectures to process: gfx1200;gfx1201
# and regenerated the entire Tensile device library for both arches (~40 min of
# 73-core CPU) even though the target is a single R9700 / gfx1201.
#
# Effect: removes gfx1200 from the gfx120X-all family, leaving that family with
# exactly one member (gfx1201). The gfx1200 target itself stays declared under
# dgpu-all, so selecting gfx1200 explicitly still works - we only stop it from
# riding along via the family default.
#
# Idempotent: prints CHANGED=1 the first time, CHANGED=0 on every later call,
# so it is safe to run on every build invocation. Callers should force a cmake
# reconfigure when CHANGED=1.
#
# Usage: gfx1201-only.sh <path/to/therock_amdgpu_targets.cmake>
# ---------------------------------------------------------------------------
set -euo pipefail

F="${1:?usage: gfx1201-only.sh <therock_amdgpu_targets.cmake>}"

if [ ! -f "$F" ]; then
  echo "ERROR file not found: $F"
  exit 1
fi

NEEDLE='therock_add_amdgpu_target(gfx1200 "AMD RX 9060 / XT" FAMILY dgpu-all gfx120X-all'
REPL='therock_add_amdgpu_target(gfx1200 "AMD RX 9060 / XT" FAMILY dgpu-all'

if ! grep -qF 'therock_add_amdgpu_target(gfx1201 "AMD RX 9070 / XT" FAMILY dgpu-all gfx120X-all' "$F"; then
  echo "ERROR gfx1201 is not in the gfx120X-all family; refusing to touch $F"
  exit 1
fi

if ! grep -qF "$NEEDLE" "$F"; then
  echo "CHANGED=0 already_patched=1 file=$F"
  exit 0
fi

cp -a "$F" "$F.bak.$(date +%s)"
# Replace only the exact gfx1200 line; gfx1201 keeps its gfx120X-all membership.
python3 - "$F" "$NEEDLE" "$REPL" <<'PY'
import sys
path, needle, repl = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, encoding='utf-8') as fh:
    lines = fh.readlines()
hits = 0
out = []
for line in lines:
    if line.startswith(needle):
        out.append(repl + line[len(needle):])
        hits += 1
    else:
        out.append(line)
if hits != 1:
    sys.exit("expected exactly 1 gfx1200 family line, found %d" % hits)
with open(path, 'w', encoding='utf-8') as fh:
    fh.writelines(out)
print("patched_lines=%d" % hits)
PY

echo "CHANGED=1 file=$F"
grep -n 'gfx1200 "AMD RX 9060' "$F" | head -2
grep -n 'gfx1201 "AMD RX 9070' "$F" | head -2
