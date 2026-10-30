# vLLM 镜像：构建与部署

镜像的默认入口是 `vllm serve`，所以 `docker run` 起来就是一个 OpenAI 兼容服务。

## 1. 镜像里有什么

| 层 | 内容 | 来源 |
| --- | --- | --- |
| `/opt/rocm` | ROCm 用户态（含 `.kpack` 设备码） | `--stage build`（源码）或官方 tarball（prebuilt） |
| `/opt/venv-torch` | torch / torchvision / triton / vLLM + 运行期依赖 | `--stage wheels` |
| `/opt/vllm-wheels` | 上述 wheel 的归档（离线重装用） | `--stage wheels` |
| `/opt/vllm/benchmarks` | vLLM 自带压测脚本 | 源码仓库 |
| `/entrypoint.sh` | 默认 `vllm serve`；带参数则透传给 `vllm` | `docker/entrypoint.sh` |

`/opt/rocm` 与 venv 都是**宿主侧构建后整体搬入**的；镜像内不编译任何东西。

## 2. 构建

```bash
# x86_64：官方 wheel（分钟级）
./scripts/build.sh --gpu r9700

# x86_64/riscv64：源码编译 torch+triton+torchvision+vLLM（数小时）
./scripts/build.sh --gpu r9700 --wheel-mode source

# 已有 wheel 目录：离线组装
./scripts/build.sh --gpu r9700 --wheelhouse /path/to/wheels

# 已有 venv：直接出镜像（跳过 wheels 阶段）
./scripts/build.sh --stage image --venv /path/to/venv-torch
```

分阶段：

```bash
./scripts/build.sh --stage build     # TheRock → dist/rocm
./scripts/build.sh --stage wheels    # Python 栈 → work/venv-stack
./scripts/build.sh --stage image     # 组装上下文 + docker build
GPU_RUN=1 ./scripts/build.sh --stage verify   # 带 GPU 验收
```

## 3. 部署

### 单卡

```bash
docker run -d --name vllm --network=host --ipc=host \
  --device=/dev/kfd --device=/dev/dri \
  --group-add video --group-add render \
  --security-opt seccomp=unconfined \
  -v /models:/models:ro \
  -e MODEL_PATH=/models/Qwen3.5-9B \
  -e PORT=8000 \
  amd-therock/vllm:x86_64-r9700-10.0.0
```

启动后即可用 OpenAI 协议访问：

```bash
curl http://127.0.0.1:8000/v1/models
curl http://127.0.0.1:8000/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"/models/Qwen3.5-9B","messages":[{"role":"user","content":"hi"}]}'
```

### 多卡（张量并行）

```bash
docker run -d --name vllm-tp2 --network=host --ipc=host \
  --device=/dev/kfd --device=/dev/dri \
  --group-add video --group-add render \
  --security-opt seccomp=unconfined \
  -v /models:/models:ro \
  -e HIP_VISIBLE_DEVICES=0,1 \
  -e EXTRA_ARGS="--tensor-parallel-size 2 --enforce-eager" \
  amd-therock/vllm:<tag>
```

> **`--enforce-eager` 在多卡下基本是必需的**：RDNA4 上 CUDA/HIP graph 与 RCCL 组合容易卡死或结果异常，
> 关掉 graph 捕获最稳（代价是首 token 延迟略高）。

### 常用环境变量

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `MODEL_PATH` | `/models/Qwen3.5-9B` | 无参数启动时 serve 的模型 |
| `PORT` | `8000` | 监听端口（`--host 0.0.0.0`） |
| `GPU_UTIL` | `0.92` | `--gpu-memory-utilization` |
| `MAX_LEN` | `8192` | `--max-model-len` |
| `EXTRA_ARGS` | 空 | 追加参数，如 `--max-num-seqs 64 --enable-prefix-caching` |
| `SKIP_MM_PROFILING` | `1` | 加 `--skip-mm-profiling`，多模态模型可省启动时间 |
| `NCCL_CUMEM_ENABLE` / `NCCL_WIN_ENABLE` | 构建期决定 | 多卡兼容开关（`--mode source` + riscv64 默认开启） |

### 直接透传给 vllm

入口脚本对非 shell 的第一个参数会原样转给 `vllm`：

```bash
docker run --rm -v /models:/models:ro <image> serve /models/Qwen3.5-9B --port 8001
docker run --rm <image> bench throughput --model /models/Qwen3.5-9B --dataset-name random
```

## 4. 调参与压测

参考实测（R9700 32GB，Qwen3.5-9B，in1024/out256）：**`--max-num-seqs` 取 2 的幂**，最优 96、
工程推荐 64（与 96 打平但显存更省），超过 96 反而回落。非 2^n 档位（10/12/14/20）吞吐会塌陷。

```bash
docker run --rm --device=/dev/kfd --device=/dev/dri --group-add video \
  --shm-size 16g -v /models:/models:ro <image> \
  bench throughput --model /models/Qwen3.5-9B --skip-mm-profiling \
    --dataset-name random --random-input-len 1024 --random-output-len 256 \
    --gpu-memory-utilization 0.95 --max-num-batched-tokens 8192 \
    --num-warmups 8 --num-prompts 512 --max-num-seqs 64
```

首次 `torch.compile` 会花 4–5 分钟（按 `max-num-seqs` 缓存），压测时逐档会重编，属正常。

## 5. 排障

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| 容器起来就退出，日志 `No module named vllm` | venv 未正确搬入 | 检查 `--stage wheels` 是否成功、`HOST_VENV_PREFIX` 是否匹配 |
| `vllm: error: unrecognized arguments` | 参数被 entrypoint 当成子命令 | 用 `EXTRA_ARGS` 传参，或显式写 `serve <model> ...` |
| 多卡挂起 / 集合通信超时 | legacy IPC / 对称 VA 问题 | 确认 `NCCL_CUMEM_ENABLE=1`、`NCCL_WIN_ENABLE=0` |
| 多卡结果异常 | graph 捕获不稳定 | 加 `--enforce-eager` |
| 启动时报显存不足 | KV cache 预留过大 | 降 `GPU_UTIL` 或 `MAX_LEN`，或降 `max-num-seqs` |
| `rocminfo` 看不到卡 | 宿主未挂设备/未装驱动 | `--device=/dev/kfd --device=/dev/dri`，宿主装 amdgpu |
