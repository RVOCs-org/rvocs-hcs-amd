# Dist "dev artifacts" required by the Python stack (triton) at wheels time.
#
# TheRock installs only runtime artefacts (.so/.a) into dist, but triton's CMake
# needs two kinds of build-tree files. Both failures were observed on this tree:
#
#   1) lib/llvm/lib/objects-Release/**
#      dist's MLIRTargets.cmake references the MLIR C API OBJECT libraries
#      (obj.MLIRCAPIDebug/Debug.cpp.o, ...) which install rules never copy, so
#      find_package(MLIR) aborts with
#        The imported target "obj.MLIRCAPIDebug" references the file ... but this
#        file does not exist
#
#   2) lib/llvm/bin/FileCheck and friends
#      triton's configure_file() references LLVM build tools; dist ships only the
#      94 runtime tools, so configure aborts with
#        CMake Error: File .../lib/llvm/bin/FileCheck does not exist
#
# Copies are taken from a component's private dist (build/<x>/<y>/dist/lib/llvm)
# and from the amd-llvm build tree (~250 MB of LLVM tools).
ensure_dist_dev_artifacts() {
  local dst="$DIST_DIR/lib/llvm"
  local src f b n=0

  [ -d "$dst" ] || { warn "skip dist dev artifacts: $dst not found"; return 0; }

  if [ ! -d "$dst/lib/objects-Release" ]; then
    src=$(ls -d "$THEROCK_BUILD"/*/*/dist/lib/llvm/lib/objects-Release \
                 "$THEROCK_BUILD"/*/*/*/dist/lib/llvm/lib/objects-Release \
                 2>/dev/null | head -1)
    if [ -n "$src" ]; then
      cp -a "$src" "$dst/lib/" && log "  dist: + objects-Release (MLIR OBJECT libs)"
    else
      warn "objects-Release not found in any component dist; triton may fail on MLIRTargets.cmake"
    fi
  fi

  src="$THEROCK_BUILD/compiler/amd-llvm/build/bin"
  if [ -d "$src" ] && [ -d "$dst/bin" ]; then
    for f in "$src"/*; do
      [ -f "$f" ] || continue
      b=$(basename "$f")
      if [ ! -e "$dst/bin/$b" ]; then
        cp -a "$f" "$dst/bin/$b" && n=$((n + 1))
      fi
    done
    [ "$n" -gt 0 ] && log "  dist: + $n LLVM build tools (FileCheck etc.)"
  fi
  return 0
}
