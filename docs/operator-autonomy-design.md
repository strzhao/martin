# 值班 agent 分级授权架构设计（A0–A4）

> 状态：**设计稿（未实施）**。本文件只做设计，不改任何产线脚本/配置/skill；用户核实拍板后才进入实施。
> 日期：2026-09-13 ｜ 设计对象：contrib operator（值班 agent，宪法 `~/.hermes/profiles/contrib/skills/github/contrib-operator/SKILL.md`）
> 命题（用户原话）：「现在他的权利是只能修知识。那如果脚本等相关问题的话，我希望给他做一定程度的赋权……我也很担心跟之前一样不停的打补丁，未来维护不住，所以应该全方面先设计好整体的架构跟方案。」
> 读者：用户（拍板人）+ 后续实施者。文中每个断言都带可实查锚（file:line / 命令），**一切状态断言以实查为准**。

---

## 0. TL;DR（结论先行）

**一句话分级**：把「改机制上报」这条类别闸拆成粒度——**A0 只读看 → A1 改知识（现状）→ A2 只许把系统调得更保守（参数/账本）→ A3 修自己的管道代码（受控车道，不直接进产线）→ A4 恒人工（对外/审批链/调度链/凭据/框架/删数据）**。

**命名裁定（推翻任务书的 L0–L4 编号）**：本设计用 **A0–A4**（authority level），不用 L0–L4。理由：本域既有的「L1 全自动 / L2 审批（L2-auto / L2-A / L2-B）」是**对外动作审批分层**的成熟词汇（`contrib-operator` SKILL §1、oss-ops），再引入一套 L0–L4 必然撞名，而两轴恰好正交——对外动作**永远**走审批环，与本分级无关。任务书的 L0–L4 对应关系：A0=L0、A1=L1、A2=L2、A3=L3、A4=L4。

**防补丁熵三机制**：①**修复速率限制 + 三次法则**（A3 ≤2 件/日、≤6 件/周；同一形状的补丁出现第 3 次 → 停修，强制升格为结构改造）②**决策账**（每次 A2/A3 动作一行：级别/对象/why/证据/before→after/回滚法/复核日，未落账的动作视为违规）③**每周巩固冲刺 + Sunset**（同形补丁 ≥3 → 合并成钳夹/参数/枚举并删掉被取代的补丁；每个修复件带 `review_by` 默认 90 天）。

**最大风险点**：**授权的地基是软的**——「gh 只读 / 对外必经 L2」目前**只是 prompt 级红线**，contrib worker 物理上能直接 `gh pr comment`（无 deny、无 hook、`hooks/` 目录为空，见 §1.3a）。在这条地基补硬之前，A2/A3 一律不开。第二风险：**闸门自身可被改**（`auto-gate.sh`/`execute.sh` 无完整性基线），A3 必须把闸门文件列入 immutable 清单 + 哈希守护（fail-closed）。

**不需要动 hermes 框架**：四个实施阶段全在 martin 仓 + 配置层完成。唯一必须动框架的缺口（kanban 停放语义，见 §1.4#2）恒属 A4/上游路。

---

## 1. 现状摸底：哪些是机制强制，哪些靠 prompt 自律

### 1.1 已经「机制强制」的（代码层，模型绕不过）

| # | 机制 | 落点（可实查） | 它保证什么 |
|---|---|---|---|
| M1 | **对外动作唯一通道 = L2 链** | `scripts/approval/execute.sh`（push/开 PR/发评论的唯一执行体）+ `collect.sh` | 提案变现实必须过机械复验（TTL/占坑/refspec） |
| M2 | **L2 自动批准硬条件**（任一不过 → 升级人工） | `scripts/approval/auto-gate.sh:35-102`：总开关 `auto_approve`（:35-40）→ **own-PR 永不自动**（:48-52）→ disposition 白名单 review-evidence/probe-salvage（:54-58）→ score≥`auto_approve_min_score`（:60-66）→ `verdict.json` 必须 decision=auto ∧ high ∧ low（:68-91）→ goods 三态 fail-closed（:93-99） | 模型意见只是输入；硬条件由代码裁决 |
| M3 | **预算钳夹** | `scripts/contrib/rq.sh budget` reserve/refund + `contrib-data/config.json`（`deep_check_per_week:30`、`probe_per_day:1`、`max_alert_pushes_per_day:30`、`notify_min_interval_min:20`） | 超配额 = 硬拒（09-13 实证：W37 30/30 → 一律 `DENY week-limit`） |
| M4 | **心跳调度** | hermes cron `:02` → `~/.hermes/scripts/contrib-heartbeat.sh`（真源 `scripts/contrib/heartbeat.sh`）；幂等键 `shift-YYYYMMDD-HH` + `--resources shift:contrib` 单飞（:21-32） | 每小时必有一班；重跑同小时返回已有卡；上一班未收工则排队 |
| M5 | **coder lane 工具级 deny** | `--disallowedTools "Bash(git push*)" "Bash(gh pr *)" "Bash(gh api *)" "Bash(gh release *)"`（`hermes-lane-protocol.md:170`；claude-run SKILL §④） | 引擎物理上没有 push/PR 能力（不是「不应该用」而是「用不了」） |
| M6 | **kanban 写围栏（两个）** | ①CLI 写动词在 worker 上下文被硬拒（`kanban.py:214-226` denied 集；原文 `delegate_task child contexts cannot mutate Kanban tasks via the CLI`）②kernel worker 作用域拒跨卡终态（`worker is scoped to task <本卡>`） | 派单 worker 改不了别人和自己的终态（09-13 两班实证） |
| M7 | **台账单写方** | `inventory.json` 唯一写入口 = `scripts/contrib/forge.sh`；`approved.log` 只读；`budget.json` 唯一写入口 = `rq.sh` | 并发写不会互相覆盖 |
| M8 | **枚举强制（同时是缺口来源）** | `forge.sh:144` 只收 `ready\|stale\|in-flight\|spent\|needs-decision` | 状态机闭合，但漂移时无法如实登记（见 §1.4#3） |

