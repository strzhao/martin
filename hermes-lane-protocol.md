# hermes × Claude Code Lane 模式协作手册

> 2026-09-06 定案。多域 COO 架构的执行规范：kanban.db 是唯一事实源，hermes 侧跑确定性流水线，Claude Code 以 control-plane lane 消费者身份认领需要判断力的卡。**后续每个新 profile 创建时都必须按本手册落 lane 配置。**

## 0. 架构总览

```
微信（唯一入口，自然语言派单）
   │  「派给 <域> 做 X」
   ▼
default profile agent（toolsets 含 kanban，14 个 kanban 工具）
   │  kanban_create → 自动订阅微信会话（auto_subscribe_on_create）
   ▼
kanban.db（唯一事实源，WAL + BEGIN IMMEDIATE + claim CAS）
   │
   ├─ assignee = 真 profile ──→ gateway 内嵌 dispatcher spawn 隔离 worker
   │                            （独立 HOME/sessions/memory，上下文硬隔离）
   │
   └─ assignee = <域>-cc ─────→ dispatcher 识别为 control-plane lane，
                                永不 spawn，停 ready 等 Claude Code claim
                                （kanban_db.py:10160 官方设计）
```

**护栏**（config.yaml kanban 段，2026-09-06 已落地）：`auto_decompose: false`（dogfood 期路由人工确认；#49638 事故路径）、`max_in_progress: 2`（macOS 内存推导失效会回落无界，必须显式）、`default_assignee: "default"`、`auto_subscribe_on_create: true`（默认）。

## 1. 分工原则：确定性归 hermes，判断力归 CC

| | hermes worker（真 profile lane） | Claude Code（`<域>-cc` lane） |
|---|---|---|
| 任务性质 | 确定性、无人值守、模板化 | 需要判断力、策略权衡、对外落弹前的材料准备 |
| contrib 域例子 | radar 日报、premise 复验、本地构建草稿 | 深检研判、PR 落地、salvage 决策、策略讨论 |
| life 域例子 | 餐厅/目的地调研、信息汇总 | 行程最终决策、风格化内容定稿 |
| 超时画像 | 分钟级，`--max-runtime` 封顶 | 小时级，`claim --ttl` + `heartbeat` 续期 |

**判断口诀**：能写成 SOP 的 → 真 profile；每次都要重新想的 → `<域>-cc`。

## 2. Lane 命名规范

- 每个域一对 lane：`<域>`（真 profile，dispatcher 自动 spawn）+ `<域>-cc`（**必须是不存在的 profile 名**，CC 专属）
- 已落地：`life` / `life-cc`（09-06，dogfood 全链已跑通）、`contrib`（09-07，见 §8；`contrib-cc` 已于 09-08 下线，own-PR 执行改走 coder lane）、`hkstock`（09-08 立项落地，**不设 hkstock-cc**——用户裁定 cc lane 模式对本域不适用，理财分析走真 profile worker）
- 待建：`ops` / `ops-cc`
- **⚠ cc lane 模式降级为可选（2026-09-08，contrib-cc 先例）**：cc lane 卡停 ready 等 CC 会话 claim、消费侧无自动化，与「批准即全自动」目标相悖。凡可自动化的 CC 任务一律走真 profile + worker 驱动 `claude -p`（coder lane 模式）；cc lane 只保留给**确需人本人在环**的交互式任务。新域默认不建 `<域>-cc`，除非能明确回答「为什么这活必须等人开 CC 会话」。
- dispatcher 对 control-plane lane 的处理：进 `skipped_nonspawnable` 桶、不计 stuck、永不 spawn（`has_spawnable_ready` 过滤，kanban_db.py:8038）

## 3. 建卡规范

**谁建卡**：微信自然语言派单（agent 调 `kanban_create`）或 CLI `hermes kanban create`（脚本/调试）。

