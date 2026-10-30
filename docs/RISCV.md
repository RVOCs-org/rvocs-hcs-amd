# RISC-V (riscv64) 构建说明

本页只讲 riscv64 与 x86_64 不同的地方。通用阶段见 [BUILD.md](BUILD.md)，补丁机制见 [PATCHES.md](PATCHES.md)，
部署与调参见 [VLLM.md](VLLM.md)。

## 1. 为什么只能源码构建

TheRock 官方在 `stable/nightly.repo.amd.com` 只发布 x86_64（及部分 aarch64）产物，
**没有 riscv64 的 tarball，也没有 riscv64 的 torch/vLLM wheel**。因此：

- `--mode prebuilt` 在 riscv64 上被脚本直接拒绝；
- `--wheel-mode pip` 不可用，必须 `source`；
- 框架侧源码用内部 GitLab（rv-rocm）的移植仓库，见 `config/sources.sh`。

## 2. 宿主前置

```bash
sudo apt-get install -y build-essential pkg-config gfortran git curl \
  cmake ninja-build xxd automake libtool python3-venv python3-dev \
  libegl1-mesa-dev texinfo bison flex zlib1g-dev libzstd-dev liblzma-dev \
  libexpat1-dev libpciaccess-dev libnuma-dev libcap-dev libncurses-dev \
  libedit-dev libxml2-dev libelf-dev ccache git-lfs rustc cargo

pip3 install --user --break-system-packages meson==1.12.0 joblib simplejson yappi invoke filelock \
  CppHeaderParser msgpack zstandard
```

四个容易漏的硬前置：

1. **gfortran** 若只装了 `gfortran-15`，需要软链：`sudo ln -s /usr/bin/gfortran-15 /usr/local/bin/gfortran`。
2. **打过补丁的 patchelf**（上游 ≤0.18.0 会写坏 PHDR 位于尾部 LOAD 段的 ELF，kpack 拆包后的库正是这种布局）：
   ```bash
   sudo env INSTALL_PREFIX=/usr/local ./upstream/therock/dockerfiles/install_pinned_patchelf.sh
   ```
3. **CppHeaderParser**（hip-clr 的 PCH 生成）与 **msgpack/zstandard**（kpack 拆包）是构建期 Python 依赖。
4. **磁盘与内存**：源码约 30 GB、构建树 200 GB 级；`amd-llvm` 链接每 job 4–8 GB。
   80 核/121 GB 机器建议先 `--jobs 40`，内存吃紧降到 8–16。

## 3. 一键构建

```bash
./scripts/build.sh --gpu r9700
```

等价于 `--mode source --wheel-mode source --image-kind vllm`，阶段序列：

```
preflight → fetch → workdir → build → wheels → image → verify
```

分阶段（长构建建议每步 nohup）：

```bash
./scripts/build.sh --stage prep      # 源码 + 补丁
./scripts/build.sh --stage build     # TheRock（~17h，可断点续跑）
./scripts/build.sh --stage wheels    # 四个 wheel（~5h）
./scripts/build.sh --stage image     # 镜像（~50min）
GPU_RUN=1 ./scripts/build.sh --stage verify
```

### 参考耗时（10.10.128.103，80 核 riscv64 + R9700）

| 阶段 | 耗时 | 产物 |
| --- | --- | --- |
| S1 TheRock（ml 组件集） | 17h31m（12 次增量续跑，零重编） | `dist/rocm` 8.5 GB |
| S2 四个 wheel + venv | ~5h | triton 262 MB / torch 329 MB / torchvision 1.2 MB / vllm 42 MB |
| S3 镜像 | 49 min | 17.4 GB |
| S4 压测（可选） | 5.5h | 最优 740 tok/s @ max-num-seqs=96 |

## 4. 构建产物与镜像布局

| 宿主路径 | 镜像内路径 | 说明 |
| --- | --- | --- |
| `upstream/therock/build/dist/rocm` | `/opt/rocm` | ROCm 用户态 + `.kpack` |
| `work/venv-stack` | `/opt/venv-torch` | torch/triton/torchvision/vLLM + 依赖 |
| `work/wheelhouse/*.whl` | `/opt/vllm-wheels` | wheel 归档 |

> venv 在宿主组装、整体搬入镜像，`bin/*` 的 shebang 由 Dockerfile 改写到 `/opt/venv-torch`。
> 因此**镜像内不需要 gcc**，也不要在容器里 `pip install`（源码构建会失败）。

## 5. 与已验证构建的对应关系

本仓库的 S1/S2/S3 与参考实现（10.10.128.103 的 `~/work/verify/stack`）一一对应：

