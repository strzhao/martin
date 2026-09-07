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
- 已落地：`life` / `life-cc`（09-06，dogfood 全链已跑通）、`contrib` / `contrib-cc`（09-07，见 §8）
- 待建：`ops` / `ops-cc`、`hkstock` / `hkstock-cc`
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
# 1. 拉自己 lane 的待领队列
hermes kanban list --assignee contrib-cc --status ready --json

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

## 8. contrib 域接入（2026-09-07 已实施）

contrib 域的特殊性：确定性部分**已经全自动化**（launchd :07 scan/radar → 深检三轮审 → L2 三路审批 → execute 投递），lane 化不是迁移而是补缺口。

**已落地**：
1. `contrib` profile（hermes worker lane）：只读研判专家（premise 复验/状态核查/报告解读/台账整理），SOUL.md 含知识源路由（hermes-contribution.md §2/§5/§7/§9/§10/§11）+ gh 只读红线；honcho.json 独立 aiPeer `contrib`
2. `contrib-cc` lane 双来源：①execute.sh own-PR 已批分支自动建卡（scripts/approval/execute.sh，`--idempotency-key <rq-id>` 幂等，事件链保留作兜底；验收测试场景 10 全绿）②微信自然语言派单（default SOUL.md 派单路由表）
3. default profile SOUL.md 加了 contrib 派单三分路由（直答 / `contrib` / `contrib-cc`）

**设计决策（探查报告建议被否决的记录）**：escalate 分支**不**建 contrib-cc 卡——escalate 项的消费者是用户（L2 审批：批/改/否），不是 CC claim；给审批项再挂任务卡会造成双消费路径（用户批后「两边都不动/都动」）。审批环保持原样。

**边界**：rq 状态机 / approved.log / budget 账本全部保留为独立 SSOT，kanban 卡只是「待领队列」的补充容器；own-PR 卡 push 前仍受 `allow_own_pr_push` 闸门约束（lane 化不豁免任何 L2 红线）。

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