**必填心智**：
- `--assignee`：按 §1 口诀选 lane
- `--body`：自包含上下文。worker/认领者可能完全没有前情——目标、约束、相关文件路径、完成标准都写进去（body 上限 8KB，长材料写文件后给路径）
- `--workspace worktree [--branch xxx]`：**凡涉及改 git 仓库代码的卡必须加**——dispatcher 物化 `<repo>/.worktrees/<task-id>` + `wt/<task-id>` 分支，与主 checkout 物理隔离（kanban_db.py:10237）
- `--max-runtime`：真 profile 卡必给（如 30m），防 worker 失控
- `--idempotency-key`：脚本建卡必给，防重复
- `--skill`：按任务挂载能力包（task.skills 列，叠加在内建 kanban-worker 之上）——**能力组合的 Correct 层，不要为能力差异拆 profile**

**禁止**：把需要 L2 审批的对外动作写成真 profile 卡让 worker 自动执行——审批闸门不因 kanban 化而豁免（纪律守恒）。

## 4. CC 侧标准动作流

```bash
# 1. 拉自己 lane 的待领队列（示例用 life-cc；contrib-cc 已于 09-08 下线，勿再使用）
hermes kanban list --assignee life-cc --status ready --json

# 2. 认领（CAS 锁，抢不到安全失败；ttl 要给够）
hermes kanban claim <task_id> --ttl 7200

# 3. 无损取上下文（与 dispatcher 注入 worker 的同一份：
#    body + 历史 attempts summary + 父任务交接 + 评论串）
hermes kanban context <task_id>
hermes kanban show <task_id> --json   # 需要全字段时

# 4. 长任务续活性，防 TTL 过期被 reclaim
hermes kanban heartbeat <task_id>

# 5. 产物三层回流（与 hermes worker 完全同构）
hermes kanban comment <task_id> "过程讨论/中间结论"
hermes kanban attach <task_id> ./报告.md        # 整份产物，≤25MB，dashboard 可预览
hermes kanban complete <task_id> --summary "一句话结论" \
  --metadata '{"issue":103271,"branch":"contrib/xxx","pr_draft":"..."}'
# 需要人审 → request-review；缺输入 → block --reason（上浮给人）
```

## 5. 红线

1. **CC 会话永不跑 `hermes kanban dispatch` / `daemon`**——调度权是 gateway 独占（flock 单例锁 `.dispatcher.lock`）；CLI 路径不拿这把锁，双跑会导致 worker 子进程资源竞争（claim CAS 只防重复 spawn，不防资源踩踏）
2. **调度类配置改动后重启 gateway**：`max_in_progress`/`default_assignee` 是 watcher 启动时读取；`auto_decompose` 每 tick 重读（#49638 修复）不用重启
3. **L2 闸门不豁免**：kanban 卡只是任务容器；对外动作（gh 写、发帖、推送）仍走 approved.log / 微信审批环
4. **hermes 外发消息规范不变**：worker 完成推送已是规范化模板卡；叙事类结果回流微信仍须 AI 整理层
5. **profile 只按边界拆，不按能力拆**：权限/身份/爆炸半径差异才配新 profile；能力差异用 task 级 `--skill` 挂载

## 6. 并发安全模型（为什么这套不打架）

- kanban.db：WAL 模式 + `BEGIN IMMEDIATE` 写事务 + `claim_task` 原子 CAS（`UPDATE ... WHERE status='ready' AND claim_lock IS NULL`），SQLite 串行化写者，同一任务至多一个认领赢家（kanban_db.py:55-68, 4617）
- gateway 内嵌 dispatcher 持 `.dispatcher.lock`（fcntl 非阻塞），多 gateway 部署由 `dispatch_in_gateway` 指定唯一 owner（docs/kanban/multi-gateway.md）
- CLI 读写命令（list/show/claim/context/comment/attach/complete/tail/watch）与 gateway 并发安全
- 偶发双 claim 同一卡：CAS 输家拿到 "cannot claim … lock=…"，安全失败

## 7. 新 profile 创建 SOP（含 lane 配置）

