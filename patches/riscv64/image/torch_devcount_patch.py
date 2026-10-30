import glob
cands = glob.glob("/opt/venv-torch/lib/python*/site-packages/torch/cuda/__init__.py")
assert cands, "torch/cuda/__init__.py not found"
p = cands[0]
s = open(p).read()
old = """        if torch.version.hip:
            nvml_count = _device_count_amdsmi()
        else:
            nvml_count = _device_count_nvml()"""
new = """        if torch.version.hip:
            nvml_count = _device_count_amdsmi()
            if nvml_count <= 0:
                nvml_count = -1  # devcount-fallback: amdsmi blind on this platform (PCI domain != 0000); use direct HIP count
        else:
            nvml_count = _device_count_nvml()"""
if "devcount-fallback" not in s:
    assert old in s, "torch device_count pattern not found"
    open(p, "w").write(s.replace(old, new, 1))
    print("TORCH_DEVCOUNT_PATCHED", p)
else:
    print("TORCH_DEVCOUNT_ALREADY")
