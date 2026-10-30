# 构建手册

## 1. 参数总览

```
./scripts/build.sh [选项]
```

| 选项 | 取值 | 默认 | 说明 |
| --- | --- | --- | --- |
| `--stage` | `all/preflight/fetch/workdir/build/wheels/image/verify/prep` | `all` | 只跑某个阶段；`prep` = fetch + workdir |
| `--gpu` | 见 `--list-gpus` | `r9700` | 目标 GPU（决定 family / gfx / device extra） |
| `--family` | 如 `gfx120X-all` | 由 GPU 表推导 | 直接给 gfx 架构名时必填 |
| `--arch` | `x86_64/aarch64/riscv64` | 本机 | 目标架构 |
| `--mode` | `source/prebuilt` | x86→prebuilt，riscv64→source | ROCm 来源 |
| `--image-kind` | `vllm/runtime` | `vllm` | 产物类型 |
| `--wheel-mode` | `auto/pip/source` | x86→pip，riscv64→source | Python 栈来源 |
| `--components` | `runtime/ml/all` | `ml` | TheRock 组件集 |
| `--wheelhouse` | 目录 | — | 离线 wheel（优先使用） |
| `--venv` | 目录 | — | 复用已有 venv（跳过 wheels 阶段） |
| `--rocm-version` | 如 `10.0.0` | `config/defaults.sh` | prebuilt 的 tarball 版本 |
| `--channel` | `stable/nightly/rc/bkc/dev` | `stable` | prebuilt 的发布通道 |
| `--base-image` | 镜像名 | Ubuntu 按架构 | 基础镜像 |
| `--proxy` | `cn/direct/auto` | `auto` | `cn` 走 gh-proxy + 清华 PyPI |
| `--jobs` | 数字 | `nproc` | 并行度 |
| `--workdir` | 目录 | `./work` | 日志/下载/src/venv/wheelhouse 存放处 |
| `--image-tag` | 字符串 | `amd-therock/<kind>:<arch>-<gpu>-<ver>` | 镜像名 |
| `--dry-run` | — | — | 只打印不执行 |

环境变量等价入口：`GPU_ID / MODE / IMAGE_KIND / WHEEL_MODE / COMPONENTS / THEROCK_EXTRA_ARGS / USE_CCACHE / GPU_RUN / WITH_GCC`。

## 2. 阶段做了什么

### preflight

只读检查：架构、内存、磁盘（source 需 ~220 GB）、git/cmake/ninja/gfortran/python3、
docker daemon 与 buildx、patchelf（kpack 拆包前置）、msgpack/zstandard、子模块 pin、补丁文件齐备。

### fetch

- **ROCm（source）**：`git submodule update --init upstream/therock` → 建 `work/venv` 装
  `requirements.txt` → 在源码树内跑 `build_tools/fetch_sources.py`（约 30 GB）。
  完成后写 `work/.sources-fetched`（内容为 pin），pin 不变则跳过。
- **ROCm（prebuilt）**：下载 `therock-dist-linux-<bundle>-<version>.tar.gz` 并解包到 `work/artifacts/install`。
- **框架侧（vllm + wheel-mode=source）**：按 `config/sources.sh` 克隆/切到指定 ref，
  记录到 `work/.sources-pins`。

> 一个镜像跑所有卡：`THEROCK_BUNDLE=multi-arch ./scripts/build.sh`。

### workdir

- 校验子模块 HEAD 与 pin
- 按 `patches/<arch>/<component>/series` 顺序 `git apply`（幂等）
- 写 `work/env.sh`（人工调试用）与 `work/.baseline`

### build

```bash
cmake -B upstream/therock/build -GNinja upstream/therock \
  -DCMAKE_BUILD_TYPE=Release -DTHEROCK_AMDGPU_FAMILIES=<family> <组件集开关>
cmake --build upstream/therock/build -j <jobs>
```

产物：`upstream/therock/build/dist/rocm`（完整 ROCm SDK，含 `.kpack/`）。

注意：同一构建目录不能换 family 重配；已有 `CMakeCache.txt` 时自动跳过 configure 直接增量；
`USE_CCACHE=0` 可关闭 ccache。

### wheels

| 模式 | 做法 | 适用 |
| --- | --- | --- |
| `pip` | 从 TheRock wheel 索引 `pip install "torch[device-<gfx>]" ...vllm`，并归档 wheel | x86_64 |
| `source` | 依次跑 `scripts/wheels/{torch,triton,torchvision,vllm}.sh` 编译 wheel，再装入 venv | riscv64 |

产物：`work/venv-stack`（整体搬进镜像）+ `work/wheelhouse/*.whl`。
`source` 模式下 torch 先装进 venv（后续组件编译需要 `import torch`），并补装 vLLM 运行期依赖。

