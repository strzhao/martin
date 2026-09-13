# contrib 流水线 AI Native 设计 v2（clean-sheet 宪法）

> 2026-09-13 定稿，取代 v1（v1 的 W1 落地记录见文末附录，其中 C 系值班环/B1 裁定被本版吸收或取代）。
> 定案历程：W1 交付后用户判定「还是很不 AI Native」→ 六轮对话收敛 → AI 视角用户故事推演暴露 10 缺口 → 本宪法。
> 实施波次（P0/A-E）见 plan 文件 tidy-jumping-fiddle.md，本文记录不可变的架构裁定。

## 0. 一句话

**链上无脚本**：六个节点全部 AI 主导；代码降格为三副钳夹 + 两本账 + 运输管道。看板是唯一状态，operator 是唯一判断，一条心跳是唯一调度。

## 1. 节点与钳夹（宪法核心）

**判据**：遇到没见过的情况应该现场判断的 → 节点（AI）；需要毫不动摇、错了必须拒绝而不是变通的 → 钳夹（代码）。

### 六节点（全 AI，零脚本）

```
感知 → 分诊 → 造 → 过闸 → 守候 → 学习
```

- **感知**：operator 醒来扫全局（看板/gh/邮件），新信号物化为 `[sig]` 卡
- **分诊**：轻判三路——出手（spawn specialist）/ 观察（物化为 `schedule` watch 卡）/ 放行（理由留卡）。判断必落卡（P1 铁律）
- **造**：specialist 卡深研/forge（context 经济：operator 是路由器不是打工人，P2 双层铁律）
- **过闸**：草稿 → 审批卡（模板化）→ 微信 → 人批
- **守候**：已交付卡持续照看；等外部事项必须有卡（P4）
- **学习**：ops-journal + 每周 auditor 对抗审计 → charter 判例沉淀

### 三钳夹 + 两账本（代码，且只此）

| 钳夹 | 不变量 | 失败语义 |
|---|---|---|
| L2 闸（collect/execute 链） | 对外动作必经机械复验（TTL/占坑/refspec） | 拒绝，人面前停 |
| 预算 | 花钱不超配额 | 拒绝 |
| 心跳 | 每小时拉起 operator | 空转自愈（下小时新卡） |
| approved.log / ops-journal | 只记录，不决策 | — |

### 钳夹三律（防脆弱的根）

1. **失败语义显式且保守**：拒绝 + 告警，绝不变通、绝不重试傻转（幽灵 slug 4125 次教训）
2. **无状态，或状态只在账本/看板上**：无私有 state 文件（flight 私有信号教训）
3. **永不长大**：钳夹要长逻辑 = 该回收成节点的信号（auditor 每周查钳夹是否变胖）

**反通道**：节点反复正确执行的例行判断，经用户批准可沉淀为新钳夹（能力升格制）。

## 2. 卡的形态（五种，无一携带流程）

| 卡种 | 标记 | 本体 | 归宿 |
|---|---|---|---|
| 信号 | `[sig]` | envelope 级事实，无预填结论 | triage 列（operator 收件箱） |
| 问题 | `[q]` | specialist 任务 = 一个问题 + 产出契约 | ready（dispatcher 派） |
| 草稿 | `[draft]` | 待人裁决的对外提案 | 等人列（notify-subscribe 推微信） |
| 承诺 | `[watch]` | `schedule` 定时复查（「以后」的家，P3） | scheduled |
| 已交付 | （状态列） | 守候笔记 | done 前 operator 照看 |

旧系统「卡 = 带说明书的工单」废除。流程活在 skill 里，结果活在卡里。

## 3. 权限模型（类别闸，非白名单枚举）

- 研判/分诊/watch/本地可逆动作 → operator 自主
- 一切对外（gh 写/push/发评论/发版）→ L2 提案；**agent 起草，链落笔**（P5 定海神针：execute.sh 机械复验是提案变现实的唯一通道）
- 花钱 → 预算钳夹
- 新动作类型 → 提案卡升格制（人批一次成原则）——信任旋钮

## 4. 迁移与终态

五波（P0/A/B/C/E→D 最后大扫除），每波以删除收官。终态：

- **scripts/contrib ≈ 4 文件**：heartbeat.sh / gateway_sentinel.sh（基建）/ l2_ledger.sh + 精简 tests
- **账本 3 本**：看板 / approved.log / ops-journal
- 退役清单：run-watch、scan_gate、mail_gate、deepcheck 族、duty/state_brief、own_pr_watch、coder_upstream_gate、notify events 族、rq 管线职责、kanban_card、cursors/snapshots/flights/pending-batches

## 5. 成功度量（月度口径）

| 指标 | 09-13 基线 | 目标 |
|---|---|---|
| 账本数量 | 9 | 3 |
| scripts/contrib 文件 | 16+ | ≤4 |
| 深检有效产出/周 | 0（死锁）/ 恢复中 | ≥3 且零死锁 |
| 积压腐烂 | 82 条含 3 天孤儿 | 零腐烂（watch 卡化 + operator 最老优先） |
| 新失败类处置 | 写新 guard | operator 吸收 ≥80%，guard 零新增 |
| KPI：commit 进仓 | 周产出波动 | operator 每日评估 forge 时机 |

## 附录 A — v1 摘要（2026-09-13 晨，已被本版取代的部分）

v1 三层架构（L1 硬底座/L2 看板控制面/L3 值班 agent 环）方向正确但保守：brief 冻结格式、白名单枚举、值班卡权限巴掌大——即「AI 的手、bash 的脑」。W1 实际交付：A1-A3（审批侧双修+日报卡复活）、B2/B3（hermes 分支，已 cherry-pick 进本地栈：ff6a4b3da0/cf8c3c38f3/e482ec93ae）、C1 state_brief + 断言加固、C2 值班环（duty_card/SKILL 模式七/L1 白名单）。其中 B2/B3 为本版直接复用的框架件；C 系与 state_brief 在 E 波被 operator 吸收退役。09-12 四活体缺陷全部闭环（详见 git log 88a8b54/2926c72 与 duty-ledger）。

## 附录 B — AI 视角推演暴露的 10 缺口（本版的修正依据）

P1 判断必落卡（板=记忆）；P2 operator=路由器（双层铁律）；P3 「以后」必须 schedule 卡；P4 等外部必须有卡；P5 agent 起草链落笔（审批链与 rq 解耦前不动 L2）；P6 钳夹收缩为小工具面；P7 新旧状态先迁移再交班；P8 知识整编是主工程；P9 每周 fresh-context auditor；P10 journal 四行软契约。
