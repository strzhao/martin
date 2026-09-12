# contrib-ops AI Native 改造设计（v1）

> 2026-09-13 立项。起因：09-12 四个活体缺陷暴露「卡化改造走了一半——工作上了看板，状态还留在 bash」。
> 本文是并发执行的 shared spec：每个优化点含范围/落点/交付/验收/依赖/红线，可直接拆卡。
> 关联：`harness-engineering-principles.md`（原则镜照）、`hermes-lane-protocol.md`（执行规范）、hermes-contribution.md §11（goods 标准）。

---

## 0. 判题与证据

**补丁跑步机的根因不是 guard 不够，是状态放错了层。** contrib-watch 在 bash 里长出了影子工作流引擎（ready-queue.json / flight-*.json / scan-cursor / own-pr-snapshot / budget / events.jsonl 七套账本），与它自己驱动的 hermes kanban 平行竞争。

09-12 四缺陷 → 通用引擎能力对照：

| 缺陷（活体病例） | 影子引擎里的根因 | kanban 已有/应有的通用能力 |
|---|---|---|
| 深检单飞槽死锁 8.5h+（t_f8c0d470，flashcards 误派卡 blocked 占槽） | flight json 信号量无租约无回收 | worker claim 本有 `claim_expires` + stale reclaim（kanban_db_dispatch.py:362-380）；并发上限本有 per-profile #21582 |
| 孤儿卡躺平 3 天（t_cb14f0ee，rq 早已 executed） | 无死后处理 | `gave_up` 事件已有，缺死信车道 |
| 日报卡秒崩×2（t_92c903b0，pin 了 profile 没有的 skill） | kanban_create 不校验 skill 存在性 | create-time 校验 |
| 幽灵 slug 重试 4125 次/5 天（tunnel rm c0i5s6514x） | rm 不幂等 + collect 无终态出口 | 幂等操作语义 |

原则镜照：正交原则（A）被违反——同一编排语义两处状态；原则 B（模型不可靠→机制层）被过度应用——编排调度是判断密集型而非安全边界；反模式 2 同构——bash gate 失败≠确定性保证（09-12 notify flush 失败→事件静默延迟 9h）。

## 1. 目标架构：三层

```
L3 值班 agent 判断环   值班卡领 state brief（零 LLM 生成）→ 自主决定补跑/回收/升级/无事；
                       新失败类归纳进失败分类学（SKILL.md checklist = 知识即代码）
L2 看板即控制面        状态唯一真源 = board：rq→卡片列、flight→在途卡本身、
                       深检槽→dispatcher per-kind 上限、死信→巡检列
L1 硬底座（收窄不废除） L2 授权闸 / approved.log / 预算硬顶 / 外发 AI 整理层 / gh+邮件 IO
```

正确性语义转变：bash 时代 = 不出错（防错）；agent 时代 = **错了能被发现 + 能修复 + 留痕迹**（自愈+审计）。

## 2. 优化点分解：11 点 × 3 波

| 波 | 点 | 名称 | 落点 | 依赖 |
|---|---|---|---|---|
| W1 | A1 | 日报卡复活 | martin / kanban ops | 无 |
| W1 | A2 | flashcards 发版审批落地 | launchd env + rq 重放 | 用户在场 |
| W1 | A3 | 幽灵 slug 止血 | scripts/approval + tunnel-cli | 无 |
| W1 | B1 | dispatcher per-kind 并发上限 | hermes-agent | 无 |
| W1 | B2 | create-time 校验（skill/assignee） | hermes-agent | 无 |
| W1 | B3 | 死信车道（gave_up/blocked 超龄标记） | hermes-agent | 无 |
| W1 | C1 | state brief 生成器 | scripts/contrib | 无 |
| W1 | C2 | 值班卡机制 + L1 修复白名单 | martin + SKILL.md | C1 |
| W2 | D1 | rq 状态机→卡片列迁移 | martin | B3 |
| W2 | D2 | events→board notify + channel 隔离 | martin + sku-pipeline | B 系落地 |
| W3 | E1 | run-watch 五段骨架→纯采集器 | scripts/contrib | C2+D1 |