### 1.2 靠「prompt 自律」的（软契约，错了只是行为不优雅，机制不拦）

| # | 软契约 | 现状证据 | 风险 |
|---|---|---|---|
| S1 | **gh 只读（零写）** | `contrib-operator` SKILL §7 红线速查；contrib profile `hooks/` 目录为空（0 文件）、config.yaml 无 `approvals.deny`、toolsets 含 `hermes-cli`（terminal 可用） | **最高**：所有「对外必经 L2」的地基 |
| S2 | **forge.sh 只到本地、绝不 push** | 脚本内无 push；靠 SKILL 红线 + forge.sh 头注释 | 中（与 M5 不同，contrib 侧无工具级 deny） |
| S3 | **改机制上报（draft 卡等人）** | SKILL §1 权限类别闸；09-13 实证 operator 遇 5 个缺口**全部**只落 `[draft]` 卡、零动手 | 中（本次设计要拆的正是它） |
| S4 | 品牌姿态红线 / 评分纪律 / 三路分诊 / 判断必落卡 | SKILL §1/§3/§0 | 低（人可见 + 事后审计） |
| S5 | **[watch] 到期巡检自担** | SKILL §4.1（钳夹自身读取会静默失败，巡检不可省） | 中（靠人记得查） |

### 1.3 摸底结论：三处结构性弱点

**(a) 层级错位：最该硬的约束最软。** 不可逆、影响品牌资产的对外动作（S1/S2）是 prompt 级；而「本域内部可逆的研判动作」反倒有 M4/M6 之类的机制围栏。地基软 → 上面盖任何授权都悬空。

**(b) 类别闸无粒度。** SKILL §1 的闸门是**类别**判定（「对外」「花钱」「新动作类型」「改机制」），没有**量级**维度。于是「`?mode=ro` → `?immutable=1` 一行级修复」与「改 kanban 停放语义」被判成同一类，都只能上报等人。09-13 的 5 个缺口里 3 个是机制层，其中 2 个是一行级——**不是不判，是没档位可判**。

**(c) 钳夹无自护。** 设计宪法写明「钳夹三律：失败语义显式保守 / 无状态 / 永不长大」，但**没有第四条：钳夹不可自改**。gate 文件（`approval/*`）没有完整性基线，谁改都无声。

### 1.4 今天的 5 个真实缺口 → 对号入座（最好的设计素材）

来源：`contrib-data/ops-journal.md` 2026-09-13 各行。

| # | 缺口 | 层 | 形状 | 本设计里的档位 |
|---|---|---|---|---|
| 1 | 到期钳夹竞态 + `watch-due:` 解析脆弱（`heartbeat.sh:41-44`：`?mode=ro` 在 WAL 静止态 rc=14 且被 `2>/dev/null \|\| true` 吞掉；`instr(...)+11,10` 窗口遇双空格/散文复述即误判） | 机制（读取/解析） | **一行级、可逆、可测、爆炸半径=唤醒准确度** | **A3**（甜区；改法需真库只读对拍） |
| 2 | 停放机制被 kernel 提前派发（`initial_status=blocked` → 25s/10s 即 promote；`scheduled` 是终止性停放、到点不自醒，`kanban_db.py:3767-3790`） | 机制（框架/调度语义） | 需动 hermes kernel 或新增时间字段 | **A4**（恒人工；走上游路） |
| 3 | `inventory.json` 缺「载体已死」终态（`forge.sh:144` 枚举） | 机制（数据枚举） | **一行级**（加 `dead`）、可逆 | **A2/A3 边界**（改枚举值属 A3；改语义分列规则属 policy → A2 需人拍一次） |
| 4 | 台账假阳性「in-flight ≠ 有货」（7 条零提交空壳） | 知识 | 已自愈（SKILL §3.2 新增实查口径） | A1（已行使） |
| 5 | `watch-due:` 机器行必须写在 comment 而非 body | 知识 | 已自愈（SKILL §4.1 补契约） | A1（已行使） |

**这行表最重要的一句话**：若当时有 A2/A3，正确动作数 = **2 个补丁（#1 一行、#3 一行）+ 1 个人工拍板（#2）+ 2 次零动作（#4#5 本来就该由知识层吸收）**；现实动作数 = 0 个补丁 + 5 张等待的 draft 卡 + 每班重复巡检。缺的不是判断力，是**档位**。

---

## 2. 最佳实践调研（每条说清「它解决了什么 / 我们借什么」）

### 2.1 SRE 自动修复分级：判据 = 可逆性 × 爆炸半径

来源：devsecops.ae《Agentic SRE Governance: How Far Should Autonomous Remediation Go?》（2026-08-06）。其分级表（摘）：

| 动作 | 可逆性/半径 | 判定 |
|---|---|---|
| restart pod / scale-up / clear cache / re-run idempotent job | 可逆、极小 | **auto-execute** |
| roll back a recent deploy / restart DB node / scale-down | 可逆但中等 | **execute with approval** |
| regional failover / schema migration / **data deletion** / **secrets rotation** | 不可逆、大 | **human-only** |

同文给的治理六件套，句句打在我们要害上：**least-privilege credentials（"scope the token, not the trust"）/ guardrail policies（policy-as-code，不是 prompt——"not a prompt instruction the model can talk itself around"）/ blast-radius limits / change windows / approval gates（记录谁在何时批了什么）/ rollback + kill-switch**。并明确：**权限凭证据晋级，不凭乐观**（"they graduate on evidence, not optimism"）。

