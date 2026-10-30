#!/usr/bin/env bash
# ============================================================================
# Framework-side source pins (RISC-V porting variant)
#
# Everything points at PUBLIC upstream; no internal GitLab is involved. Porting
# changes live as patches under patches/riscv64/<component>/series (see
# patches/riscv64/README.md).
#
# The refs below are the BASELINE COMMITS of the patches and must match exactly
# the base used when the patches were exported, otherwise git apply conflicts:
#   pytorch     cf30153c4c  release/2.13 commit from 2026-09 (version.txt = 2.13.0a0)
#   triton      5f3f125e8f  "[release 3.7] Release Triton to pypi" (= v3.7.0)
#   vllm        98dff2a81d  main commit from 2026-09-08 (0.1.dev1)
#   torchvision v0.28.0     no patches, pure upstream
# ============================================================================

declare -A SRC_URL=()
declare -A SRC_REF=()
SRC_ORDER=()

src_define() {
  SRC_ORDER+=( "$1" )
  SRC_URL["$1"]="$2"
  SRC_REF["$1"]="$3"
}

src_define pytorch     https://github.com/pytorch/pytorch.git      cf30153c4c131c8164ee7798e5022d810682e2cb
src_define torchvision https://github.com/pytorch/vision.git       v0.28.0
src_define triton      https://github.com/triton-lang/triton.git    5f3f125e8f63c24613f1f73b937442864f263f94
src_define vllm        https://github.com/vllm-project/vllm.git     98dff2a81d747d1dba01a47f939f48c3526d4206

# When changing the baseline:
#   1) update the refs here (tag or commit)
#   2) ./scripts/build.sh --stage fetch          fetch the new sources
#   3) ./scripts/tools/patch.sh check --verbose  see whether the patches still apply
#   4) fix conflicts as described in docs/PATCHES.md section 2, or capture them again
