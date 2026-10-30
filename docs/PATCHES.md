# 补丁机制

> 补丁能力由 `patches/` 目录决定（单分支）；目录缺失时源码保持上游原样。

## 1. 设计

```
patches/riscv64/
├── components.map                 # 组件 → 路径 → 编号前缀
├── <component>/series             # 有序补丁列表（编译前应用）
└── image/*.py                     # 镜像构建期执行的 python 补丁
```

- **按组件分目录**：TheRock 是超级工程，一个补丁很少只动一个仓库；
  按“补丁要落到哪个 git 仓库”分目录，`git apply` 的 p1 路径才正确。
  路径三态：`.`（TheRock 根）、`<path>`（其子模块）、`src:<name>`（框架侧源码 `work/src/<name>`）。
- **series 决定顺序**：与 quilt 习惯一致，一行一个文件名，支持注释。
- **幂等应用**：`patch_state()` 用 `git apply --check -R` 判定“已应用”，
  所以 `--stage workdir` 可以无限次重跑，不会重复打补丁。
- **不复制源码**：TheRock 工作区就是 `upstream/therock` 子模块本身，
  补丁生效后子模块显示 dirty —— 这是特性，正好可以用 `git diff` 捕获成补丁。
- **两级补丁**：编译期用 `series`（.patch），运行期用 `image/*.py`
  （在 `docker build` 时用镜像内 venv 解释器执行，见 `patches/riscv64/image/README.md`）。

## 2. 一条补丁的生命周期

```
上游新基线 (bump)
   │
   ├─ 应用成功 → 继续
   └─ 应用失败 (fail) → patch.sh check --verbose 定位
                          ├─ 小冲突：手工改几行 → patch.sh capture 覆盖同名补丁
                          └─ 大改动：patch.sh revert <comp> 后重做
```

### 应用失败怎么修

```bash
# 1) 看是哪个 hunk 冲突
./scripts/tools/patch.sh check --verbose

# 2) 尝试三方合并（会留下冲突标记，人工解决）
git -C upstream/therock apply --3way patches/riscv64/therock/1001-xxx.patch || true
vim upstream/therock/...

# 3) 解决后重新生成该补丁（覆盖原文件，编号不变）
./scripts/tools/patch.sh capture therock <原名去掉编号>

# 4) 验证
./scripts/tools/patch.sh check
```

`capture` 生成的是 `git diff HEAD`（相对该组件当前 commit），文件名由
`components.map` 的编号前缀 + series 长度决定；要**原地覆盖**同一编号，
先手工删掉旧文件并把它从 series 里移除，或直接用 `refresh`（见 §4）。

## 3. 新增补丁的三种方式

| 场景 | 命令 |
| --- | --- |
| 直接改源码，改动已跑通 | `patch.sh capture <comp> <name>` |
| 手上已有 patch 文件 | `patch.sh import <comp> <file> <name>` |
| 从 URL 拉（GitHub PR / 内部 GitLab） | `patch.sh import <comp> <url> <name>` |

三者的共同保证：写入前做 `git apply --check`，不干净的补丁不会被加进 series。

## 4. 工具速查

```bash
./scripts/tools/patch.sh list                  # 全部补丁 + applied/pending/fail
./scripts/tools/patch.sh status <comp>         # 单组件详情（含组件 HEAD）
./scripts/tools/patch.sh check [--verbose]     # CI 口径校验，失败返回非 0
./scripts/tools/patch.sh capture <comp> <name> # 固化工作区改动
./scripts/tools/patch.sh import <comp> <src> <name>
./scripts/tools/patch.sh revert <comp>         # 逆序撤销该组件全部补丁
```

编译期批量应用发生在 `--stage workdir`，也可以在 CI 里只跑 `check`。

## 5. 命名规范

- 文件名：`<前缀><3 位序号>-<kebab-case-描述>.patch`
- 前缀：`therock=1`、`rocm-libraries=2`、`rocm-systems=3`、
  `composable-kernel=4`、`pytorch=5`、`triton=6`、`vllm=7`（见 `components.map`）
- 描述写“行为”，例如 `kpack-riscv-elf`、`rocm-smi-riscv-cpuinfo`，
  不要写 `fix-bug`、`patch1`。
- 每个补丁头部保留 `Subject:` / 说明段，写清上游 PR 编号（若已提）。

## 6. 与上游合入的关系

某个补丁被上游合入后：

1. `baseline.sh bump` 到包含该修复的 tag；
2. 从 `series` 删除该行、`git rm` 补丁文件；
3. `patch.sh check` 确认剩余补丁仍可用；
4. 当 `patches/riscv64/` 全部清空时，可把 `RISCV-Porting` 的剩余内容（如果只有文档）
   合并回 master，收敛分支。