- **解决什么**：给「什么可以自动」一个与模型无关的判据，避免按动作清单枚举（清单永远漏）。
- **我们借**：①判据用「可逆性 × 爆炸半径」（对应我们的三问：回滚可行吗、影响几个文件/几个班、错多久能发现）；②**只读凭据 = 最硬机制**（把 gh 写权限从 contrib 身份上摘掉，比任何 deny 列表都稳）；③kill-switch 必须常备且一行可执行。

### 2.2 成熟度谱 + 「先自动化退出，再自动化修复」

来源：CI/CD Auto-Remediation Maturity Spectrum（CARM，dev.to/arvoai 2026）：L0 人工 → L1 自动回滚 → L2 回滚+诊断 → **L3 回滚+诊断+修复（"agent proposes — or in some cases applies — a fix"，人 review/merge）** → L4 闭环+策略闸。tianpan.co《Self-Healing Agents in Production》给的落地次序更狠：**"Before you automate fixes, automate rollbacks."**；配套「rings（渐进环）+ 前后基线 + pause point」。

- **解决什么**：防止把「生成修复」放到「能安全回退」之前——那正是补丁熵的引爆器。
- **我们借**：①**先证明回滚可机械执行，再开自动修复**（我们的 A3 必须先做一次回滚演练，见 §6 P3 验收）；②**rings**：A3 的射程先只覆盖 contrib 域自家脚本（错也只错在自家管道，不碰上游/对外）；③**pause point**：apply 后留观察窗，窗内不叠加同类修复。

### 2.3 Claude Code 权限分层：deny > ask > allow，且必须落在 harness

来源：Claude Code 官方 permissions / permission-modes / hooks 文档。三条硬事实：**「Permission rules are enforced by Claude Code, not by the model. Instructions in your prompt or CLAUDE.md shape what Claude tries to do, but they don't change what Claude Code allows.」**；规则序 **deny → ask → allow，首个命中生效，deny 在任意层级不可被 allow 覆盖**；**hook 可收紧不可放松，且只应作 escape hatch——用 hook 做 permission gate 是反模式**（失败语义是 `non_blocking_error`，不可靠；见 `harness-engineering-principles.md` 反模式 #2）。

hermes 的对应件（已实查，见 §1.3 证据）：`tools/approval_floors.py:23-55` 的 **`approvals.deny` glob = 硬地板**——注释原文「User-defined fnmatch globs that block unconditionally … a match fires BEFORE the yolo / mode=off bypass」，即**在 `--yolo`/`mode: off` 之下也拦得住，agent 说服不了自己**；文档 `website/docs/user-guide/security.md:33-39` 另有 `approvals.cron_mode / single_query_mode / unattended_mode`（无人值守会话的危险命令默认 deny）。\n
- **解决什么**：证明「prompt 级约束在任何注入/催促下都会被绕过」，因此安全必须落在不可协商的层。
- **我们借**：①S1/S2 的硬化落点 = **contrib profile 的 `approvals.deny`**（既有机制，纯配置，零框架改动）；②分工不变：prompt（skill）负责协作与教化，机制负责安全；③**不用 hook 做 gate**。

### 2.4 Kubernetes operator：level-triggered reconcile，幂等收敛

来源：Kubernetes 官方 *Operator pattern* 文档（"Operators follow Kubernetes principles, notably the **control loop**"；核心是"code to tell the API server **how to make reality match the configured resources**"），以及 controller 的 level-triggered 语义（看**当前状态**而非事件）。

- **解决什么**：把「系统该长什么样」写成声明式期望，让代码每轮对账并收敛 drift——而不是等人读日志发现某脚本悄悄坏了。
- **我们借**：①**把「机制健康」也变成声明式对账**：每班对 `gate-baseline.sha256`、关键脚本存在性、判据文件在位性做一次 reconcile，drift 即告警——今天的钳夹静默失败正是「无 reconcile」的直接后果；②**幂等**：所有 A2/A3 动作必须可重复执行而无副作用（我们已有的 `.bak` + 原子写 + 幂等键就是这个形状）；③**无状态**：状态只在账本/看板（钳夹三律第 2 条）。

### 2.5 自治级别框架：批准可以发生在更高抽象层；晋级凭证据

来源：Cloud Security Alliance《Autonomy Levels for Agentic AI》（2026，六级：L0 人执行 / L1 辅助 / **L2 监督=批「计划/批次」而非批每条动作** / L3 边界内自主 / L4 高自主=监控+异常介入 / L5 完全自主）；arXiv 2506.12469《Levels of Autonomy for AI Agents》（用户角色视角：Operator→Collaborator→Consultant→Approver→Observer，"autonomy as a design decision that does not need to be tightly coupled with agent capability"）。

- **解决什么**：证明「放权」不必是逐动作审批，可以**在更高抽象层批准**（批一类动作的边界条件），既省人力又不失控。
- **我们借**：①本设计的形态就是「**批边界**而不是批每件事」：用户批一次 `A3 白名单 + 六道闸`，之后每件修复不必再问；②**晋级凭证据**：每个阶段都有可验的晋/降条件（§3.7）；③**"autonomy ≠ capability"**：权限设计与模型能力解耦——能力更强不等于该给更大权限。

---

## 3. 分级授权模型（A0–A4）

### 3.0 两条正交轴（先说清命名，避免误读）

```
轴一：对外动作审批（既有，不变）
  L1 全自动 → L2 审批环（L2-auto 确定闸 / L2-A 微信批 / L2-B 会话明示）
  ↑ 永远存在。任何 A 级升高都不豁免它。gh 写/push/PR/评论/发版 恒走这里。

轴二：内部机制改动授权（本设计新增）
  A0 观察 → A1 知识自修 → A2 配置/账本面 → A3 代码修复（受控车道） → A4 恒人工
  ↑ 只覆盖「本域自己的运行管道」，不覆盖对外动作。
```