```bash
# 1. 建 profile（clone 拿模型/skills；description 是 decomposer 的路由信号，必须写准）
hermes profile create <域> --clone --description "<一句话说清这个专家管什么、不管什么>"

# 2. 定制 SOUL.md：~/.hermes/profiles/<域>/SOUL.md
#    - 定位与边界（管什么/不管什么，越界时建议路由到哪个 profile）
#    - 领域知识锚点（档案/文档路径，如 about-me、martin 下的域手册）
#    - 作为 kanban worker 的行为准则：读全 context → 干活 → 结构化 summary 回流
#    - 语气与语言（默认中文）

# 3. 按需调 ~/.hermes/profiles/<域>/config.yaml（model pin / toolsets / 记忆开关）
#    注意：clone 后是独立副本，改 default 不会影响已有 profile

# 4. dogfood 首卡：CLI 建一张 5 分钟内的无害卡验证主链
hermes kanban create "smoke: <小事>" --body "..." --assignee <域> --max-runtime 5m
hermes kanban tail <task_id>   # 观察到终态

# 5. 声明 CC lane：无需创建任何东西——<域>-cc 作为不存在的 profile 名直接用作 assignee
#    在 CLAUDE.md / 域手册里登记该 lane 的用途

# 6. 真卡走微信自然语言派单，验证终态推回微信
```

### 7.1 hkstock 域登记（2026-09-08 立项落地）

- **形态**：单真 profile `hkstock`（理财专家：A股/港股/基金/期货的盘前简报、持仓问答与结构化市场信号；只做信息与信号，不做任何交易执行），**不设 hkstock-cc**（用户裁定 cc lane 模式对本域不适用）。
- **数据层**：`martin/hkstock-data/holdings.yaml`（目录整体 gitignore，隐私数据不入库）——worker 读不到/解析失败必须 block 不猜；校验器 `martin/scripts/hkstock/validate_holdings.py`（exit 0=合法 / 1=字段违规 / 2=文件缺失或解析失败）。
- **配置**：`~/.hermes/profiles/hkstock/`（SOUL.md 六节闭集；config toolsets = hermes-cli + kanban + terminal；honcho.json aiPeer=hkstock）；派单路由表已登记于 `~/.hermes/SOUL.md`。
- **待建**：T2 盘前简报 brief_guard.sh、T3 信号落库 signals.jsonl（schema 在 SOUL.md「分析框架」节预留）。

## 8. contrib 域接入（2026-09-07 实施；09-08 lane 改造）

contrib 域的特殊性：确定性部分**已经全自动化**（launchd :07 scan/radar → 深检三轮审 → L2 三路审批 → execute 投递），lane 化不是迁移而是补缺口。

**已落地**：
1. `contrib` profile（hermes worker lane）：只读研判专家（premise 复验/状态核查/报告解读/台账整理），SOUL.md 含知识源路由（hermes-contribution.md §2/§5/§7/§9/§10/§11）+ gh 只读红线；honcho.json 独立 aiPeer `contrib`
2. **own-PR 执行 = coder lane 全自动（09-08 起，替代已下线的 contrib-cc 卡）**：execute.sh own-PR 已批分支探测 build 产物分流——`push-only`（BRANCH.md+worktree 校验通过 → `--workspace dir:<worktree>` 45m）/ `build-and-push`（无产物 → `--workspace worktree:<hermes-agent 仓>` 4h）——建 coder 卡（`--idempotency-key <rq-id>` 幂等），dispatcher spawn worker 驱动 claude -p 完成 push fork + gh pr create，rq set executed 由 worker 收尾（claude 不碰 martin 仓）。`allow_own_pr_push` 语义=**急停总开关**（false=不建卡只发 approval-manual-required 事件退回人工）。验收测试场景 10.A-D 全绿。
3. default profile SOUL.md 派单路由：直答 / `contrib` / `coder`（contrib-cc 行已删）

**设计决策（探查报告建议被否决的记录）**：escalate 分支**不**建卡——escalate 项的消费者是用户（L2 审批：批/改/否），不是 worker；给审批项再挂任务卡会造成双消费路径（用户批后「两边都不动/都动」）。审批环保持原样。