并发建议：W1 共 8 点，其中 **5 张可派卡**（B1-B3 hermes 仓 + C1-C2 martin 仓）；A1/A3 太小，顺手修不开卡；A2 需用户在场。W2/W3 串行在后。

## 3. 每点规格

### A1 日报卡复活（ops，10min）
- 动作：t_92c903b0 清 `skills` 字段重派（或按原 body 重建卡不带 skills——scan 卡即靠 SOUL 路由不 pin skill）。
- 验收：卡终态 done；《09-12 共建运转日报》落在 comment + complete summary；用户收到微信推送。

### A2 flashcards 1.3.0 发版审批落地（ops，需用户在场）
- 动作：`HM_CREDENTIALS` 进 launchd 环境（`launchctl setenv` 或 plist EnvironmentVariables）→ 重放 rq-20260912-812574 execute（approved.log 已有批准记录，重放=完成既定授权）。
- 验收：approval-execute.log 出现 executed + hm 侧提审成功回执。
- 注意：发版时机本身是用户决策，重放前与用户确认；同时把 release-gate 类 disposition 排除出 deep lane（见 B 系落地后的 D1 校验规则）。

### A3 幽灵 slug 止血（scripts/approval，30min）
- 动作：collect.sh 对 `tunnel rm` 失败先 `tunnel list` 复核——slug 已不存在→视为成功、标记 done 终态；tunnel-cli 仓 `drops rm` 对不存在 slug 幂等成功（独立小改，upstream 是自己）。
- 验收：collect.log 不再出现同 slug 连续失败对；`bash scripts/approval/tests/run.sh` 全绿。

### B1 ~~dispatcher per-kind 并发上限~~（已裁定取消，2026-09-13 凌晨）
- **裁定依据**：资源闸已在本地栈（commit 92007446e5，上游 PR #108006）——`--resources deepcheck:global` 排他锁即深检单飞的原生表达，且语义更优：blocked/gave_up 卡不持有资源（held=仅 running），t_f8c0d470 那类死锁结构性消失。另加 per-kind 配额是造第二个平行概念，违背正交原则。
- **原 B1 交付物去向**：深检卡接线（deepcheck 建卡加 `--resources deepcheck:global` + 废除 flight json 单飞检查）并入 C2；`max_in_progress_per_kind` 计数容量语义留作未来独立评估（仅当真出现「同资源需 N>1 并发」场景再立项）。

### B2 create-time 校验（hermes-agent，1 张卡）
- 落点：`hermes_cli/kanban_ops.py` create 入口。
- 交付：①skills 存在性——目标 profile skills 注册表查无 → **拒绝建卡**并列出 Unknown 清单（worker 必崩 = 数据损坏类，硬约束）；②assignee 存在性——profile 查无 → **警告不拒绝**（CC control-plane lane 语义：assignee=不存在 profile 是故意形态，软契约）。
- 验收：未知 skill 建卡被拒且报错可读；假名 assignee 仍可建卡（警告）；两者均有测试。
- 红线同 B1。

### B3 死信车道（hermes-agent，1 张卡）
- 落点：dispatcher tick（或 kanban_db sweep），config `kanban.dead_letter_after_hours`（默认 24，0=off）。
- 交付：`gave_up`/`blocked` 状态超龄卡自动 append `dead_letter` task_event（幂等：已标记不重复）+ 可选状态列标记；不自动改终态——消费方是值班环（C2），框架只负责「让尸体可见」。
- 验收：构造超龄 gave_up 卡 → 被标记一次且仅一次；未超龄不动；config=0 全关。
- 红线同 B1。