## 7. 当前清单（已全部导入，不依赖内网 GitLab）

补丁由参考实现（10.10.128.103）的内网仓库 commit 用 `git format-patch` 导出，
**剔除了子模块 gitlink 与 `.gitmodules` 改动**（那两类只在内网有意义，无法在公开上游复现）。

| 组件 | 基线（补丁作用于其上） | 补丁数 | 编号 |
| --- | --- | --- | --- |
| `therock` | upstream `therock-10.0` = `16adc4d8` | 7 | 1001–1007 |
| `rocm-libraries` | `8d1ae90e`（therock-10.0 的 gitlink） | 1 | 2001 |
| `rocm-systems` | `6b0e43f3`（therock-10.0 的 gitlink） | 6 | 3001–3006 |
| `composable-kernel` | — | 0 | — |
| `pytorch` | `cf30153c4c`（release/2.13） | 3 | 5001–5003 |
| `triton` | `5f3f125e8f`（v3.7.0） | 2 | 6001–6002 |
| `vllm` | `98dff2a81d`（main, 2026-09-08） | 1 | 7001 |
| `amd-llvm` | `9f8c0bcf`（补丁作者的父提交） | 1 | 8001 |
| （镜像期） | — | 3 | `image/*.py` |

合计 **21 个 .patch + 3 个镜像期 .py**，约 8.6 MB。

各补丁的内容：

| 编号 | 主题 |
| --- | --- |
| 1001 | sysdeps meson 去掉 `--version-script`（expat/gmp/hwloc/mpfr/ncurses/libdrm 等） |
| 1002 | 构建文档（riscv64 campaign 记录） |
| 1003 | hwloc `config.guess/sub` 刷新 |
| 1004 | gfx1201 构建修复（compiler/BLAS/profiler CMake、amd-llvm bump） |
| 1005 | 新增 `cmake/therock_amdsmi_deferred.cmake`（amdsmi 延迟构建） |
| 1006 | 启用 NVPTX LLVM target |
| 1007 | （pins 提交中非 gitlink 的部分） |
| 2001 | hipSOLVER 的 LAPACK `RISCV64_GENERIC` 目标 |
| 3001 | 文档（claude 提交） |
| 3002 | v100 平台适配（7.1.1 补丁集移植） |
| 3003 | rocvirtual/hsa-runtime 残留冲突标记修复 |
| 3004 | rocr blit SDMA 与 clr `Os::spinPause` 的可移植 pause |
| 3005 | kpack 支持 RISCV64 ELF machine type 与重定位 |
| 3006 | RCCL `init.cc` cpuid 守卫 + `xml.cc` `__riscv` topo 分支 |
| 5001 | torch 的 riscv64/gfx1201 适配（csrc/aten/inductor 等，20 万行新增） |
| 5002 | `cmake/Dependencies.cmake` 参数化 libroctx64 |
| 5003 | ATen/c10/caffe2 的 HIP 后端源码补齐 |
| 6001 | triton 依赖 LLVM 的 riscv module |
| 6002 | triton 移植到 LLVM/MLIR 23（对齐 TheRock 10.0 的 amd-llvm） |
| 7001 | vLLM：HIP 目标改用 GNU ld(bfd)，规避 lld COMDAT 回归 |
| 8001 | OMPT 设备追踪 hook 的弱符号 no-op 兜底 |

### 已知未纳入的部分

| 项 | 为什么不纳入 | 影响 |
| --- | --- | --- |
| pytorch 的 4 个子模块 gitlink（`kineto`/`mslk`/`fbgemm`/`gloo` 指向内网 HIP 修补版） | 内网私有提交，无法在公开上游复现 | 若这些子模块在 riscv64 上编译失败，需要单独打补丁 |
| `.gitmodules` 的 URL 重写（内网 GitLab） | 内网专属 | 无（本仓库全部用公开上游） |
| `amd-llvm` 的基线差异 | 参考构建用的 amd-llvm 比 therock-10.0 的 pin 略新（`9f8c0bcf` vs `8f497e09`），补丁按 `9f8c0bcf` 导出 | 应用时若上下文不符，改用 `--3way` 或把 amd-llvm 升到 `9f8c0bcf` |

## 8. 镜像期补丁（image/*.py）

`patch.sh` 不管这一层：它们在 `docker build` 中由 `docker/vllm.Dockerfile` 执行，
目录整体 COPY 到 `/opt/patches`，跑完即删。命名 `NNNN-描述.py`，必须幂等并自带断言。
详见 [../patches/riscv64/image/README.md](../patches/riscv64/image/README.md)。