| 参考实现 | 本仓库 |
| --- | --- |
| `build.sh` stage1（TheRock cmake+ninja） | `scripts/03-build.sh` |
| `scripts/p2_torch3.sh`（build_amd.py→cmake→ninja→bdist_wheel） | `scripts/wheels/torch.sh` |
| `scripts/riscv-gfx1201/s2_triton_only.sh` + `triton_env.sh` | `scripts/wheels/triton.sh` |
| `scripts/riscv-gfx1201/s2_other_wheels.sh`（torchvision/vllm） | `scripts/wheels/{torchvision,vllm}.sh` |
| `s2_venv_assemble.sh` | `scripts/04-wheels.sh` 的安装段 |
| `s3_docker.sh` + `docker/riscv-gfx1201/Dockerfile` | `scripts/05-image.sh` + `docker/vllm.Dockerfile` |
| `docker/riscv-gfx1201/patches/*.py` | `patches/riscv64/image/*.py`（待导入） |

## 6. 补丁（已全部内置，无内网依赖）

移植改动已全部以补丁形式入库（21 个 `.patch` + 3 个镜像期 `.py`，约 8.6 MB），
**不依赖内网 GitLab**：源码全部来自公开上游，补丁在 `--stage workdir` 阶段应用。

| 组件 | 基线 | 补丁数 | 解决的问题 |
| --- | --- | --- | --- |
| `therock` | `16adc4d8`（therock-10.0） | 7 | sysdeps meson `--version-script`、hwloc config.guess、gfx1201 CMake、amdsmi 延迟构建、NVPTX |
| `rocm-libraries` | `8d1ae90e` | 1 | hipSOLVER 的 LAPACK `RISCV64_GENERIC` 目标 |
| `rocm-systems` | `6b0e43f3` | 6 | v100 平台适配、rocr/clr 可移植 pause、kpack RISC-V ELF、RCCL cpuid 守卫 |
| `amd-llvm` | `9f8c0bcf` | 1 | OMPT 设备追踪 hook 弱符号兜底 |
| `pytorch` | `cf30153c4c` | 3 | riscv64/gfx1201 适配、libroctx64 参数化、HIP 后端源码 |
| `triton` | `5f3f125e8f` | 2 | 依赖 LLVM riscv module、移植到 LLVM/MLIR 23 |
| `vllm` | `98dff2a81d` | 1 | HIP 目标改用 GNU ld，规避 lld COMDAT 回归 |
| （镜像期） | — | 3 | amdsmi 预热、vLLM ROCm 平台回退、torch 设备计数 |

逐条说明见 [PATCHES.md](PATCHES.md) §7。构建参数上有两处 riscv64 专属默认（`03-build.sh` 自动处理）：

- **`-DBUILD_TESTING=OFF`**：规避 clang/lld 处理 GCC 静态库 COMDAT + 异常表段的 bug。
  要跑测试用 `THEROCK_BUILD_TESTING=1` 覆盖。
- **不启用 ccache**：ccache 的 `--offload-compress` 与 amdclang 设备码在 riscv 上未验证。
  需要时 `USE_CCACHE=1`。

### 未纳入的部分（内网私有，无法复现）

pytorch 的 4 个子模块（`kineto`/`mslk`/`fbgemm`/`gloo`）原指向内网 HIP 修补版本，
这部分以 gitlink 形式存在，无法转成补丁。若在 riscv64 上编译失败，需要单独处理（届时
用 `patch.sh capture` 从这些子模块的源码导出补丁即可）。

## 7. 验证要点

```bash
GPU_RUN=1 ./scripts/build.sh --stage verify
```

| 检查点 | 含义 |
| --- | --- |
| kpack 中 `gfx1201` 文件数 > 0 | 设备码已按 RISC-V ELF 正确拆分 |
| `ldd libamdhip64.so` 无 not found | 私有 sysdeps（zstd/elfutils/libdrm）随 dist 进镜像 |
| `rocminfo` 报出 `gfx1201` | HSA 运行时能枚举 Navi 48 |
| `torch.cuda.is_available()` 为 True | torch 的 ROCm 后端正常 |
| `vllm --version` / `vllm serve --help` | 入口可用（真正的 serve 冒烟需模型） |

## 8. 部署注意

- 多卡：`--tensor-parallel-size 2` 通常要配 `--enforce-eager`（RDNA4 上 graph 捕获 + RCCL 易异常）。
- `--max-num-seqs` 取 2 的幂，工程推荐 64，上限 96。
- 首次启动 `torch.compile` 需 4–5 分钟，按 `max-num-seqs` 缓存。
- 多卡兼容默认值（`NCCL_CUMEM_ENABLE=1`、`NCCL_WIN_ENABLE=0`）在 riscv64 构建时自动写入
  `/opt/stack/rccl_fix.env`，可在运行时用 `-e` 覆盖。
