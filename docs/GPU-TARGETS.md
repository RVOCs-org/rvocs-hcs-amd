# GPU 目标

## 1. 一个 GPU 在构建系统里对应三个东西

| 概念 | 变量 | R9700 的取值 | 来源 |
| --- | --- | --- | --- |
| 架构族（family） | `THEROCK_AMDGPU_FAMILIES` | `gfx120X-all` | TheRock `cmake/therock_amdgpu_targets.cmake` |
| LLVM/HIP 架构 | `THEROCK_AMDGPU_TARGETS` / `PYTORCH_ROCM_ARCH` | `gfx1201` | 同上 |
| Python 包 extra | `rocm[device-<gfx>]`、`torch[device-<gfx>]` | `device-gfx1201` | TheRock 发布索引 |

本仓库用 `config/gpu-targets.sh` 把三者绑在一行里，避免手写错。

## 2. 当前表

```bash
./scripts/build.sh --list-gpus
```

| ID | family | gfx | 产品 |
| --- | --- | --- | --- |
| `r9700` | `gfx120X-all` | `gfx1201` | Radeon AI PRO R9700（Navi 48 / RDNA4, 32 GB）**已作为主目标** |
| `rx9070` | `gfx120X-all` | `gfx1201` | Radeon RX 9070 / XT |
| `rx9060` | `gfx120X-all` | `gfx1200` | Radeon RX 9060 / XT |
| `mi300x` | `gfx94X-dcgpu` | `gfx942` | Instinct MI300X |
| `mi355x` | `gfx950-dcgpu` | `gfx950` | Instinct MI355X |
| `w7900` | `gfx110X-all` | `gfx1100` | Radeon PRO W7900 |

> `gfx120X-all` 同时包含 gfx1200 与 gfx1201 的设备码。若只想要 `gfx1201`（省一半设备码编译时间），
> 可用 `THEROCK_EXTRA_ARGS="-DTHEROCK_AMDGPU_TARGETS=gfx1201 -DTHEROCK_AMDGPU_DIST_BUNDLE_NAME=gfx1201"`，
> 但注意一旦这么配置，就不能再用 `--gpu rx9060` 复用同一个构建目录。

## 3. 新增一块卡

```bash
# config/gpu-targets.sh
gpu_define r9600 gfx120X-all gfx1200 "AMD Radeon AI PRO R9600D"
```

然后：

```bash
./scripts/build.sh --gpu r9600 --mode prebuilt     # x86 直接出镜像
./scripts/build.sh --gpu r9600 --components ml     # 源码构建
```

脚本零改动。唯一需要注意的：

- family 名必须存在于上游 `therock_amdgpu_targets.cmake`，否则 configure 会直接报错（这是好事）；
- 若新卡需要不同的组件集（比如数据中心卡要 RCCL），用 `THEROCK_EXTRA_ARGS` 或改
  `config/defaults.sh` 的 preset；
- 若新卡的架构在 TheRock 里尚未标记 Release Ready（见上游 `SUPPORTED_GPUS.md`），
  镜像能构建出来但运行时不保证 —— 先跑 `GPU_RUN=1 --stage verify`。

## 4. 一个镜像跑多种卡

预构建模式：

```bash
THEROCK_BUNDLE=multi-arch ./scripts/build.sh --gpu r9700
```

源码模式：把多个 family 一起编

```bash
THEROCK_EXTRA_ARGS="-DTHEROCK_AMDGPU_FAMILIES=gfx120X-all,gfx94X-dcgpu" \
  ./scripts/build.sh --mode source
```
注意此时 `THEROCK_AMDGPU_DIST_BUNDLE_NAME` 必须显式指定（上游要求单 bundle 才能命名 tarball）。