**一句话**：A3 不是「能 push 了」，A3 是「能修自己的脚本了（在车道里）」。

### 3.1 A0 观察（现状保留）
只读：survey（看板/gh/邮件）、读台账/日志/源码、写 journal 四行与卡。零写权限。这是每级的底座，永久保留。

### 3.2 A1 知识自修（现状已行使，但补两条不变量）
可做：改 skill 正文/口径/判例、写 `ops-journal`、建/改 `watch-*.json` 判据、更新 `absorb-ledger`。
**新增不变量（机制强制）**：
- **A1-1 知识层不得自我扩权**：skill 中任何**权限相关条款**（红线清单、类别闸、可做/不可做清单、白名单）的变更 = A4。理由：agent 改自己的指令 = 自我授权，是天生的越权通道。
- **A1-2 知识层变更可审计**：权限相关行的 diff 由每周 auditor（fresh context）逐条对照本文件 §3.7 校验；发现放宽 → 回退 + 记 incident。

### 3.3 A2 配置面与账本面（新增；纯值调整，单向保守）

**A2-a 参数调值**：只允许**把系统调得更保守**；任何放松 = A4。

| 参数（`contrib-data/config.json`） | 允许方向 | 边界 |
|---|---|---|
| `max_alert_pushes_per_day` / `own_pr_alert_per_day` | ↓ | ≥1 |
| `notify_min_interval_min` | ↑ | ≤1440 |
| `deep_check_per_day` / `deep_check_per_week` | ↓ | ≥0 |
| `probe_per_day` / `max_auto_builds_per_day` | ↓ | ≥0 |
| `stale_pr_days` / `approval_ttl_hours` | ↓ | ≥1 / ≥1 |
| `auto_approve_min_score` / `ready_min_score` / `min_build_score` | ↑ | ≤15 |
| `notify_dry_run` | false→true | — |
| **永不可 A2** | — | `auto_approve`（总开关）、`allow_own_pr_push`、`notify_target`、`repo`、`refund_failed_deep_check`、任何额度**上调** |

机制强制：`config-clamp`（新增小钳夹，A3 车道的一部分）：读方向表 → 对 `(key, old, new)` 判方向 → 越界/反向 **拒绝并告警**（fail-closed）；通过则原子写 + 备份 + 落决策账。**每班 ≤1 项、每周 ≤3 项**配置变更（变更预算）。

**A2-b 账本/数据修复**：对**可再生的运行数据**做恢复性写回。
- 允许：`scan-cursor`/`mail-cursor`/`own-pr-watch-snapshot` 游标修正、`pending-batches/*` state 写回（53 done / 22 skip 那类）、`watch-*.json` 判据落盘、`card-bodies/*`。
- 条件（五个全过）：①**`.bak-<ts>` 先备份** ②幂等（重跑同结果）③**不碰单写方台账**（`approved.log` / `budget.json` / `inventory.json` / `ready-queue` 状态机 / L2 链态项）④**写回后同口径自证**（用产生该数据的同一 jq/口径复核，判"去重 0 / 损坏 0"）⑤落决策账。
- **已有判例**：09-13 13:12 operator 自决写回 8 个批次文件（逐文件 `.bak-20260913-13` 备份 + scan_gate 同款 jq 复核）。这件事**事实上已经越了当时的类别闸**——本设计把它**事后入册**为 A2-b，并补上⑤（当时缺决策账）。

### 3.4 A3 代码修复（受控车道；本次赋权的主体）

**核心裁定：A3 不让 operator 直接改文件，而是让它「立项 + 走车道」。** 理由：本域已有成熟的质量机件（coder lane 的 autopilot 红蓝队 / plan-reviewer / QA 波次 / mutation 自证），绕过它们直接改 = 废掉质量根（claude-run SKILL 红线 7 的同款逻辑）。所以：

```
operator 发现机制缺口
  → 建 pipeline-fix 卡（模板化：缺口/证据锚/最小修法/回滚法/验收判据）
  → coder lane 产：worktree 分支 pipefix/<slug> + commit + mutation 自证 + 测试绿 + 真库对拍
  → l3_apply 六道机械闸（下）
  → apply（备份 + 可回滚）→ 观察窗 2 班 → 落决策账 / 或回滚
```

**六道闸（全部 fail-closed：任一不过 → 拒绝 + 告警，绝不"变通"、绝不重试绕行）**

| 闸 | 判据 | 为什么 |
|---|---|---|
| G1 **分支隔离** | 修复永远在 martin worktree 分支 `pipefix/<slug>`；产线跑主 checkout ⇒ **零直接生效** | 可逆性的根；对应调研 §2.2 rings |
| G2 **路径白名单 + immutable 哈希** | 允许：`scripts/contrib/*.sh`（除下方 immutable）、`scripts/contrib/tests/**`、`martin/*.md`（非权限条款）。**immutable（硬拒）**：`scripts/approval/**`、`scripts/contrib/l2_ledger.sh`、`heartbeat.sh` 的调度/失败语义段、`contrib-data/{approved.log,budget.json,inventory.json}`、`~/.hermes/scripts/**`、`~/.hermes/profiles/*/config.yaml`、cron/launchd 定义、任何 skill 目录。apply 前校验 `gate-baseline.sha256`：闸门文件哈希变了 → 拒 | 回答「闸门自己被改怎么办」；回答「agent 给自己写权限」 |
| G3 **diff 规模上限** | ≤80 行 ∧ ≤3 文件；超限 → 拒并转人工（A4） | 强制单关注点；把"大改"逼回人的视野 |
| G4 **测试闸** | `scripts/contrib/tests/run.sh` 全绿 + 该脚本 acceptance 绿 + mutation 自证文件在位（改一处判据必须转红、还原后转绿、`git status --porcelain` 归零） | 防"空心断言"（09-13 实证：mutation 后仍绿 = 断言与判据无关） |
| G5 **行为面取证** | 真库/真环境**只读对拍**：同一份真实数据上跑旧/新逻辑，输出差异可见（如 `?mode=ro` vs `?immutable=1` 在同一 board 库上的 rc 对照） | 防"能过测试但语义错误"；mutation 只证明判据相关，行为面另证 |
| G6 **apply 契约** | ①`.bak-<ts>` 备份 ②记录 before-sha ③`pipefix rollback <id>` 可机械执行 ④决策账一行 ⑤观察窗 2 班（窗内不叠加同类修复）⑥**回滚演练先于首次自动 apply** | "先自动化退出，再自动化修复"（§2.2） |

