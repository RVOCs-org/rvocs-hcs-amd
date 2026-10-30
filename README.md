# rvocs-hcs-amd

把 ROCm（AMD [TheRock](https://github.com/ROCm/TheRock) 超级工程）+ PyTorch + vLLM
**一条命令**构建成可直接部署模型的 Docker 镜像；同时支持 **RISC-V (riscv64) 原生构建**。

本仓库是 RVOCs 的 **AMD 厂商仓库**（`rvocs-hcs-{vendor}`），**单分支**（`master`）：
x86_64 走官方预构建路径（分钟级），riscv64 走 `patches/riscv64/` 移植层的源码构建。
本仓库是**编排层**：不重写 TheRock 的构建逻辑，只负责
「按目标 GPU 选组件 → 取源码 → 打补丁 → 编 ROCm → 编/装 Python 栈 → 打包镜像 → 验收」，
并把上游基线、补丁和构建参数全部版本化。

宿主机侧说明：amdgpu 驱动在内核中、ROCm 用户态在镜像内，因此本仓库暂无 `host/` 部分；
riscv64 需要 ≥ `7.0.0-31-generic` 的内核（旧内核的 amdgpu 有缺陷）。

## 产物

| 镜像 | 内容 | 用途 |
| --- | --- | --- |
| `rvocs-vllm-therock<rocm>-<gpu>-<arch>:<version>` | ROCm + torch/torchvision/triton/vLLM + `vllm serve` 入口 | **默认产物**，`docker run` 即 OpenAI 兼容服务 |
| `rvocs-runtime-therock<rocm>-<gpu>-<arch>:<version>` | 只有 ROCm 用户态 | 自带应用、不需要 Python 栈的场景 |

示例：`rvocs-vllm-therock10.0-r9700-riscv64:v0.1.0`。
`<arch>` 为 OCI 名（amd64 / arm64 / riscv64），`<version>` 来自仓库根的 `VERSION`。
两种镜像都**只含用户态**：内核驱动与 `/dev/kfd`、`/dev/dri` 由宿主机提供。

## 设计目标

1. **一条命令出可部署镜像**：`./scripts/build.sh` → vLLM 镜像，无需理解 TheRock 的 CMake 细节。
2. **双架构、单分支**：`master` 同时承载 x86_64（官方 wheel，分钟级）与 riscv64 源码构建（`patches/riscv64/` 移植层）。
3. **阶段可拆分**：拉源码 / 打补丁 / 编 ROCm / 编 Python 栈 / 出镜像 / 验收，各自独立可重入。
4. **目标 GPU 参数化**：`--gpu r9700`，新增型号只改一个配置文件。
5. **上游基线可管理**：`baseline.sh` 提供 status/apply/check/sync/bump/tag/rollback。

## 版本矩阵（当前 pin）

| 组件 | 仓库 | 版本 |
| --- | --- | --- |
| TheRock（ROCm 构建系统） | ROCm/TheRock | `therock-10.0`（`16adc4d8`） |
| ROCm | — | 10.0.0 |
| PyTorch / torchvision | pytorch/pytorch | 2.11 / 0.26（TheRock 官方 wheel；源码构建见 `config/sources.sh`） |
| vLLM | vllm-project/vllm | 配套 ROCm 10.0 的版本 |
| 目标 GPU（默认） | — | AMD Radeon AI PRO R9700（`gfx1201` / family `gfx120X-all`） |

TheRock 的 pin 由 `upstream/therock` 子模块 gitlink 承载；框架侧源码 pin 在 `config/sources.sh`。
两者都可被 `scripts/tools/baseline.sh` 检查。

## 快速开始

### A. x86_64：最快路径（官方 ROCm tarball + 官方 wheel）

```bash
git clone <this-repo> && cd rvocs-hcs-amd
./scripts/build.sh --gpu r9700
```

镜像：`rvocs-vllm-therock10.0-r9700-amd64:v0.1.0`。

### B. riscv64：源码全栈

```bash
./scripts/build.sh --gpu r9700          # 自动 --mode source --wheel-mode source
```

阶段：`preflight → fetch → workdir → build → wheels → image → verify`。
耗时参考（80 核 riscv64）：TheRock 约 17h、四个 wheel 约 5h、镜像 50min。构建目录与 venv 都可断点续跑。

### C. 已经有 wheel / venv

```bash
./scripts/build.sh --wheelhouse /path/to/wheels     # 离线 wheel 组装
./scripts/build.sh --stage image --venv /path/to/venv-torch
```

### 部署

```bash
docker run -d --name vllm --network=host --ipc=host \
  --device=/dev/kfd --device=/dev/dri --group-add video --group-add render \
  --security-opt seccomp=unconfined \
  -v /models:/models:ro -e MODEL_PATH=/models/Qwen3.5-9B \
  rvocs-vllm-therock10.0-r9700-<arch>:<version>
```

也可用编排层统一部署：`../rvocs-main/rvocs.sh --target therock --arch riscv --deploy --yes`。

详见 [docs/VLLM.md](docs/VLLM.md)（单卡/多卡、调参、压测、排障）。

## 阶段与常用命令

| 阶段 | 作用 |
| --- | --- |
| `preflight` | 环境自检（磁盘/内存/工具链/docker/patchelf/补丁完整性） |
| `fetch` | 拉 TheRock 源码与组件（source）或下载官方 tarball（prebuilt）；按需拉框架侧源码 |
| `workdir` | 应用 `patches/<arch>/` 补丁系列（幂等） |
| `build` | TheRock：cmake + ninja → `build/dist/rocm` |
| `wheels` | Python 栈：pip 安装或源码编译 → `work/venv-stack` + `work/wheelhouse` |
| `image` | 组装上下文 + `docker build` |
| `verify` | 容器内冒烟（ROCm/kpack/导入/vllm 命令/可选 GPU） |

```bash
./scripts/build.sh --stage fetch      # 只拉源码
./scripts/build.sh --stage prep       # 拉源码 + 打补丁
./scripts/build.sh --stage build      # 只编 ROCm（可反复重入）
./scripts/build.sh --stage wheels     # 只做 Python 栈
./scripts/build.sh --stage image      # 只重建镜像
GPU_RUN=1 ./scripts/build.sh --stage verify
./scripts/build.sh --list-gpus        # 可选目标 GPU
./scripts/build.sh --dry-run          # 只打印计划
```

## 目标 GPU

```bash
./scripts/build.sh --gpu r9700        # 默认
./scripts/build.sh --gpu mi300x
./scripts/build.sh --gpu gfx1201 --family gfx120X-all
```

GPU 表在 `config/gpu-targets.sh`（一行 `gpu_define` 即可扩展），详见 [docs/GPU-TARGETS.md](docs/GPU-TARGETS.md)。

## 上游基线管理

`manifest.yaml` 是唯一输入：改 `<module>.ref`（tag 或 commit sha），然后：

```bash
./scripts/tools/baseline.sh status
./scripts/tools/baseline.sh apply                  # 移 gitlink + 回写全 sha
./scripts/tools/baseline.sh check                  # CI 门禁
./scripts/tools/baseline.sh sync                   # 上游有哪些新 tag
./scripts/tools/baseline.sh bump therock-10.1 --commit
./scripts/tools/baseline.sh tag 2026-10-21
./scripts/tools/baseline.sh rollback baseline/2026-10-21
```

详见 [docs/BASELINE.md](docs/BASELINE.md)。

## 目录结构

```
rvocs-hcs-amd/
├── VERSION                    # 仓库版本（产物命名用）
├── manifest.yaml              # 基线与版本清单（唯一 pin 输入）
├── config/
│   ├── defaults.sh            # 版本、基础镜像、组件集 preset、镜像种类
│   ├── gpu-targets.sh         # GPU 目标表（唯一事实源）
│   └── sources.sh             # 框架侧源码 pin（torch/torchvision/triton/vllm）
├── scripts/
│   ├── build.sh               # 一键入口（阶段编排）
│   ├── 00-preflight.sh … 06-verify.sh
│   ├── wheels/{torch,triton,torchvision,vllm}.sh
│   ├── lib/{common,gpu,patch}.sh
│   └── tools/{baseline,patch}.sh
├── docker/
│   ├── vllm.Dockerfile        # 默认产物
│   ├── runtime.Dockerfile     # 纯 ROCm
│   └── entrypoint.sh
├── docs/{BUILD,BASELINE,GPU-TARGETS,VLLM,PATCHES,RISCV}.md
├── patches/<arch>/            # 按架构的移植层（单分支）
└── upstream/therock/          # 子模块（上游源码）
```

## 已知限制

- 源码构建约需 **200 GB** 磁盘；TheRock 源码约 30 GB，venv + wheel 约 10 GB。
- kpack 拆包依赖打过补丁的 patchelf，`preflight` 会提示安装方式。
- riscv64 的移植补丁已全部内置（21 个 `.patch` + 3 个镜像期 `.py`），源码全部来自公开上游，
  **不依赖内网 GitLab**；未纳入的只有 pytorch 的 4 个私有子模块 gitlink（见 docs/PATCHES.md §7）。
- 镜像仅支持 apt 系基础镜像（Ubuntu/Debian）。
- 已有构建目录不支持切换 family 重新 configure（TheRock 限制），需 `baseline.sh clean`。
- riscv64 内核需 ≥ `7.0.0-31-generic`（旧内核 amdgpu 驱动有缺陷）。