### C1 state brief 生成器（scripts/contrib，1 张卡）
- 交付：`scripts/contrib/state_brief.sh`（零 LLM）：contrib board 各列计数、在途/超龄卡清单（含龄）、gave_up 计数、rq awaiting/approved 悬空项、budget 余量、flight json 残留、重复 claim/崩溃卡。输出单文件 md（值班卡 body 直接用）。
- 验收：对当前库跑一次，**命中今天三个活体病例**（t_f8c0d470 超龄在飞、t_cb14f0ee 孤儿、t_92c903b0 gave_up）；空库/坏库不炸（fail-closed 输出降级 brief）。

### C2 值班卡机制（martin，1 张卡，依赖 C1）
- 交付：①值班卡建卡口（kind=duty，复用 kanban_card.sh）+ run-watch 挂段或独立入口；②`.claude/skills/contrib-watch/SKILL.md` 新增模式七（duty）：领 brief → 判伤情 → L1 修复白名单内动手 / 白名单外升级为事件；③L1 修复白名单：archive 卡、清 flight 登记、rq set expired、budget refund——**全部本地不可逆为零的操作**；④自愈台账 `contrib-data/duty-ledger.md`（动作 + decisionReason）。
- 验收：值班卡真实回收 t_cb14f0ee（孤儿卡开业验收）；台账留痕；零外发零 push。

### D1 rq 状态机→卡片列迁移（W2，依赖 B3）
- rq 各状态映射 board 列/label；flight json 废除（在途=卡在某列，深检槽=B1 配置）；rq.sh 退化为薄适配或退役；**approved.log 台账不动**（授权账本永久机制层）。
- 验收：深检候选从建卡到终态全程 board 状态可解释；旧 rq json 只读归档。

### D2 events→board notify + channel 隔离（W2，依赖 B 系落地）
- sku-pipeline/visual 事件迁独立 board 或独立 notify sub（`kanban_notify_subs` 已按 board 隔离）；contrib 告警预算独占。
- 验收：sku 事件不再出现在 contrib 渠道推送；两侧告警预算独立计数。

### E1 run-watch 收缩（W3，依赖 C2+D1）
- 五段骨架退化：scan 采集（gh 增量）、mail 采集、state brief 生成、值班卡触发、flush。编排决策上移 L3。
- 验收：删除的 guard 类代码行数 > 新增；故障注入演练（杀 worker/坏 json/断 gh）由值班环恢复而非脚本自愈。

## 4. 迁移顺序与回退

- W1 内部无相互依赖（C2 等 C1 交付物，可同卡接力）；B 系三卡在 hermes-agent 各自 worktree 天然并行，落地走本地 feature 分支 → 按升级机制合入常驻 observability-stack 栈（fetch+rebase 纪律不变）。
- 每点独立回退：B 系 config 默认关闭即回退；C 系不建卡即回退；D/E 是迁移非新能力，回退=git revert。
- 不做大爆炸：scan 研判链（质量在线）一行不动。

## 5. 明确不迁移清单（机制层永久驻扎）

L2 授权环（微信卡/tunnel 页/approved.log/48h 对账）、预算硬顶与配额告警、外发消息 AI 整理层与三段式结构、gh 写操作闸门、邮件 IMAP 拉取。理由：「模型不可靠」原则只在不可逆/对外/花钱的面上机制强制。

## 6. 成功度量（月度复盘口径）

| 指标 | 现状（09-12 基线） | 目标 |
|---|---|---|
| 深检有效产出/周 | 0（当天全饿死） | ≥3 且零槽位死锁 |
| 孤儿卡平均存活 | ≥3 天 | <2h（死信车道+值班环） |
| 新失败类处置 | 新写一个 bash guard | 值班环捕获归类 ≥80%，guard 新增趋零 |
| 框架特性 upstream offer | — | B 系 3 个 commit 进可 offer 库存 |
| 账本数量 | 7 套 JSON | ≤3（board + approved.log + duty-ledger） |