**A3 不含**：改对外行为（评分判定/出手条件/品牌口径）、改任何 A4 面、多关注点重构、新增/删除 `kanban` 写动词、把 `scheduled`/`blocked` 语义改动。

**A3 需要升级的情形（半自动闸）**：diff 触及 `heartbeat.sh` 时，除六道闸外，diff 必须以 `# A3:<id> <date>` 标记且附**真库只读对拍证据**（旧/新 SQL 同库结果对照）。**A2/A3 边界**：改「枚举值」（如给 `forge.sh:144` 加 `dead`）属 A3；改「该枚举所承载的语义分列规则」（如 `dead` 与 `spent` 必须分列）属 policy → 需人拍**一次**成原则，之后同类按原则执行。

### 3.5 A4 恒人工红线（永不下放，与 A 级无关）

| 类别 | 具体 | 由谁执行 |
|---|---|---|
| 对外动作 | gh 写 / push / PR / release / 评论 / 发版 | **永远 L2 审批环**（与本分级正交） |
| 审批链自身 | `scripts/approval/**`（含 `auto-gate.sh`/`execute.sh`/`ttl_comment_judge.sh`）、`l2_ledger.sh`、`approved.log` | 人 |
| 调度链 | `heartbeat.sh` 的调度/失败语义段、cron job 定义、launchd plist、`~/.hermes/scripts/**` 的部署动作 | 人 |
| 凭据 | `.env`、Keychain、vault、任何 token 的发放/替换 | 人（AI 只起草） |
| 账本 | `budget.json` 的额度与退款、`inventory.json` 的单写方改写、删任何账本 | 人 / 单写方脚本 |
| 配置的**放松方向** | `auto_approve`、`allow_own_pr_push`、任何额度上调、`notify_target` 变更 | 人 |
| hermes 框架 | `~/workspace/hermes-agent/**`（含 kanban 停放语义 #2）——走上游 issue/PR 路 | 人 + 上游 |
| 删数据 | 邮件、session、台账、批量文件删除 | 人 |
| 全新动作类型 | 无先例（升格制：人批一次成原则） | 人 |
| 知识层的权限条款 | skill 中红线/闸门/白名单行 | 人 |
| A3 超限件 | diff 超 G3、改动语义/policy、不可回滚 | 人 |

### 3.6 每级四问（能做什么 / 怎么机制强制 / 失败怎么回滚 / 出事怎么追责）

| | **A0 观察** | **A1 知识自修** | **A2 配置/账本** | **A3 代码修复** | **A4 红线** |
|---|---|---|---|---|---|
| **能做** | 读一切（看板/gh 只读/台账/源码/邮件），写 journal 与卡 | 改 skill 正文/口径/判例、写判据文件、台账（非单写方） | 保守方向调参、可再生运行数据恢复性写回 | 立项 + 走车道修本域脚本/测试/文档 | —（人做） |
| **机制强制** | 无（只读天然安全）；**唯一新增**：`approvals.deny` 硬地板挡住 gh 写/push（§6 P0） | A1-1 权限条款属 A4 + auditor 周检 diff | `config-clamp` 方向表（fail-closed）+ 单写方台账隔离 + 变更预算 | G1 分支隔离 + G2 白名单/immutable 哈希 + G3 规模上限 + G4 测试/mutation + G5 对拍 + G6 apply 契约 | 路径不在任何白名单；哈希基线校验 fail-closed |
| **失败回滚** | — | 回退 skill 版本（git）；判例只增不改历史 | `.bak` 还原一行；`operator_autonomy_level` 降级 | `.bak-<ts>` + `pipefix rollback <id>`（before-sha）；分支丢弃零成本 | —（人决策） |
| **追责** | journal 四行 | journal + auditor 周检 | **决策账**一行 + 变更台账 | **决策账**一行（含 diff sha、测试证据、对拍证据、回滚法、`review_by`） | 审批环本身即台账（谁/何时/批了什么） |

### 3.7 升降级规则（棘轮：自动降、人工升）

- **升级凭证据，不凭乐观**：每阶段有晋/降条件（§6 各阶段验收）；首次进入任一级都由**人拍一次**。
- **自动降级（机制执行，不需同意）**：①A3 连续 2 次回滚 → 自动降 A1 + 冻结 A2/A3 七日 + 告警；②任一**不可回滚**事故 → 立即降 A0 + 全量冻结至人工复核；③gate 哈希漂移 → 立即冻结 A3 + 告警。
- **一键 kill-switch**：`config.operator_autonomy_level: 0`（单值降级，全部回 A0）+ 环境变量硬关 `PIPELINE_FIX_DISABLE=1`（车道直接拒跑）。二者独立，任一命中即停。
- **越权企图是资产**：被 deny 拦下的尝试必须入月报（它暴露了模型想干什么），而不是被静默吞掉。

---

## 4. 防补丁熵专章：自动修复积累 100 个之后还维护得住吗？

### 4.1 先诊断：熵的真实来源不是「数量」，是三处机制缺失

