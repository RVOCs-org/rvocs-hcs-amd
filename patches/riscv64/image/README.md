# 镜像构建期 python 补丁（hook 目录）

放在这里的 `*.py` 会在 `docker build` 阶段、ROCm 与 venv 就位之后执行，
解释器是镜像里的 `${STACK_VENV}/bin/python`，执行顺序按文件名排序。

适用场景：**运行时行为的猴补丁**，即“必须改已安装的 site-packages，但不想重新编 wheel”的修复。

## 约定

- 文件名：`NNNN-<短横线描述>.py`（例：`0101-vllm-rocm-platform-fallback.py`）
- 必须**幂等**：重复执行不报错、不重复插入
- 必须自带断言：改完立刻验证目标符号存在，失败就非 0 退出（让 docker build 失败）
- 目录整体被 `COPY` 到 `/opt/patches`，执行后删除；不打进运行镜像

## 与其它补丁机制的区别

| 机制 | 位置 | 生效时机 | 适用 |
| --- | --- | --- | --- |
| `patches/<arch>/<component>/series` | `.patch` | `--stage workdir`（编译前） | 改源码、编译期问题 |
| `patches/<arch>/image/*.py` | `.py` | `docker build`（镜像层） | 改已安装包、运行时行为 |

## 已验证构建中出现过的三类镜像期补丁

来自参考实现（`stack/docker/riscv-gfx1201/patches/`），**尚未导入本仓库**：

| 补丁 | 解决的问题 |
| --- | --- |
| `torch_devcount_patch.py` | torch 对可见设备数的判定（多卡/单卡） |
| `vllm_rocm_fallback.py` | vLLM 的 ROCm 平台探测回退（amdsmi 在 PCI domain ≠ 0000 时失明） |
| `amdsmi_warmup_patch.py` | 通过 `.pth` 预热 amdsmi 句柄，避免 import 顺序导致的设备枚举失败 |

导入方式：把文件放到本目录（带编号前缀），重新 `--stage image` 即可，无需改脚本。
