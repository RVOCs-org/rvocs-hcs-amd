#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# ci/quick-bench.sh - one-shot performance regression probe for the GPU stage
#
# Starts (or reuses) the vLLM container, waits for /v1/models, runs one
# `vllm bench serve` round and compares the result to a recorded baseline.
#
# Usage: ci/quick-bench.sh [concurrency]        (default 4)
# Env:
#   BENCH_IMAGE   image to run         (default swr.../:v0.2.20)
#   BENCH_MODEL   model dir (host)     (default /home/ubuntu/models/Qwen3.8-27B-AWQ-INT4)
#   BENCH_NAME    container name       (default rvocs-bench)
#   BASELINE_TPOT recorded TPOT ms     (default 62.05, from 2026-11-24 run @c=4)
#   MAX_TPOT_REGRESSION_PCT            (default 15)
#   BENCH_RESULTS host results dir     (default /home/ubuntu/bench-results)
#
# Notes learned the hard way (keep them):
#   - the image ENTRYPOINT is already `vllm`, so the argument is `serve ...`,
#     NOT `vllm serve ...`
#   - Qwen3.8 is multimodal; without --limit-mm-per-prompt {"image":0,"video":0}
#     the ViT profiling dummy forward tries to allocate 256 GiB and OOMs
#   - the first start costs ~13 min (weights 41s + torch.compile 520s + graphs)
# ---------------------------------------------------------------------------
set -euo pipefail

C="${1:-4}"
IMG="${BENCH_IMAGE:-swr.cn-east-3.myhuaweicloud.com/cloud-mdgx/rvocs-vllm-therock10.0-r9700-riscv64:v0.2.20}"
MDIR="${BENCH_MODEL:-/home/ubuntu/models/Qwen3.8-27B-AWQ-INT4}"
NAME="${BENCH_NAME:-rvocs-bench}"
BASE_TPOT="${BASELINE_TPOT:-62.05}"
MAXREG="${MAX_TPOT_REGRESSION_PCT:-15}"
RES="${BENCH_RESULTS:-/home/ubuntu/bench-results}"
SUDO() { if sudo -n true 2>/dev/null; then sudo -n "$@"; else echo "password" | sudo -S "$@"; fi; }

mkdir -p "$RES"
echo "[quick-bench] concurrency=$C image=$IMG model=$MDIR"

# ---------------------------------------------------------------- container --
if ! SUDO docker inspect "$NAME" >/dev/null 2>&1; then
  echo "[quick-bench] creating $NAME"
  SUDO docker run -d --name "$NAME" \
    --device /dev/kfd --device /dev/dri --group-add video \
    --security-opt seccomp=unconfined --shm-size 16g \
    -v "$(dirname "$MDIR")":/models:ro -v "$RES":/results \
    -p 8000:8000 "$IMG" \
    serve "/models/$(basename "$MDIR")" --served-model-name qwen38awq \
    --trust-remote-code --limit-mm-per-prompt '{"image":0,"video":0}' \
    --max-model-len 2048 --gpu-memory-utilization 0.88 --max-num-seqs 32 \
    --host 0.0.0.0 --port 8000 >/dev/null
elif [ "$(SUDO docker inspect -f '{{.State.Status}}' "$NAME")" != "running" ]; then
  echo "[quick-bench] starting existing $NAME"; SUDO docker start "$NAME" >/dev/null
fi

echo "[quick-bench] waiting for /v1/models (up to 20 min)"
for i in $(seq 1 120); do
  if curl -sf -m 3 http://127.0.0.1:8000/v1/models >/dev/null 2>&1; then
    echo "[quick-bench] ready after $((i*10))s"; break
  fi
  if [ "$(SUDO docker inspect -f '{{.State.Status}}' "$NAME")" != "running" ]; then
    echo "[quick-bench] container died; last logs:"; SUDO docker logs --tail 20 "$NAME" 2>&1; exit 1
  fi
  sleep 10
  [ "$i" -eq 120 ] && { echo "[quick-bench] timeout waiting for server"; exit 1; }
done

# -------------------------------------------------------------------- bench --
F="bench-c${C}-$(date +%Y%m%d-%H%M%S).json"
echo "[quick-bench] running vllm bench serve -> $RES/$F"
SUDO docker exec "$NAME" vllm bench serve \
  --backend openai --base-url http://127.0.0.1:8000 \
  --model "/models/$(basename "$MDIR")" --tokenizer "/models/$(basename "$MDIR")" \
  --served-model-name qwen38awq --trust-remote-code \
  --dataset-name random --input-len 1024 --output-len 128 \
  --num-prompts 128 --num-warmups 16 --ignore-eos \
  --max-concurrency "$C" --request-rate inf \
  --percentile-metrics ttft,tpot,itl,e2el --metric-percentiles 50,90,99 \
  --disable-tqdm --save-result --result-dir /results --result-filename "$F" \
  2>&1 | tail -20

# ------------------------------------------------------------------- report --
python3 - "$RES/$F" "$BASE_TPOT" "$MAXREG" "$C" <<'PY'
import json,sys,os
p,base,maxreg,c = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), sys.argv[4]
d=json.load(open(p))
tpot=d.get("mean_tpot_ms",0.0); tp=d.get("output_throughput",0.0)
ttft=d.get("mean_ttft_ms",0.0); p99=d.get("p99_ttft_ms",0.0)
reg=(tpot-base)/base*100 if base else 0
verdict="REGRESSION" if reg>maxreg else "OK"
print(f"c={c} out_tput={tp:.2f} tok/s  TTFT={ttft:.0f}ms (p99 {p99:.0f})  TPOT={tpot:.2f}ms")
print(f"vs baseline TPOT {base:.2f}ms -> {reg:+.1f}% (threshold +{maxreg:.0f}%) => {verdict}")
out={"concurrency":int(c),"output_throughput":tp,"mean_ttft_ms":ttft,"p99_ttft_ms":p99,
     "mean_tpot_ms":tpot,"baseline_tpot_ms":base,"regression_pct":reg,"verdict":verdict,"raw":os.path.basename(p)}
json.dump(out, open(os.path.join(os.path.dirname(p),"ci-bench-summary.json"),"w"), indent=2)
s=os.environ.get("GITHUB_STEP_SUMMARY")
if s:
    open(s,"a").write(f"### GPU bench c={c}\n| metric | value |\n|---|---|\n"
        f"| output throughput | {tp:.2f} tok/s |\n| TTFT mean / p99 | {ttft:.0f} / {p99:.0f} ms |\n"
        f"| TPOT mean | {tpot:.2f} ms |\n| vs baseline {base:.2f} ms | {reg:+.1f}% |\n| verdict | **{verdict}** |\n")
sys.exit(1 if verdict=="REGRESSION" else 0)
PY