### image

组装 `work/image-ctx`（`cp -al` 硬链接，省时省空间）：

```
dist/         ← dist/rocm 或 artifacts/install
venv-torch/   ← work/venv-stack（vllm）
wheelhouse/   ← work/wheelhouse
benchmarks/   ← work/src/vllm/benchmarks（有则带）
patches/      ← patches/<arch>/image/*.py（镜像构建期执行的 python 补丁）
Dockerfile / entrypoint.sh
```

然后 `docker build -f docker/vllm.Dockerfile`（或 `runtime.Dockerfile`）。
镜像内会改写 venv 里 console script 的 shebang（宿主路径 → `${STACK_VENV}`），
再做一次 `import torch, triton, torchvision, vllm` 自检。

### verify

容器内检查：架构、`/opt/rocm` 结构、`libamdhip64`/`libhsa-runtime64`、`gfx` kpack 数量、`ldd`；
vllm 镜像额外检查 venv、`import` 四件套、`torch.version.hip`、`vllm --version`、`vllm serve --help`、
入口脚本、benchmarks、wheel 归档。
`GPU_RUN=1` 时挂 `/dev/kfd`、`/dev/dri`，跑 `rocminfo` 与 `torch.cuda.is_available()`。

## 3. 组件集（--components）

| preset | 包含 | 用途 |
| --- | --- | --- |
| `runtime` | core-runtime、core-hip、amdsmi、compiler | 最小可跑 HIP |
| `ml` | runtime + prim/blas/rand/solver/sparse/fft/MIOpen/rocWMMA | **torch / vLLM 必需（默认）** |
| `all` | `THEROCK_ENABLE_ALL=ON` | 上游全量 |

逃生口：

```bash
THEROCK_EXTRA_ARGS="-DTHEROCK_ENABLE_RCCL=ON -DTHEROCK_BUNDLE_3RDPARTY=OFF" \
  ./scripts/build.sh --components runtime
```

## 4. 耗时与资源（参考）

| 阶段 | x86_64（prebuilt+pip） | x86_64（源码） | riscv64（源码，80 核） |
| --- | --- | --- | --- |
| fetch | 2–10 min | 20–40 min | 30–60 min + 框架源码 |
| build | — | 1.5–4 h | ~17 h（ml 组件集） |
| wheels | 2–5 min（下载） | 1–3 h | ~5 h（4 个 wheel） |
| image | 1–3 min | 1–3 min | ~50 min（镜像 17 GB） |
| verify | <1 min | <1 min | <1 min |

内存：`amd-llvm` 链接每 job 4–8 GB；torch/vLLM 编译建议 `MAX_JOBS` 与内存匹配（80 核/121 GB 用 32）。

## 5. 缓存与增量

| 想改的东西 | 命令 |
| --- | --- |
| 改 ROCm 源码后重编 | `--stage build`（ninja 增量） |
| 加补丁 | `--stage workdir && --stage build` |
| 只改 entrypoint / Dockerfile | `--stage image` |
| 换 torch/vllm 源码版本 | 改 `config/sources.sh` → `--stage fetch wheels` |
| 换组件集 / family | `baseline.sh clean --yes` 后 `--stage build` |
| 复用现成 venv | `--stage image --venv <dir>` |

## 6. 故障排查

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| `fetch_sources.py` 超时 / 403 | GitHub 直连不通 | `--proxy cn` |
| kpack 拆分报 ELF/PHDR 错误 | patchelf 未打补丁 | 按 `preflight` 提示装 pinned patchelf |
| `split_artifacts.py: No module named msgpack` | 缺 python 依赖 | `pip3 install --user msgpack zstandard` |
| configure 报 family 与缓存不一致 | 已有 build 目录换 family | `baseline.sh clean --yes` |
| ninja 被 OOM kill | 并行度过高 | 降 `--jobs` |
| torch 编译找不到 ROCm | `ROCM_PATH`/`dist` 不对 | 确认 `--stage build` 产物存在，脚本会导出 `ROCM_PATH` |
| `pip install vllm` 解析失败 | wheel 索引没有该版本 | 用 `--wheel-mode source` 或 `--wheelhouse` |
| 镜像里 `import vllm` 失败 | venv 搬入不完整 / shebang 未改 | 看 `--stage verify` 输出；确认 `HOST_VENV_PREFIX` |
| prebuilt 404 | 版本号或 bundle 名不对 | 浏览 `https://stable.repo.amd.com/rocm/core/tarball/` |

部署侧问题（多卡挂起、参数不识别等）见 [VLLM.md](VLLM.md) §5。
