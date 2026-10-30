import glob
cands = glob.glob("/opt/venv-torch/lib/python*/site-packages/vllm/platforms/__init__.py")
assert cands, "vllm platforms __init__ not found"
p = cands[0]
s = open(p).read()
old = "    if not is_rocm and in_wsl():"
new = ("    # vllm-rocm-fallback: amdsmi is blind on this platform (PCI domain != 0000);\n"
       "    # fall back to PyTorch-based ROCm detection regardless of WSL\n"
       "    if not is_rocm:")
if "vllm-rocm-fallback" not in s:
    assert old in s, "vllm rocm_platform_plugin pattern not found"
    open(p, "w").write(s.replace(old, new, 1))
    print("VLLM_ROCM_FALLBACK_PATCHED", p)
else:
    print("VLLM_ROCM_FALLBACK_ALREADY")
