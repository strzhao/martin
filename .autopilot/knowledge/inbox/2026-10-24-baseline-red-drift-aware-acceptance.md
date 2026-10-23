# 纯测试面卡基线红处置范式 + headless 接力前台纪律（t_57210563 退役孤儿套件卡）

<!-- tags: autopilot, qa, acceptance-predicate, flake, headless-relay, contrib-tests -->

## Lesson：基线自带存量红时，验收口径改「与基线零回归 + 失败集白名单」，不改成硬凑全绿
**When** 目标是纯测试面/纯删除卡（零生产面改动），而 design 期实测基线 `run.sh` 非绿（存量 flake，origin/main 已含）——「提交后全绿退出 0」字面不可达。
**How**：契约修订为 v2 漂移类别感知：结构性字段（total/skipped/四维计数）与基线逐字段一致 ∧ 失败行集 ⊆ 已知 flake 簇白名单（failed≤N），任何非白名单失败行=硬红。立据需三重独立：机制分析（为何 flake）+ 双向实证（红窗/绿窗各跑一次，total 恒等）+ 外部裁决文件（FACT-CORRECTION.md 形态，发车后由陪跑员核实落盘）。本卡实证：C27（unit/write-attribution.sh 348/350，知识库 §15）随套件延迟双向波动，1386 total 恒等。
**Choice**：不扩 scope 修存量 flake（会违反零生产面红线）；flake 修复作为遗留发现移交未来卡（本卡候选形态：套用 C28 的 `touch -t` 确定性时间锚构造，unit:686 已有范式）。

## Lesson：headless autopilot 接力中，长验证（>1min）一律前台跑完再推进
**Why**：后台子进程（run_in_background / nohup）随父进程（claude -p 会话或其 90min alarm 包装）终止而终止——本卡连续 3 轮折戟于同一根因（Tier 0 全量 run.sh 后台跑被掐死，日志停在启动横幅、无任何结果行，属空标题不可信）。
**How**：7-10 分钟级验证用前台 Bash（timeout 拉满 600000）直接跑完拿输出；计划内接力不属失败，接力启动器（.launch-relayN.sh 包装 claude -p + alarm）会在 worktree 积累为 untracked 文件，白名单断言需随收编扩元素（每轮实读确认非任务产物再并入，留痕变更日志）。