| 熵源 | 机理 | 本域实证 |
|---|---|---|
| **无收敛压力** | 每个缺口打一个补丁，补丁散落在各脚本里，单位维护成本不降反升；只有**补丁收敛成结构**（钳夹/参数/枚举）才降低长期成本 | `run-watch.sh` 38429 字节、5 段骨架，最终只能整体退役（09-13 13:11 实证）；设计宪法已定「**永不长大**」钳夹三律，但没有执行它的周期动作 |
| **无退出机制** | 修复件只增不减；退役清单长期挂账 | `forge` 12 条分支里 **7 条零提交空壳**（立项 2.2–3.5 天）——「立项欠账」；run-watch/scan_gate/mail_gate/deepcheck 族已停搏但代码留存待 E 波删除 |
| **无速率上限** | 变更风暴 → 回归定位成本指数上升（change failure rate↑）；且修复本身成为新的缺口来源 | 09-13 一天就有 5 个机制缺口被识别；若无上限，每个都修 = 5 个新补丁 |

**关键判断**：今天 5 个缺口里 2 个由知识层自愈（#4#5）、2 个一行级（#1#3）、1 个框架级（#2）——**正确的动作数远小于缺口的数量**。熵的对手不是"少发现缺口"，而是"把发现收敛成更少的动作"。

### 4.2 机制一：修复速率限制（change budget）+ 三次法则

- A3：**≤2 件/日 ∧ ≤6 件/周**（A2 配置变更 ≤1 项/班 ∧ ≤3 项/周）。超限 → 拒（不是排队：排队会在下个窗爆量）。
- **三次法则（本设计的核心反熵条款）**：**同一形状的补丁第 3 次出现 → 禁止继续打补丁**，强制升格为结构改造（抽成钳夹/参数/枚举/表驱动），并把前两次补丁合并删除。理由：三处同形补丁 = 一个缺失的抽象。
- 与其配套的**补丁形状指纹**：决策账里每个修复件带 `shape:` 字段（如 `sqlite-read-path`、`token-window-parse`、`status-enum`）。同 `shape` 计数由机械脚本统计，不靠人记。

### 4.3 机制二：决策账（decision ledger）+ 回滚契约

`contrib-data/decision-ledger.jsonl`，append-only，每行 = 一次 A2/A3 动作：

```json
{"ts":"...","level":"A3","shape":"sqlite-read-path","target":"scripts/contrib/heartbeat.sh",
 "why":"watch-due 钳夹在 WAL 静止态静默失败","decision_reason":{"type":"mechanism-defect","evidence":"journal 09-13 14:13/15:06 两行",
 "before_sha":"...","after_sha":"...","rollback":"pipefix rollback pf-20260913-01","review_by":"2026-12-12",
 "gates":{"G1":"pass","G2":"pass","G3":"pass","G4":"pass","G5":"pass","G6":"pass"}}}
```

- **未落账的动作视为违规**（auditor 抽检：比对脚本 mtime / git log 与 ledger，缺一即 incident）。
- **`review_by` 默认 90 天**：到期未证明仍必要 → **删除**（Sunset）。修复件是负债，不是资产。
- 只记 A2/A3；A0/A1 沿用 journal 四行（避免账本通胀，见 §5.6）。

### 4.4 机制三：每周巩固冲刺（consolidation sprint）+ Sunset

作为 auditor 周检的**固定议程**（每周一次，30 分钟）：
1. 扫决策账 → 按 `shape` 分桶，找 **≥3 次同形** → 合并成结构，删被取代的补丁（产出一张 A3 卡）。
2. 扫 `review_by` 到期件 → 逐个判「删/留/降级」，删除优先。
3. 扫退役清单 → 删已停搏的代码（run-watch 族待删是现成任务）。
4. 出**补丁熵报表**三个数：**新增 / 收敛 / 删除**。

### 4.5 回答「100 个之后」

设 N = 累计修复件数，S = 结构性件数，则维护成本 ~ O(脚本总行数) 而不是 O(N)。
- 若速率限制 + 每周冲刺运转：100 次修复预期收敛成 **<20 个结构件**，且**脚本总行数不随 N 单调增长**（这是可测量的硬指标）。
- 若无收敛动作：100 个散补丁 ⇒ 维护不住。**这不是预测，已有实证**——`run-watch` 就是这个过程的产物：每个缺口加一段，最后 38KB/5 段只能整体退役。

**判据（写进月度成功度量）**：
| 指标 | 基线（09-13） | 目标 |
|---|---|---|
| `scripts/contrib/*.sh` 总行数 | ~250KB 级（16+ 文件） | **不随修复数单调增长**（每季度净增 ≤0 才算健康） |
| 补丁/结构比 | 无（无账本） | ≤ 5:1（每 5 个补丁至少 1 个结构件） |
| 同形补丁最大计数 | 无观测 | ≤2（第 3 次即触发升格） |
| `review_by` 过期未处理件 | 无观测 | 0 |

**早期预警信号（命中任一 → 停修，强制转结构改造）**：
1. 同一文件被 **3 个不同修复**碰过；
2. 修一个缺口要**同时改 ≥2 个脚本**；
3. 理解一处修复需要**读 ≥3 个文件**。

---

## 5. 风险与反方意见

### 5.1 【最高】授权盖在软地基上
S1（gh 只读）是 prompt 级：contrib worker 物理上能 `gh pr comment`。若 A2/A3 在这种地基上开放，被注入/误判导致的对外动作将绕过整个审批环。
→ **硬前置（phase gate）**：§6 P0 未完成，A2/A3 不开放。落点首选 **凭据分离**（只读 token 给 contrib worker；写 token 只存在于 `execute.sh` 的 env）——「scope the token, not the trust」，比黑名单稳；次选 `approvals.deny` glob（既有硬地板机制）。