**边界**：rq 状态机 / approved.log / budget 账本全部保留为独立 SSOT，kanban 卡只是执行容器；own-PR 自动化不豁免任何 L2 红线（auto-gate「own-PR 永不自动」独立生效，仍必走 L2-A 微信批准；TTL 复验四项在建卡前照跑）。

**contrib-cc 下线记录（09-08）**：唯一实际使用的 cc lane（execute.sh 自动建卡 → 等 CC 会话 claim），消费侧从无脚本实现、SOP 随卡走，实际是「等人来」。用户拍板「不该存在这个模式」→ 删除（代码 1 处 + 文档 5 处 + 测试重写），执行通道升级为 coder lane 全自动。存量卡 t_e5f19d5a 已 archive。

## 9. 关键源码锚点

| 机制 | 位置 |
|---|---|
| control-plane lane 判定 | `hermes_cli/kanban_db.py:10160` |
| claim CAS | `hermes_cli/kanban_db.py:4617` |
| worker 上下文组装 | `hermes_cli/kanban_db.py:11004`（build_worker_context） |
| dispatcher watcher | `gateway/kanban_watchers.py` |
| kanban 工具面（14 个） | `tools/kanban_tools.py` |
| 建卡自动订阅 | `tools/kanban_tools.py:1484`（_maybe_auto_subscribe） |
| worktree 物化 | `hermes_cli/kanban_db.py:10237` |
| profile 管理 | `hermes_cli/profiles.py` |
| 用户文档 | `website/docs/user-guide/features/kanban.md` |

## §10 coder lane（CC 内嵌 worker）（2026-09-08 立项）

四域之外的第五 profile：**coder** = 复杂编码执行 worker。与其他 lane 的区别——它不是 CC 会话 claim 的 control-plane lane，而是真 profile：dispatcher spawn 后由 hermes worker 陪跑一次 Claude Code 无头驾驶。

**链路一行图**：微信 → default（AI 自判，coder-delegate skill）建 coder 卡 → dispatcher spawn coder worker → worker 用 terminal 工具在 kanban 物化的 git worktree 里**多轮接力**跑 `claude -p "/autopilot <目标> --fast"`（⚠️ Phase 0 spike 实证 09-08：单条 -p 进程退出后循环即停、不自续到 done，worker 必须循环重调直到 state.md `phase: done`；启动轮 slash prompt 输出常为空、续跑轮自然语言 prompt 输出完整可读）→ 每轮 `process(action=wait)` 分片等待 + heartbeat → done 后验收（commit/测试/diff）→ `kanban_complete`（三段式 summary + metadata）→ notifier 推回微信。

**worktree 归属决策**：worktree 由 kanban 物化（`hermes_cli/kanban_db.py:10237`），**不交给 autopilot 再建一层**——autopilot 的 SessionStart hook 在 worktree 内会自动进 worktree-session 模式（锚 `worktree-bootstrap.sh` 行为），worker 只需把 claude 的工作目录指向 `$HERMES_KANBAN_WORKSPACE`，两层机制天然兼容。

**L2 红线互引（本文件 §5.3）**：coder 只 commit 不 push（`--disallowedTools` 硬禁 `git push`/`gh pr`/`gh api`/`gh release`，白名单 + 红线双闸）；一切 push/PR/release 需求走 L2 审批环，coder 卡的产出物是本地 worktree 分支 + 本地 commit，合并与发布是卡外的人工/审批动作。**唯一例外（09-08 lane 改造）：own-PR 执行卡**（body 带 `类型: own-PR 执行`，approval 流水线 L2 批准后由 execute.sh 建卡）——按卡 body 配方放开 `git push fork` + `gh pr create`（仍禁 `gh pr merge`/`gh release`/`gh api` 写/`git push origin`/force），执行手册见 claude-run SKILL §⑦。

**执行手册**：`~/.hermes/profiles/coder/skills/claude-run/SKILL.md`（CLI 探测、模型 pin、双层超时、启动配方、auto_approve 兜底、失败矩阵、own-PR 执行卡 §⑦）。

**验收**：走本文件 §7 新 profile 创建 SOP 的 smoke 卡步骤（设计文档写 §9，实为 §7——§9 是源码锚点表）。
