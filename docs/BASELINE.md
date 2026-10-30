# 上游基线管理

## 1. 什么算“基线”

基线 = **`upstream/therock` 子模块的 gitlink**（`git ls-tree HEAD upstream/therock` 得到的 commit）。
它同时决定了：

- TheRock 构建系统的版本（CMake 逻辑、feature flags、打包行为）
- TheRock 内部各组件（rocm-libraries / rocm-systems / third-party …）的版本——由 TheRock
  自己的 `build_tools/fetch_sources.py` 按它的 gitlink 检出，本仓库不重复 pin

`manifest.yaml` 里的 `upstream.therock.ref` / `commit` 是同一份信息的**人类可读副本**，
不参与构建。两者不一致时 `baseline.sh check` 会报错。

为什么这样设计：
- 子模块 gitlink 天然随提交走 —— 切 git commit 就等于切基线，回退只需 checkout；
- 不会出现“文档写 10.0、实际编 10.1”的漂移；
- 上游组件的 pin 由上游维护，本仓库不必跟随上游每次改动去 bump 十几个子模块。

## 2. 日常命令

```bash
./scripts/tools/baseline.sh status      # 一眼看清：pin / 实际 HEAD / 脏状态 / 产物大小 / 补丁
./scripts/tools/baseline.sh check       # 机器可读校验，失败返回非 0（CI 用）
./scripts/tools/baseline.sh history     # 所有基线快照 tag 及时间
```

## 3. 升级到新上游版本（SOP）

```bash
# 1) 看看上游有什么
./scripts/tools/baseline.sh sync

# 2) 切到新基线（--commit 会顺带生成一个提交）
./scripts/tools/baseline.sh bump therock-10.1 --commit

# 3) 重放补丁，逐个修复冲突
./scripts/build.sh --stage prep
./scripts/tools/patch.sh check --verbose

# 4) 全量构建 + 验收
./scripts/build.sh --stage all

# 5) 通过后打快照，便于回退
./scripts/tools/baseline.sh tag 2026-10-21-rocm10.1
```

补丁修复的两种方式：
- 小改：直接在源码树里改，然后 `scripts/tools/patch.sh capture <comp> <name>`；
- 大改：`patch.sh revert <comp>` 撤销后重打，或对单个补丁 `git apply --3way` 后重新 capture。

## 4. 回退

```bash
./scripts/tools/baseline.sh rollback baseline/2026-10-21-rocm10.1   # 回到某个快照
./scripts/tools/baseline.sh rollback therock-10.0                  # 回到某个 tag
./scripts/tools/baseline.sh rollback <commit-sha>                  # 回到某个 commit
```

`rollback` 同时恢复 `manifest.yaml` 与子模块 gitlink，并执行 `git submodule update`。
之后务必重跑 `patch.sh check` —— 旧补丁可能不适用于更早的基线。

## 5. 重新开始

```bash
./scripts/tools/baseline.sh restore --force   # 丢弃子模块内所有改动（含补丁），保留 build/
./scripts/tools/baseline.sh clean  --yes     # 删除 build/（源码与补丁保留）
```

`restore` 用于“我想确认补丁是否真的全部生效”；`clean` 用于“换了 family / 想彻底重编”。

## 6. 什么时候需要动基线

| 场景 | 动作 |
| --- | --- |
| 追新组件（如新的 hipBLASLt / rocBLAS） | `bump` 到新的 upstream tag |
| 某个 RISC-V 补丁被上游合入 | 仍 `bump`，然后在 `patches/` 里删掉该补丁 |
| 构建失败想排除本地因素 | `restore --force` + `clean --yes` 后重编 |
| 需要固定给客户交付 | `tag` 一个 `baseline/<版本>` 快照 |