### 5.2 L3 车道的测试覆盖不足 ⇒ 虚假安全感
`scripts/contrib/tests/` 有 detect probes + unit + acceptance，但覆盖不全；G4「测试绿」不等于语义对。
→ 三道补丁：①**行为面取证**（G5，真库只读对拍，输出差异必须可见）②**mutation 自证**（防空心断言，09-13 `t_582e238b` 实证：mutation 后仍绿 = 断言与判据无关）③**A3 只允许单关注点**（G3 规模上限逼出来）。**门是必要不充分**，所以还有 G6 观察窗 + 回滚。

### 5.3 闸门自身被改 ⇒ 一切归零
`auto-gate.sh`/`execute.sh` 无完整性基线；若 A3 能把闸门改宽，A3 就变成了无限权限。
→ 机制：①闸门文件进 immutable 清单（G2 硬拒）②`contrib-data/gate-baseline.sha256` 哈希基线，**每次 apply 前校验**，漂移 → 拒 + 冻结 A3 + 告警 ③基线文件本身在 G2 白名单之外（改它同样是 A4）。这条同时补上了设计宪法缺失的「钳夹不可自改」第四律。

### 5.4 「能过测试但语义错误」的修复
测试断言的是**已经写下的契约**；语义错误恰恰在契约没写到的部分。
→ 四道防线：①**红队**（fresh-context verifier 卡，swarm 形态已有）②**爆炸半径限制**（A3 只覆盖 contrib 域自家脚本，错也只错在自家管道，不触上游/对外/资金）③**观察窗**（apply 后 2 班内不叠加同类修复）④**语义类变更降级**：改动对外行为、评分判定、出手条件任一 → 不是 A3，是 A4（那是 policy，不是 mechanism）。

### 5.5 operator 自我扩张（A1 知识 + A3 代码 = 给自己写权限）
→ ①skill 权限条款 = A4（A1-1）②A3 白名单**不含 skill 目录**（skill 改动走独立通道）③auditor 用 fresh context 每周 diff 权限相关行（A1-2）④**自动降级不可逆**（§3.7）。

### 5.6 观察层通胀（留痕变成噪音）
今天的量级：`ops-journal.md` 34KB、`duty-ledger.md` 23KB、`ledger.md` 337KB。
→ ①决策账只记 A2/A3（量小）②journal 保持四行、"无事可做"不进决策账 ③月度归档压缩 ④`ledger.md` 这类历史账本在 E 波随退役清单一起瘦身。

### 5.7 反方意见（诚实的，必须写在纸面上）

**「这件事可能不该做」的论证**：
1. 今天 operator「不动手」**并未造成可测的损失**：5 个缺口里 2 个知识自愈；剩下 3 个只阻塞了「watch 唤醒准确度」与「库存枚举如实性」，KPI（进仓 commit）未受损。
2. 每加一层自动修复机制，就多一层**需要维护的机制**——机制自身的维护成本可能超过它修的问题（这正是用户担心的补丁熵，只是换到了元层）。
3. 最省事的替代方案 = **提高人工响应速度**（draft 卡现在要等用户看微信），而不是放权。

**我的裁断**：
- 替代方案 3 **不成立**——用户已明确「不做具体事的 CEO」，且 A3 的价值不是省下那几分钟，而是**让修复能在没有人值班的时段自然发生**（09-13 的 5 个缺口全部发生在无人时段）。
- 风险 2 **成立，且是本设计要防的头号对象**——所以三个反熵机制（速率/账本/收敛冲刺）不是配菜，是**前置条件**：没有它们，这个设计不该上。
- 因此**范围必须最小**：首次只开 A2 + A3 的「读取/解析类修复」，射程只到 contrib 域自家脚本，前两周 shadow（只产分支不 apply），第三周 apply 需人工点一次，第四周起（若零回滚）才自动。若四周内出现任一不可回滚事故 → 回 A0 重新设计。

---

## 6. 分阶段实施路线

> 原则：**每阶段都以「可一行回退」为入口条件**；每阶段先 shadow、再 assisted、最后 bounded auto（调研 §2.2 rings）。

| 阶段 | 内容 | 性质 | 回退方案 | 验收（可机械验证） |
|---|---|---|---|---|
| **P0 地基**（前置，不做则 P1+ 免谈） | ①**凭据分离**：contrib worker 用只读 GitHub token，写 token 只存在于 `execute.sh` env（首选）；②兜底：contrib profile `approvals.deny` 加 glob（`gh pr create*`/`gh pr comment*`/`gh pr merge*`/`gh api*-X*POST*` 等写动词、`git push*`、`gh release*`）；③`gate-baseline.sha256` 哈希基线 + 只读校验脚本；④`decision-ledger.jsonl` + 契约文档 | **纯配置 + 两个小脚本**（不动 hermes 框架） | 删 deny 条目 / 还原 `.env`；删除基线文件 | 在 contrib worker 会话里实跑 `gh pr comment` → 被拒并留**可 grep 的拒绝语**；篡改 gate 副本 → 校验脚本报红 |
| **P1 A2 开启** | 参数方向表 + `config-clamp` 钳夹 + 变更预算（≤1 项/班）+ 决策账接入；A2-b 数据写回流程入册（补 `.bak` + 同口径自证 + 落账） | 纯配置 + 一个小脚本 | `operator_autonomy_level: 0` + `.bak` 还原参数 | 一次「收紧」变更经 clamp 通过并落账；一次「放松」变更被 clamp **拒绝** |
| **P2 A3 shadow** | `pipeline-fix` 车道（martin worktree + coder lane 模板）+ `l3_apply.sh` 六道闸；**apply 必须人工点一次** | 动 martin 仓（不动 hermes） | 停建卡 + 删车道脚本 | ≥3 件修复走完整链（分支/测试/mutation/对拍/备份），**0 件直接生效** |
| **P3 A3 assisted** | apply 自动执行（日 ≤2 件）；观察窗 2 班；**回滚演练先于首次自动 apply** | 动 martin 仓 | 同上 + 冻结 7 日 | 首件自动 apply 后 `pipefix rollback <id>` **实跑成功一次**（机械可执行，非口头） |
| **P4 bounded auto + 反熵** | 自动 apply 常态化 + 每周巩固冲刺（消同形/清 Sunset/出「新增/收敛/删除」三数报表）+ 月度 auditor 出「动作/回滚/降级/越权企图」四数 | 动 martin 仓 + 周期任务 | 降级开关 | 首次冲刺产出三数 + **至少 1 个同形补丁被合并成结构** |
| **永不做** | §3.5 A4 全表（框架/审批链/调度链/凭据/账本/对外/删数据/全新动作类型） | — | — | — |

