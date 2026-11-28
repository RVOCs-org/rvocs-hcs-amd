# MIOpen shim for USE_MIOPEN=0 torch builds

`libMIOpen.so.1` (14 KB) exports the sixteen `at::_ops::*` / `at::native::miopen_*`
wrappers that `libtorch_hip.so` references even when torch is configured with
`USE_MIOPEN=0`. The wrappers are stubs: text models served by vLLM never call the
MIOpen convolution / batch-norm entry points.

The runtime image ships this file as `/opt/rocm/lib/libMIOpen.so.1` (the image has
no 473 MB real MIOpen), which is why `import torch` works inside the image but
failed on the build host until 2026-11-26: the host's `dist/rocm/lib` holds the
real library, which does not export these wrappers, and `LD_LIBRARY_PATH` puts it
ahead of `torch/lib`.

`scripts/04-wheels.sh:install_miopen_stub()` installs it in both places
(`<venv>/.../torch/lib/` and `dist/rocm/lib/libMIOpen.so.1.0`). Keep the two
copies byte-identical; see the guide, chapter 33.3.
