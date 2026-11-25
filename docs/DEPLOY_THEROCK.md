# therock 推理镜像部署

本文覆盖拉取镜像、启动容器、serve 与 bench；构建与基线见 [BUILD.md](BUILD.md) 与 [RISCV.md](RISCV.md)。

## 1. 拉取镜像

```bash
docker pull swr.cn-east-3.myhuaweicloud.com/cloud-mdgx/rvocs-vllm-therock10.0-r9700-riscv64:v0.2.2
docker tag swr.cn-east-3.myhuaweicloud.com/cloud-mdgx/rvocs-vllm-therock10.0-r9700-riscv64:v0.2.2 \
  rvocs-vllm-therock10.0-r9700-riscv64:v0.2.2
```

离线环境用 `docker load -i <image.tar>` 导入。

## 2. 启动容器

确认设备节点：

```bash
ls -l /dev/kfd /dev/dri/renderD*
```

服务模式：

```bash
docker run -d --name vllm \
  --device=/dev/kfd --device=/dev/dri \
  --group-add video --group-add render \
  --security-opt seccomp=unconfined \
  --network=host --ipc=host --shm-size 16g \
  -v /models:/models:ro \
  -e MODEL_PATH=/models/<model> \
  -e PORT=8000 \
  rvocs-vllm-therock10.0-r9700-riscv64:v0.2.2
```

entrypoint 已执行 `vllm serve`；命令行只需传入 `serve`/`bench` 子命令或留空。
追加 serve 参数时在 `docker run` 中加入 `-e EXTRA_ARGS="--tensor-parallel-size 2"`。

调试或重复压测可使用常驻容器：

```bash
docker run -d --name vllm-bench \
  --device=/dev/kfd --device=/dev/dri \
  --group-add video --group-add render \
  --security-opt seccomp=unconfined \
  --network=host --ipc=host --shm-size 16g \
  -v /models:/models \
  --entrypoint /bin/sleep \
  rvocs-vllm-therock10.0-r9700-riscv64:v0.2.2 infinity
```

## 3. serve

服务模式无参数启动时读取 `MODEL_PATH`。手动启动：

```bash
docker exec -it vllm bash
. /opt/stack/rccl_fix.env
vllm serve /models/<model> --tensor-parallel-size 2 --max-num-seqs 16 --port 8000
```

`/opt/stack/rccl_fix.env` 是 TP≥2 的前提，包含 `VLLM_DISABLE_PYNCCL=1` 与
`VLLM_NCCL_SO_PATH`；服务模式由 entrypoint 自动加载，手动 `docker exec` 时必须自己 source。
单卡（TP=1）可省略。

常用参数：

| 参数 | 说明 |
| --- | --- |
| `--tensor-parallel-size` | 张量并行度；>1 时需先加载 `rccl_fix.env` |
| `--enable-expert-parallel` | MoE 模型的专家并行 |
| `--gpu-memory-utilization` | 显存占用比例，默认 0.92 |
| `--max-num-seqs` | 并发序列数 |
| `--skip-mm-profiling` | 跳过多模态 dummy profiling；entrypoint 默认开启 |
| `--limit-mm-per-prompt` | VL 模型各模态的输入上限，如 `'{"image":0,"video":0}'` |
| `--port` / `--host` | 服务端口与监听地址 |

首次启动需完成权重加载、`torch.compile` 与图捕获，期间端口不会监听。

服务就绪后：

```bash
curl -s http://127.0.0.1:8000/v1/models
```

## 4. 关键环境变量

| 变量 | 说明 |
| --- | --- |
| `rccl_fix.env` | TP≥2 必需；提供 `VLLM_DISABLE_PYNCCL=1`、`VLLM_NCCL_SO_PATH` |
| `NCCL_PROTO` | 可选，限制 RCCL 协议（如 `^LL`）；会改变多卡性能特征 |
| `NCCL_CUMEM_ENABLE` / `NCCL_WIN_ENABLE` | 多卡兼容开关，源码构建默认开启/关闭 |
| `HIP_VISIBLE_DEVICES` | 指定参与运行的 GPU，如 `0,1` |
| `MODEL_PATH` / `PORT` | 服务模式的默认模型与端口 |
| `GPU_UTIL` | 覆盖 `--gpu-memory-utilization` |
| `SKIP_MM_PROFILING` | 默认 `1`；置 `0` 可恢复多模态 profiling |
| `EXTRA_ARGS` | 追加到 serve 命令的参数 |

## 5. bench

服务启动后，在容器内对指定端口发起在线压测：

```bash
vllm bench serve \
  --model /models/<model> \
  --dataset-name random --input-len 1024 --output-len 128 \
  --num-prompts 32 --max-concurrency 8 --num-warmups 4 \
  --temperature 0 --port 8000
```

调整 `--max-concurrency` 得到不同并发下的吞吐与延迟；`--num-prompts` 需足够大，使统计进入稳态。

离线吞吐：

```bash
vllm bench throughput \
  --model /models/<model> --skip-mm-profiling \
  --dataset-name random --random-input-len 1024 --random-output-len 256 \
  --gpu-memory-utilization 0.95 --max-num-batched-tokens 8192 \
  --num-warmups 8 --num-prompts 512 --max-num-seqs 64
```

## 6. 排障

| 现象 | 处理 |
| --- | --- |
| 容器内无 GPU | 检查 `--device=/dev/kfd --device=/dev/dri` 与 `video`/`render` 组 |
| TP≥2 启动失败或集合通信超时 | 加载 `rccl_fix.env`，确认 `torch.distributed.is_nccl_available()` |
| 图捕获报错 / 多卡挂起 | 确认 `rccl_fix.env` 已加载，且 RCCL 与 ROCm 来自同一次构建 |
| VL 模型启动 OOM | 保持 `--skip-mm-profiling`；必要时用 `--limit-mm-per-prompt` 限制模态输入 |
| 参数不识别 | 首参数应为 `serve`/`bench`，不是 `vllm`；其余参数通过 `EXTRA_ARGS` 或 `serve` 传入 |

## 7. 相关文档

- [BUILD.md](BUILD.md)、[RISCV.md](RISCV.md)、[PATCHES.md](PATCHES.md)
- `rvocs-main/docs/CLI.md`（`--download` / `--list-releases`）