**要不要动 hermes 框架？答：四个阶段都不需要。** 全部落在 martin 仓 + 配置层。唯一必须动框架的缺口（kanban 停放语义，§1.4#2）恒属 A4，且它的正路是走上游 issue/PR 而不是本地改。

---

## 7. 待用户拍板的点（我定不了的点）

1. **命名**：是否接受用 **A0–A4** 取代任务书的 L0–L4（避与既有 L1/L2 审批分层撞名）？（我的建议：接受）
2. **配称（P0 取证方向）**：对外动作硬化走 **只读 token（首选，最硬）** 还是 `approvals.deny` glob（最小改动）？前者需要用户操作 GitHub 侧凭据，后者纯本地。
3. **A2 的方向表裁量**：我采用「**只能更保守，任何放松 = A4**」的单调约束，代价是某些合理的放松（如临时调大告警额度）也要问人。是否接受这条严格性？
4. **射程**：A3 只覆盖 `contrib` 域自家脚本（martin/scripts/contrib + contrib-data），**不含** `hermes-agent` 仓、不含其他域（hkstock/dianping）脚本。是否同意先只开这一个域？
5. **`forge.sh:144` 加 `dead` 枚举**（§1.4#3）：改枚举值我可以走 A3；但「`dead` 与 `spent` 必须分列」是 policy，需要你拍一次成原则。
6. **是否现在就把 `INDEX.md` 登记**（本文件按仓规需在 INDEX 登记，但那属于改仓文档，本卡红线只允许落盘设计稿）——建议由交互会话补登记。

---

## 附录 A — 证据锚清单（全部可现场复验）

| 断言 | 锚 |
|---|---|
| L2 自动批准硬条件（own-PR 永不自动等） | `scripts/approval/auto-gate.sh:35-102` |
| 对外动作唯一通道 | `scripts/approval/execute.sh`；`scripts/approval/collect.sh` |
| 预算钳夹与配额 | `scripts/contrib/rq.sh budget`；`contrib-data/config.json` |
| 心跳与单飞 | `scripts/contrib/heartbeat.sh:21-32` |
| 到期钳夹的两处脆弱（读取 + 解析） | `scripts/contrib/heartbeat.sh:37-51`（SQL 在 41-44） |
| coder lane 工具级 deny | `hermes-lane-protocol.md:170`；claude-run SKILL §④ |
| kanban 写围栏 | 09-13 journal 行（源码 `kanban.py:214-226`、`kanban_db.py:121-136`） |
| `approvals.deny` 是硬地板（yolo 之下也拦） | `tools/approval_floors.py:23-55`；`website/docs/user-guide/security.md:33-39` |
| 「prompt 改不了权限」原则 | Claude Code permissions 文档；`harness-engineering-principles.md:27-30`、反模式 #1/#2 |
| 可逆性 × 爆炸半径分级 + 治理六件套 | devsecops.ae《Agentic SRE Governance》2026-08-06 |
| 「先自动化回滚，再自动化修复」 | tianpan.co《Self-Healing Agents in Production》 |
| 成熟度谱（L0–L4 修复级） | CI/CD Auto-Remediation Maturity Spectrum（dev.to/arvoai 2026） |
| operator reconcile / 幂等收敛 | Kubernetes 官方 *Operator pattern* 文档 |
| 自治级别与「批边界而非批动作」 | CSA《Autonomy Levels for Agentic AI》2026；arXiv 2506.12469 |
| 今天的 5 个缺口原文 | `contrib-data/ops-journal.md` 2026-09-13（13:11 / 13:12 / 14:10 / 14:11 / 14:13 / 15:06 / 15:20 各行） |
| 库存空壳实证 | `contrib-data/inventory.json` + `forge.sh check`；09-13 11:08 journal 行 |
| A2-b 越界判例（批次写回） | 09-13 13:12 journal 行 |

## 附录 B — 与既有文档的关系（本设计不修改它们）

- `contrib-ops-ai-native-design.md`：本设计是它的**补充**，不是取代。它定「六节点 + 三钳夹 + 两账本」的架构；本设计补的是**钳夹的修改授权**这一维（并给第三律补上「钳夹不可自改」）。
- `contrib-operator` SKILL §1 权限类别闸：方向不变（类别闸保留），本设计**在其内部加粒度**（A2/A3 两个新档位），红线清单只增不减。
- `hermes-lane-protocol.md` / coder lane：A3 复用其质量机件，**不新增 lane 语义**（`pipeline-fix` 是 coder lane 的一个新卡型，不是新 profile）。
- `harness-engineering-principles.md`：本设计遵守原则 B（安全靠机制不靠 prompt）、E（软契约 vs 硬约束的判别）、H（每个 policy 决策带 decisionReason）、J（策略层模型不可见）。
- 未修改任何产线脚本/配置/skill（本卡红线）。
