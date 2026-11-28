# staging/ci — CI/CD 落地文件（待审阅，未提交）

方案 C（混合）：GitHub 托管 runner 跑秒级静检，本机 self-hosted runner 跑重活，
systemd timer 做夜间兜底。

## 文件清单

| 文件 | 归属仓库 | 作用 |
|---|---|---|
| `ci/stage.sh` | rvocs-hcs-amd | 包住 `scripts/build.sh` 的 CI 包装：断点续跑（`.stage_done/<stage>.<key>`）、CPU/GPU 锁、磁盘内存守卫、日志、ALERT、`$GITHUB_STEP_SUMMARY`、镜像 digest |
| `ci/check-pins.sh` | rvocs-hcs-amd / rvocs-main | ①`config/sources.sh` 的 `src_define` pin 与本地 HEAD 一致性；②`upstream/*/.pin` 校验；③调用 `scripts/tools/patch.sh check`（权威）验证 23 个补丁可应用 |
| `ci/quick-bench.sh` | rvocs-hcs-amd | GPU 性能回归：拉/复用容器 → 等 `/v1/models` → `vllm bench serve` 一轮 → 与基线 TPOT 62.05ms 比对，超 15% 判 REGRESSION |
| `.github/workflows/ci-static.yml` | rvocs-main（或任意） | L0：`bash -n`、shellcheck(-S error)、patch 可应用性、pin 一致性、workflow YAML 解析 |
| `.github/workflows/build.yml` | rvocs-hcs-amd | L1–L5：build → wheels → image → verify → release，含 SWR 登录、artifacts 只放清单、GPU 独占与环境审批 |

## 已验证（2026-11-24，在本机 staging/ 内直接跑）

```
bash -n ci/*.sh                        -> OK x3
yaml.safe_load(workflows)              -> OK x3（含既有 ci.yml）
ci/stage.sh build|wheels|image|verify --dry-run
  -> 正确解析为 scripts/build.sh --stage <x> --arch riscv64 --gpu r9700
     --image-kind vllm --image-tag rvocs-vllm-therock10.0-r9700-riscv64:sha-853f7453b5b3 --jobs 64
ci/check-pins.sh                       -> fail=0 warn=1
   pytorch cf30153c4c13 == local HEAD
   torchvision v0.28.0 (tag)
   triton 5f3f125e8f63 == local HEAD
   vllm 98dff2a81d74 == local HEAD
   patch.sh check -> PATCH_CHECK_OK (23 patches)
```

`stage.sh` 的 stage key 由 `git HEAD + patches/docker/scripts 文件指纹 + 脚本自身 sha` 组成，
输入不变则命中 marker 直接 SKIP（日志与 summary 会写明 `cache hit`）。

## 部署前需要你提供 / 确认的 6 项

1. **self-hosted runner 注册 token**（repo → Settings → Actions → Runners → New self-hosted runner），
   labels 建议：`self-hosted,linux,riscv64,amd-gpu,gfx1201`（GPU 作业额外要求 `amd-gpu`）
2. **Secrets**：`SWR_USER`、`SWR_PASSWORD`（我已把脚本里所有 `sudo -S` 改成 `sudo -n`，依赖现存的
   `/etc/sudoers.d/99-docker-nopasswd`）
3. **Environment `gpu-approval`** 创建 + 添加 required reviewers（防止误占卡）
4. **`IMAGE_TAG` 语义确认**：`scripts/build.sh` 的默认 tag 我看不到最终形态，工作流用
   `sha-<12>` 覆盖，如需 `vX.Y.Z` 请在 release job 里改
5. **`RVOCS_ROOT` 路径**：工作流假定 `/home/ubuntu/RVOCs-CICD/rvocs-hcs-amd`；若 runner 检出到
   `_work/` 下，建议设置 `RVOCS_ROOT=/home/ubuntu/RVOCs-CICD/rvocs-hcs-amd`（复用已有构建树）而不是
   每次 checkout 到临时目录（否则 19GB 源码与 ccache 全部失效）
6. **`patch.sh status` 语义**：`list` 里出现 `fail` 属正常（尚未应用的补丁），我已改用
   `patch.sh check` + `PATCH_CHECK_OK` 作为唯一成功判据

## 上线顺序（建议）

1. 先只上 `ci-static.yml`（零风险，验证 runner/权限链路无关，托管 runner 即可）
2. `ci/stage.sh preflight` 手工跑一次，确认 guards 与 lock 文件权限（`/var/lock` 需 ubuntu 可写，
   或用 `CI_CPU_LOCK=$HOME/.rvocs-ci.lock`）
3. 再上 `build.yml` 的 build → wheels（手动 `workflow_dispatch` + `force=false` 验证 cache 命中）
4. 最后开 image → verify（verify 需 `gpu-approval` 审批）

## 已知未覆盖

- 夜间 `schedule` 与 GitHub 长时间不可用：需加方案 B 兜底（复用 `ci/poll-build.sh` + timer）
- 告警 webhook URL 未提供，`logs/ALERT` 目前只落盘
- `build.yml` 的 `release` job 依赖 `gh release upload`，需 `GITHUB_TOKEN` 有 `contents: write`（当前为 read）
