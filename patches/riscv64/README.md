# patches/riscv64 —— RISC-V 移植补丁层

本目录是 riscv64 移植层（单分支，随 master 维护）。目录缺失时 riscv64 相关步骤会显式报错。

## 结构

```
patches/riscv64/
├── components.map          # 组件 → 工作区路径 → 编号前缀
├── <component>/
│   ├── series              # 有序列表（一行一个 patch 文件名）
│   └── NNNN-name.patch
└── README.md
```

`components.map` 当前声明：

| 组件 | 路径 | 编号前缀 |
| --- | --- | --- |
| `therock` | `.`（upstream/therock 根） | 1xxx |
| `rocm-libraries` | `rocm-libraries` | 2xxx |
| `rocm-systems` | `rocm-systems` | 3xxx |
| `composable-kernel` | `rocm-libraries/projects/composable_kernel` | 4xxx |
| `pytorch` | `src:pytorch`（work/src/pytorch） | 5xxx |
| `triton` | `src:triton` | 6xxx |
| `vllm` | `src:vllm` | 7xxx |
| `amd-llvm` | `compiler/amd-llvm` | 8xxx |
| （镜像期） | `image/*.py` | — |

## 规则

1. **只提交 `.patch` 与 `series`**，不提交整棵源码树。
2. 补丁必须能被 `git apply` 消费（`git diff` / `git format-patch` 产物即可），路径层级为 `-p1`。
3. 编号连续、名字用短横线英文小写，描述“做什么”而不是“改哪行”。
4. `series` 的顺序就是应用顺序；新增补丁默认追加到末尾，除非有前置依赖需要插队（在 series 里手工调整）。
5. 应用是**幂等**的：已应用的补丁（`git apply --check -R` 通过）会被跳过，可以反复执行 `--stage workdir`。

## 三种导入方式

```bash
# A. 改完源码后固化（推荐，冲突最少）
./scripts/build.sh --stage fetch
./scripts/build.sh --stage workdir          # 保证现有补丁已应用
vim upstream/therock/<file>
./scripts/tools/patch.sh capture therock kpack-riscv-elf

# B. 导入现成 patch 文件 / URL
./scripts/tools/patch.sh import rocm-systems ./0001-riscv-timer.patch riscv-timer
./scripts/tools/patch.sh import rocm-libraries https://example.com/x.patch hipsolver-riscv

# C. 手工放入 + 追加 series 行，然后校验
./scripts/tools/patch.sh check --verbose
```

## 状态查看

```bash
./scripts/tools/patch.sh list                 # 所有补丁 + applied/pending/fail
./scripts/tools/patch.sh status rocm-systems  # 单组件详情
./scripts/tools/patch.sh check --verbose      # CI 口径：能否干净应用
```

## 当前状态

框架已就绪，**尚未导入具体补丁**。各组件 `series` 均为空（仅注释）。
导入清单确定后，按上面的方式逐条加入即可，脚本无需改动。
