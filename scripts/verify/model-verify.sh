#!/usr/bin/env bash
# Model-level functional + performance check for the vllm image.
# Runs on the host, mounts a local AWQ model, serves it with vLLM on a spare port.
#   usage: model-verify.sh <image-tag> [model-dir]
# env: MODEL_DIR PORT MAXLEN GPU_UTIL TP START_TIMEOUT OUT_DIR
set -uo pipefail
IMAGE="${1:?image tag}"
MODEL_DIR="${MODEL_DIR:-${2:-/home/ubuntu/models/Qwen3.8-27B-AWQ-INT4}}"
PORT="${PORT:-18080}"; MAXLEN="${MAXLEN:-8192}"; GPU_UTIL="${GPU_UTIL:-0.85}"
TP="${TP:-1}"; START_TIMEOUT="${START_TIMEOUT:-1200}"
OUT_DIR="${OUT_DIR:-/home/ubuntu/RVOCs-CICD/rvocs-hcs-amd/artifacts/model-verify}"
NAME=rvocs-model-verify
mkdir -p "$OUT_DIR"; TS=$(date +%Y%m%d-%H%M%S)
OUT="$OUT_DIR/model-verify-$TS.json"; LOG="$OUT_DIR/model-verify-$TS.log"
fail=0
say(){ printf '%s\n' "$*" | tee -a "$LOG"; }

[ -d "$MODEL_DIR" ] || { echo "[FAIL] model dir missing: $MODEL_DIR" >&2; exit 1; }
MN=$(basename "$MODEL_DIR")
GID_ARGS=(); for d in /dev/kfd /dev/dri/renderD128; do [ -e "$d" ] && GID_ARGS+=(--group-add "$(stat -c '%g' "$d")"); done
cleanup(){ docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

say "== start vLLM ($IMAGE) model=$MN port=$PORT maxlen=$MAXLEN util=$GPU_UTIL tp=$TP"
cleanup
docker run -d --name "$NAME" \
  --device=/dev/kfd --device=/dev/dri --ipc=host --security-opt seccomp=unconfined \
  "${GID_ARGS[@]}" -v "$MODEL_DIR":/models/"$MN" -p 127.0.0.1:"$PORT":8000 \
  --entrypoint /opt/venv-torch/bin/vllm "$IMAGE" \
  serve /models/"$MN" --served-model-name m --port 8000 \
  --max-model-len "$MAXLEN" --gpu-memory-utilization "$GPU_UTIL" \
  --tensor-parallel-size "$TP" --trust-remote-code >>"$LOG" 2>&1 \
  || { say "[FAIL] docker run"; exit 1; }

t0=$(date +%s)
for i in $(seq 1 $((START_TIMEOUT/5))); do
  if curl -fsS -m 3 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then break; fi
  if [ "$(docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null)" != "true" ]; then
    say "[FAIL] server exited during startup"; docker logs "$NAME" 2>&1 | tail -25 | tee -a "$LOG"; exit 1
  fi
  sleep 5
done
startup=$(( $(date +%s) - t0 ))
curl -fsS -m 5 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 \
  || { say "[FAIL] server not ready after ${startup}s"; docker logs "$NAME" 2>&1 | tail -25 | tee -a "$LOG"; exit 1; }
say "[ OK ] server ready in ${startup}s"

python3 - "$PORT" "$OUT" "$startup" <<'PY' | tee -a "$LOG"
import json,sys,time,urllib.request,concurrent.futures as cf
port,out,startup=int(sys.argv[1]),sys.argv[2],int(sys.argv[3])
url=f"http://127.0.0.1:{port}/v1/chat/completions"
def ask(prompt,max_tokens=128,temp=0.0):
    body=json.dumps({"model":"m","messages":[{"role":"user","content":prompt}],
        "max_tokens":max_tokens,"temperature":temp}).encode()
    t=time.time(); req=urllib.request.Request(url,body,{"Content-Type":"application/json"})
    with urllib.request.urlopen(req,timeout=300) as r: d=json.loads(r.read())
    dt=time.time()-t
    txt=d["choices"][0]["message"]["content"]; u=d.get("usage",{})
    return {"latency_s":round(dt,3),"completion_tokens":u.get("completion_tokens",0),
            "total_tokens":u.get("total_tokens",0),"text":txt,"finish":d["choices"][0].get("finish_reason")}
res={"model":"Qwen3.8-27B-AWQ-INT4","startup_s":startup,"functional":{},"perf":{}}
fail=0
# --- functional
for name,p,kw in [("capital_of_france","What is the capital of France? Answer in one word.",{"max_tokens":16}),
                  ("arithmetic","What is 17*23? Reply with just the number.",{"max_tokens":32}),
                  ("chinese","用一句话介绍你自己。",{"max_tokens":64})]:
    try: r=ask(p,**kw)
    except Exception as e: r={"error":str(e)}
    res["functional"][name]=r
    ok = ("error" not in r) and r.get("text","").strip()!="" and r.get("completion_tokens",0)>0
    if name=="capital_of_france": ok = ok and "paris" in r.get("text","").lower()
    if name=="arithmetic": ok = ok and "391" in r.get("text","")
    print(("  [ OK ] " if ok else "  [FAIL] ")+name+f" -> {str(r.get('text',''))[:60]!r}")
    fail |= 0 if ok else 1
# --- perf: sequential TTFT-ish + concurrency 4
lat=[]
for i in range(3):
    r=ask("Write a short paragraph about GPUs.",max_tokens=128); lat.append(r["latency_s"])
    time.sleep(0.2)
res["perf"]["sequential_latency_s"]=lat
res["perf"]["sequential_tps"]=round(sum(128/x for x in lat)/len(lat),1)
N=8; t=time.time()
with cf.ThreadPoolExecutor(max_workers=4) as ex:
    outs=[f.result() for f in [ex.submit(ask,"Explain tensor parallelism briefly.",128) for _ in range(N)]]
wall=time.time()-t; toks=sum(o.get("completion_tokens",0) for o in outs)
res["perf"]["c4_requests"]=N; res["perf"]["c4_wall_s"]=round(wall,2)
res["perf"]["c4_throughput_tps"]=round(toks/wall,1)
print(f"  [ OK ] sequential avg latency {sum(lat)/len(lat):.2f}s (~{res['perf']['sequential_tps']} tok/s/stream)")
print(f"  [ OK ] c=4 throughput {res['perf']['c4_throughput_tps']} tok/s over {wall:.1f}s ({toks} tokens)")
json.dump(res,open(out,"w"),indent=2,ensure_ascii=False)
print("  json:",out)
sys.exit(1 if fail else 0)
PY
rc=$?
say "== model verify rc=$rc"
exit $rc