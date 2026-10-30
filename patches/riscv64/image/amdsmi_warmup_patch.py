#!/usr/bin/env python3
"""Bake amdsmi warm-up into the stack venv (runs at image build time).

Root cause (verified on 2x Radeon AI PRO R9700, riscv64):
  1. Order sensitivity: libamdsmi global init must run BEFORE the HIP runtime
     (torch.cuda.init()) touches DRM in-process, otherwise amdsmi's first init
     is permanently poisoned (init returns None but enumeration yields 0
     handles; shutdown raises NOT_INIT; re-init cycles never self-heal).
  2. Reference lifetime: even a healthy early init is GC-fragile - the handle
     list must stay referenced for the whole process lifetime.
  3. Deployment trap: venv sitecustomize.py is shadowed by
     /usr/lib/python3.14/sitecustomize.py (symlink to /etc), so .pth injection
     is the reliable mechanism: .pth files execute at site initialization,
     before sitecustomize and before any application import.

Effect: every python process in the venv starts with amdsmi initialized and
keeps handle refs in sys._AMDSSI_KEEP, so vLLM's ROCm platform reads real
device name/UUID/NUMA instead of falling back to guesswork.
"""
import pathlib
import sysconfig

sp = pathlib.Path(sysconfig.get_paths()["purelib"])
(sp / "amdsmi_warmup.py").write_text('''\
# libamdsmi global init MUST happen before any HIP runtime (torch) touches
# DRM, and the handle list must STAY REFERENCED for the process lifetime,
# else the internal state is freed and enumeration is permanently poisoned
# (0 handles, NOT_INIT on shutdown, no self-heal). See
# docker/riscv-gfx1201/patches/amdsmi_warmup_patch.py header for details.
import os
import sys
try:
    from amdsmi import amdsmi_interface as _I
    _r = _I.amdsmi_init()
    _AMDSSI_KEEP = _I.amdsmi_get_processor_handles()
    sys._AMDSSI_KEEP = _AMDSSI_KEEP  # module-global refs survive GC
    if os.environ.get("AMDSSI_DEBUG"):
        print(f"[amdsmi-warmup] init={_r} handles={len(_AMDSSI_KEEP)}",
              file=sys.stderr)
except Exception:
    pass
''', encoding="utf-8")
(sp / "zz_amdsmi_warmup.pth").write_text("import amdsmi_warmup\n", encoding="utf-8")
print("AMD_SMI_WARMUP_OK", sp)
