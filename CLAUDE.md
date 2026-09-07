# martin — Hermes Agent 操作目录

通过 Claude Code 管理和操作 Hermes Agent 的工作目录。

## ⚑ 核心原则：治框架，不治现象

**用户是 Hermes Agent 的核心维护者。** 任何问题/现象的分析与解决，**优先作用于框架本身，而非问题本身**：

- 先定位根因在框架哪一层（agent loop / 工具 / 网关 / 压缩 / 记忆…），把缺陷修在源码 `~/workspace/hermes-agent/`，再顺手解决眼前这一例——而不是反过来打补丁绕过。
- 看到一个 case，默认问「框架怎样才能让这类 case 不再发生 / 自动恢复」，而不是「这一个怎么救」。
- 仅当框架修复成本极高、或纯属环境/配置偶发时，才退而只处理个案；事后仍记一笔待修。
- 修复落到框架后，同步评估是否值得提 PR 回馈上游（见记忆 [[hermes-contribution-followups]] 的贡献红线）。

一句话：**根因进框架，个案走兜底。**

## hermes 外发消息规范（先 AI 整理，后推送）

用户 2026-09-05 拍板：**任何经 hermes 推送到微信等渠道的消息，禁止脚本直推原始输出**（事件转储、rq-id 列表、日志行、exit code、命令回显等——用户读到无法理解）。所有外发载荷必须先经 AI 整理成人类可读摘要再发：

- **三段式结构**：发生了什么 → 为什么与我有关/多重要 → 建议我做什么（或明说无需动作）。技术标识（rq-id / PR# / issue#）只作引用锚点，不当正文。
- **职责分层**：脚本（notify.sh 等）只负责收集、去重、限额、排队（events.jsonl / ready-queue 账本）；「组织语言并推送」必须由 AI 完成（hermes 带 agent 的整理步骤，或 claude -p 摘要层）。不经 AI 的直推通道按框架缺陷对待、列入改造。
- **审批卡豁免（用户 09-05 确认）**：L2-A 审批卡走规范化模板、**不经 AI 整理**——结构化本身就是高效消费。它是本规范的设计标杆（自解释 + 决策就绪：动作选项 / 链接 / premises 齐备），机械性告警改造时向此形态对齐。
- **存量改造（09-05 已落地）**：contrib-watch `notify.sh` 已按本规范重写——机械事件（premise-dead/own-pr/budget）走脚本模板卡、叙事事件（pipeline-failure 等）走 `claude -p` 摘要层（失败挂账重试，永不降级 raw dump）、事件带 `channel` 字段做渠道隔离、空卡守卫防空推。详见 contrib-data/README.md「告警推送两级渲染」。

## harness 工程原则

开发/修改 hermes 任何子系统（agent loop / permission / compact / hook / streaming / mcp / skill / memory 等）前，**先读 [`harness-engineering-principles.md`](harness-engineering-principles.md)** —— 提炼自 `learn-everything` 14-artifact harness 教程（以 Claude Code 为参照系）。核心四条：**① 正交架构**（新子系统不改旧的，接入前问"能否零改动")；**② 模型不可靠**（安全/隐私/cardinality 机制层强制，不靠 prompt 自律）；**③ 软契约**（约束写 prompt/类型，不 runtime throw；仅数据损坏/安全才硬约束）；**④ context 经济是 KPI**（cache 命中 + 双轨注入 stable-prompt/dynamic-attachment + 双层去重 LRU/Session-Set）。文档含 10 条通用原则 + 27 条反模式 + 14 子系统速查表。配合 [[hermes-contribution-followups]] 的 sweeper 红线食用。

## hermes 开源共建

参与 `NousResearch/hermes-agent` 共建时，**先读 [`hermes-contribution.md`](hermes-contribution.md)** —— 沉淀了被合入 PR 画像、kshitijk4poor 打法逆向、salvage 流程、sweeper 机制（含 09-02 AI farm 生态侦察）、sweeper 红线、邮件时滞坑、**策略主轴 2.0 全文**。具体 PR 进度见记忆 [[hermes-contribution-followups]]。

### 策略主轴 2.0（2026-09-02 拍板）：review-first，让维护者做 pick

**背景**：上游已是 AI agent 贡献农场生态（自锚打包/消防 hose 竞速/issue 农场三种架构，issue→PR 以小时计、单账号日发 7 PR）；09-02 实证 8 个当日抢坑 PR **零合入** → **anchor ≠ merge，分钟级占坑竞速不参与**（SLA=当日内+决策质量；唯一例外=深水区+独家证据域）。而该仓库有成熟的三代收敛文化（erosika #83500 → kshitij #85452 → teknium #99375/#100916，模式=从 PR 池 cherry-pick 保署名收编）；我方 #86622 即被动验证：Teknium 亲手 salvage 我方 3 个可剥离 commit 合入 main。

**主轴**：**高质量 review 是渠道，可 pick 的 commit 库存是资产，被 pick（graph 亮灯）是终极产出。**

**⭐ commit 进仓优先原则（2026-09-05 用户拍板，优先级高于三腿分工的任何单腿惯性）**：一切贡献动作的**第一 KPI = 我方 authored commit 进入上游 main**（直接 merge 或被 pick，署名保留）。执行含义：
- 每个贡献动作立项时先回答「这次动作产出/推进哪个可进仓的 commit」；答不出就调整形态，直到答得出
- evidence review **有货必带 cherry-pick offer**（#86062 模式）；「没货就不硬带」是对单次动作的纪律，不是长期借口——没货时下一步必须是**造出货来**（repro→修复 commit→mutation 自证→入库存）
- 本地库存持续按「单关注点 + 可剥离 + mutation 自证 + 基于 current main」标准锻造，保持随时可 offer 状态
- 纯观察/纯评论且不推进任何 commit 的动作要占少数；连续多个无 commit 产出的动作 = 形态报警，回炉重选

三腿分工：
1. **evidence authority** —— 生产取证型 review/评论，只在域内+有独家证据时出手（weixin TTL/取证、state.db/FTS、cron 投递）
2. **cherry-pick invitation** —— review 真发现缺口 && 库存有货时，按 #86062 模式 offer 单关注点 commit（fork sha + authorship 保留；措辞**排序推荐不并列**：lift 保署名=显式首选 → absorb 须点名 Co-authored-by → follow-up 兜底；禁「随你方便」式对称句式——09-07 #103650 对称措辞致 substance 被采纳但署名归零），**没货就纯 review，不硬带**
3. **salvage** —— 停滞 PR 雷达（farm 洪水的必然产物=工业化停滞供给），probe→salvage 走 §5 流程

**review 红线（COI 防御）**：主载荷必须是对维护者的验证价值（file:line receipts + mutation 自证）；自己的 PR/commit 只在缺口驱动场合出现；**每周深检预算 1-3 个**（三轮验证 strategist→亲手核→fresh-context 红队成本高），其余新 PR/issue 只内部研判不发帖——不做全仓免费 QA。筛选 rubric：域契合 × 合入临近度 × 独家弹药 × 可收敛性 × 作者质量史。**漏斗度量：review → adoption → pick → 关系信号（@提及/直接 ping）。**

**任何对外动作落地前过 `/contrib-preflight`**（hermes-contrib-strategist agent）；对外动作走 L2 闸门（会话内批准/微信审批 + approved.log 台账）。存量可 pick 库存（#96472/#85548/#75771/#75453/#65794 + #86062 内 1d0e71e822）台账见 hermes-contribution.md §11。

**lane 模式接入（2026-09-07 已实施，详见 [`hermes-lane-protocol.md`](hermes-lane-protocol.md) §8）**：contrib 域双 lane 已落——①`contrib` profile（hermes worker，只读研判专家：premise 复验/状态核查/报告解读；gh 只读红线，SOUL.md 含 hermes-contribution.md 知识源路由）；②`contrib-cc` lane（CC 消费）：execute.sh own-PR 已批分支自动建卡（幂等）+ 微信派单（default SOUL.md 路由表：直答/`contrib`/`contrib-cc` 三分）。escalate 审批项**不建卡**（消费者是用户非 CC，防双消费）。流水线主链与三路 L2 审批全部原样保留。

### 机会流水线 contrib-watch（09-02 上线，试点 local-only）

主轴 2.0 的执行层：launchd `com.stringzhao.contrib-watch`（每小时 :07）跑 `scripts/contrib/run-watch.sh`——廉价闸门粗滤新 issue（`scan_gate.sh`，零命中不开 LLM）→ 有命中才 `claude -p "/contrib-watch scan"` 研判（15 分 rubric → own-PR / probe-salvage / review-evidence / watch / skip 五分类）；每日 08 窗口 radar（停滞 PR 雷达 = salvage 供给线 + 自有 PR 资产盘点 + 台账复检 + 至多 1 个自动构建）。产物全落 `contrib-data/`（gitignore）：briefs（每日简报）/ radar / runs（构建记录）/ ledger.md（观察台账）。手动入口：`/contrib-watch scan|radar|build <issue#>`。

**边界**：scan/radar 严格 L1 只读（gh 读+本地写）；build 产出本地 worktree 分支 + PR-DRAFT 草稿，**绝不 push / 绝不 gh pr create**——提交永远人工，L2 闸门不豁免；自动构建旋钮在 `contrib-data/config.json`（auto_build / min_build_score=12 / 每日上限 1）。观察真实运转质量后再评估是否放开自动提交。

**commit trailer 规范**：上游 hermes PR 的 commit message **一律不带 `Co-Authored-By: Claude` trailer**（用户 2026-08-14 拍板，沿用上游惯例）；Claude Code 默认加 trailer 的行为在此仓库的上游贡献场景被显式覆盖。本地 martin 仓库自身 commit 不受影响。

### 快车道与 L2-A 微信审批环（09-04 上线）

及时性数据实证（#102413 probe 7h 作废 / #102700 建议 build 后 2h 被占）后，contrib-watch 加了快车道：**闸门已反转为黑名单**（只排除 desktop/kanban/dashboard 等零契合域，其余 issue 全部进 LLM 研判——09-04 用户拍板扩大范围+token 充裕；PR 仍走每日 08:07 停滞雷达，不做小时级全量分析）。scan/radar 把「验证成本已付清、只差 L2 批准」的项写入 `contrib-data/ready-queue.json`（唯一写入口 `scripts/contrib/rq.sh`，含 premises/ammo/score/状态机）。**深检触发双通道：run-watch 每小时尾部快车道（候选即出即检，nohup 后台）+ launchd 09:37 兜底窗口**，对预算内 top1 自动跑三轮审（strategist preflight + fresh-context 红队，两次独立 `claude -p`，文件版次传递），成稿落 `contrib-data/pending/` → tunnel 只读 URL → `hermes send` 推微信 🟡 审批卡（深检配额周/日均 30，09-04 用户拍板放宽——token 充裕，配额已非节流而是**告警线：候选项因配额不足排队时微信通知用户**；账本 `budget.json`；probe 车道单轮 strategist 免红队、不占深检预算）。告警（自有 PR 获维护者互动/merge 灯、probe premise 死亡、流水线故障、配额告罄）走 `events.jsonl` 聚合推送，非审批类日 ≤3（**09-05 起推送载荷必须过 AI 整理层，见「hermes 外发消息规范」——notify.sh 脚本直推属待改造存量**）。用户微信回「批/改/否 #rq-id」由 hermes 侧 `~/.hermes/skills/github/hermes-contrib-l2/` skill 处理：TTL 复验（issue 存活/占坑/premises 抽验/近 5 评论信号）→ gh 落弹 → approved.log（L2-A）→ 回执；48h 无回复由 hermes cron（09:17 no-agent）搁置+晨间对账。

**纪律守恒（升级不降级）**：①草稿与微信推送是 L1（本地渠道），**发出（gh 写）永远过 L2**——微信批准（L2-A）与会话内明示（L2-B）等效，执行前都查 approved.log 去重；②**所有对外草稿必须过 strategist preflight** 才能进 awaiting-approval；③own-PR 的 push/gh pr create 由执行方执行需 `allow_own_pr_push=true`（默认关）。会话内随时 `scripts/contrib/rq.sh list` / `budget status` 查看队列与预算。首周 `notify_dry_run=true`（只打印不真发），演练闭环确认后再关。

**L2-A 短码审批链（09-05 立项；~~暗 launch 未启用~~ 09-07 探查实证已实际启用：config `approval_interactive:true` + `auto_approve:true`+`auto_approve_min_score:12` 已在，`com.stringzhao.approval-collect` 已装载运行，notify-state approvals 计数为证；CLAUDE.md 此前的「未启用」记载系文档滞后）**：审批卡带 `?key=<短码>` 链接 → tunnel 审批页点选批准/否决/需修改（短码自动回填，零打字）→ launchd 90s 轮询收集 → 确定性执行链投递。编排实现在 [`scripts/approval/`](scripts/approval/README.md)（collect.sh + execute.sh + plist；**plist 刻意不入 launchd，装载是人工步骤**）；页面与判定层在 tunnel-cli 仓（`drops approve`/`drops decision` ≥1.8.0）。开关 = `config.json` 增 `"approval_interactive": true`（缺省 false = 旧文本卡路，**当前真实 config 未加此键**）；微信文本回复降级路（hermes-contrib-l2 skill）全程保留，两路共用 rq 状态机互斥（collect 先 `set approved` 占坑防重复消费，verdict 是第二跳）。沙箱全链测试零真实外发：`bash scripts/approval/tests/run.sh`。

## hermes 多域 COO 架构（kanban + profiles，2026-09-06 立项）

用户拍板方向：四域各一个 profile（**面向场景设计专家，能力组合走 skill 层**——task 行有独立 skills 列可按任务挂载；拆 profile 的唯一正当理由是权限/身份/爆炸半径边界，不是能力复用）。四域 = contrib（开源共建，暂维持脚本流水线）/ ops（产品运营）/ life（生活助理，dogfood 首选）/ hkstock（待建）。微信单入口 `/kanban create` → triage → 人工路由（dogfood 期 `auto_decompose: false`）→ dispatcher 按 assignee=profile spawn 隔离 worker → 终态事件自动推回微信。

**已落地（第 0 步加固）**：`~/.hermes/config.yaml` kanban 段已显式设 `auto_decompose: false`（#49638 事故路径，每 tick 重读即时生效）、`max_in_progress: 2`（macOS 无 MemTotal 内存推导回落无界，必须显式封顶；watcher 启动时读取，需 gateway 重启生效）、`default_assignee: "default"`。实态：dispatcher 在跑（60s tick 单例锁）、kanban.db 全空零历史、微信 `/kanban` 无平台限制可用、`kanban-worker`/`kanban-orchestrator` skill 已装。v1 成熟度中高（孤儿卡 reconcile/僵尸回收/per-profile 并发上限齐备）。

待办：~~gateway 重启使 max_in_progress 生效~~ ✅ → ~~life profile dogfood 全链~~ ✅（smoke 卡 + 微信自然语言派单全环 09-06 23:22 跑通：派单→建卡→life worker 55s→notifier 唤醒微信 agent 推回）→ 压测微信推送并发（[[hermes-weixin-rate-limit]] TTL 老问题会放大）→ ops 跟进 → contrib 迁移评估。

**life profile 已配置（09-07）**：SOUL.md 重写为生活助理（三大主场+kanban worker 准则）；修复 clone_honcho_for_profile 对 self-hosted Honcho 静默失效 bug（life 本地 honcho.json 独立 aiPeer，workspace 共享）——**此 bug 是贡献候选，在 evidence authority 域（state/记忆方向），待入 contrib-watch 台账**。遗留：①profile 级 cron 需 multiplex gateway 或独立 gateway 才触发；②用户自装 skill（dianping-*/travel-planner）不随 hermes update 同步到 profile，需手动拷贝。

**UX 层（2026-09-06 补）**：default profile 的 `toolsets` 已加 `kanban`——微信里用**自然语言派单**（「派给 life 做 X」），agent 调 `kanban_create` 工具建卡并自动订阅当前微信会话（`_maybe_auto_subscribe`，`kanban.auto_subscribe_on_create` 默认 True，热加载无需重启），worker 终态自动推回微信。`/kanban create --assignee` 裸命令只是管道层/调试入口。smoke 卡 t_797cfe76 已验证主链（life profile worker 21s 完成）。

**执行规范全文 → [`hermes-lane-protocol.md`](hermes-lane-protocol.md)**（lane 模式协作手册：分工口诀「能写成 SOP 的→真 profile，每次都要重新想的→`<域>-cc` lane」、建卡规范、CC claim 动作流、五条红线、并发安全模型、**新 profile 创建 SOP——后续每个 profile 必须按此落 lane 配置**、contrib 薄适配方案、源码锚点表）。核心三条：①CC 路径 = control-plane lane 消费者（assignee=不存在的 profile 名如 `contrib-cc`，dispatcher 永不 spawn，停 ready 等 claim）；②CC 会话**永不跑 `hermes kanban dispatch`/`daemon`**；③产物回流三层 = comment / attach / complete --summary --metadata。

## 开源项目运营（oss-ops）

运营 strzhao 名下开源项目组合（ai-todo 打样 → 组合铺开 → 内容引擎 → 发布脉冲）时，**先读 [`oss-ops.md`](oss-ops.md)** —— 沉淀了审批分层红线（L1 全自动只读；**一切对外动作 = L2，无 L3**，按场景走两路：**L2-A 异步路** Hermes 发起→微信审批、**L2-B 实时路** Claude Code 会话内用户明示即执行、不走微信不等时间窗；两路共用 approved.log 账本，preflight 与反 slop 不豁免）、渠道规则事实核查（Topics 自设 / dev.to API 可全自动 / awesome-claude-code 14 天门槛已满足）、9 仓组合台账与 ai-todo 打样 playbook。双 COO 分工：Hermes Agent 承担异步日常执行（每日巡检 cron + `~/.hermes/skills/github/oss-ops/` skill），martin 侧 Claude Code 承担实时合作运营 + 上下文工程 + 打样质量件 + pre-flight 审视（`/oss-preflight`）。动态进度见记忆 [[oss-ops-progress]]。

## Hermes 可观测性消费（本地观测栈）

操作/排查 hermes 异常（消息没发、说一半断、疑似限流、定时任务没跑）前，**先读 [`hermes-observability-guide.md`](hermes-observability-guide.md)** —— 30 秒入口 `hermes forensics summary --hours 24`、症状→命令决策树、events.db 数据字典、日志路由表（含 cron→agent.log 上游单写坑：gateway.log 查不到 cron 日志 ≠ 没发生）。栈为本地补丁不入上游（`observability-stack` 分支锚定）；升级只走 fetch+rebase。

## Hermes Agent 环境

- **版本**: v0.20.5（2026-08-23 rebase 到 origin/main@f293e7206b + 本地补丁栈，见记忆 [[hermes-upgrade-mechanism]]）
- **安装路径**: `/Users/stringzhao/workspace/hermes-agent/`
- **CLI 路径**: `/Users/stringzhao/.local/bin/hermes`
- **用户数据目录**: `~/.hermes/`（config.yaml、sessions、skills、memories、cron、logs 等）
- **当前模型**: `deepseek-v4-flash`（自定义 provider `deepseek-flash`，DeepSeek 官方 Anthropic 兼容端点 `https://api.deepseek.com/anthropic`，key 在 `~/.hermes/.env` 的 `DEEPSEEK_FLASH_API_KEY`；2026-09-07 用 `gcli hermes deepseek-flash` 一键切换——因 Kimi coding plan 额度用尽，属**临时切换**，config 备份 `~/.hermes/config.yaml.bak-before-deepseek-flash-1788769781`；回滚 `gcli hermes rollback` 或切回 kimi-coding/k3，5 个 cron 已随切换自动重 pin）
- **终端后端**: local（命令直接在宿主机执行）
- **当前工具集**: hermes-cli

## 常用命令速查

### 交互式聊天

```bash
hermes                    # 进入交互式 CLI 聊天
hermes chat               # 同上
hermes --tui              # TUI 模式（Node/React 前端）
hermes -z "描述你的需求"    # 单次非交互式任务
hermes -m "模型名"         # 指定模型
hermes -t "工具集名"       # 指定工具集
hermes --resume SESSION   # 恢复指定会话
hermes --continue         # 继续最近会话
hermes --accept-hooks     # 自动批准高危操作（慎用）
hermes --yolo             # 跳过所有确认（慎用）
```

### 配置管理

```bash
hermes config             # 查看完整配置
hermes config get <key>   # 读取指定配置项
hermes config set <key> <value>  # 修改配置项
hermes model              # 切换默认模型/提供商
hermes tools              # 配置启用的工具
hermes setup              # 重新运行设置向导
```

### 会话管理

```bash
hermes sessions list      # 列出历史会话
hermes sessions browse    # 交互式会话浏览器（支持 FTS5 搜索）
hermes sessions export <id>  # 导出会话
hermes sessions delete <id>   # 删除会话
hermes logs               # 浏览日志
```

### 网关（多平台消息）

```bash
hermes gateway            # 前台运行消息网关
hermes gateway start      # 后台启动网关服务
hermes gateway stop       # 停止网关
hermes gateway status     # 网关状态
hermes gateway install    # 安装为系统服务（launchd）
```

### Cron 定时任务

```bash
hermes cron               # 进入 cron 管理交互界面
hermes cron list          # 列出所有 cron 任务
hermes cron status        # 查看定时任务状态
```

### 高级功能

```bash
hermes acp                # 以 ACP 服务器模式运行（供 VS Code/Zed/JetBrains 集成）
hermes mcp serve          # 以 MCP 服务器模式运行（供 Claude Desktop 等客户端调用）
hermes dashboard          # 启动 Web 仪表盘
hermes doctor             # 诊断配置和依赖
hermes skills             # 搜索、安装、管理技能
hermes plugins            # 管理插件
hermes profile            # 多实例配置管理
hermes update             # 更新到最新版本
hermes version            # 显示版本
```

### 终端后端切换

```bash
hermes config set terminal.backend local      # 本地执行（默认）
hermes config set terminal.backend docker     # Docker 容器隔离执行
hermes config set terminal.backend ssh        # SSH 远程执行
hermes config set terminal.backend modal      # Modal 云执行
# 需要相应的环境变量和配置
```

## 架构概览

```
用户输入 → hermes CLI (cli.py / hermes_cli/main.py)
         → AIAgent (run_agent.py) → 会话循环
              ├── prompt_builder.py → 组装 system prompt
              ├── model_tools.py → 工具发现/调用
              │    ├── tools/registry.py → 工具注册中心
              │    └── tools/*.py → 40+ 内置工具
              ├── tools/environments/ → 终端后端 (local/docker/ssh/modal)
              ├── agent/memory_manager.py → 记忆管理
              ├── agent/context_compressor.py → 上下文压缩
              └── agent/skill_commands.py → 技能系统
         → hermes_state.py → SQLite + FTS5 持久化会话
```

## 关键文件位置

| 文件 | 说明 |
|------|------|
| `~/.hermes/config.yaml` | 主配置文件 |
| `~/.hermes/.env` | API 密钥等敏感信息 |
| `~/.hermes/sessions/` | SQLite 会话存储（含 FTS5 全文索引） |
| `~/.hermes/skills/` | 技能目录 |
| `~/.hermes/memories/` | 记忆存储 |
| `~/.hermes/cron/` | Cron 任务定义 |
| `~/.hermes/logs/` | 日志文件 |
| `~/.hermes/SOUL.md` | Agent 人格/自定义指令 |
| `~/.hermes/skins/` | 皮肤/主题（YAML） |

## Claude Code 操作模式

当前目录下，Claude Code 可以：

1. **执行 hermes 命令**：直接通过 Bash 工具运行 `hermes` 相关命令
2. **管理配置**：读写 `~/.hermes/config.yaml` 和 `~/.hermes/.env`
3. **查看状态**：`hermes status`、`hermes doctor`、`hermes logs`
4. **操作会话**：`hermes sessions list/browse/export`
5. **管理 cron 任务**：`hermes cron list/status`
6. **管理网关**：`hermes gateway start/stop/status`
7. **更新 agent**：`hermes update`

### 常用操作示例

```bash
# 快速任务：让 hermes 完成一次性工作
hermes -z "帮我检查当前目录的 git 状态并汇报"

# 指定模型执行
hermes -m "anthropic/claude-opus-4-6" -z "复杂的代码审查任务"

# 恢复之前的会话继续工作
hermes --resume <session_id>

# 查看最近的会话
hermes sessions list | head -20

# 诊断问题
hermes doctor
```

## whisper 语音转写

本机已部署高性能 whisper 语音识别环境，利用 M4 Max 的 Metal GPU / ANE 加速。

### 基本用法

```bash
# 激活虚拟环境
source /Users/stringzhao/workspace/martin/.venv/bin/activate

# 基本转写（默认 mlx 引擎 + tiny 模型 + 中文 + txt 输出）
python scripts/transcribe.py audio.m4a

# 高精度转写（large-v3 模型，推荐用于重要内容）
python scripts/transcribe.py audio.m4a --model large-v3

# 速度优先（large-v3-turbo，精度接近 large-v3 但更快）
python scripts/transcribe.py audio.m4a --model large-v3-turbo
```

### 参数速查

| 参数 | 可选值 | 默认值 | 说明 |
|------|--------|--------|------|
| `audio` | 文件路径 | - | 输入音频（支持 wav/m4a/mp3 等） |
| `--engine` | mlx / faster / whisper | mlx | 推理引擎 |
| `--model` | tiny / base / small / medium / large-v3 / large-v3-turbo | tiny | 模型尺寸 |
| `--language` | zh / en / auto | zh | 语言 |
| `--output-format` | txt / srt / vtt / json | txt | 输出格式 |
| `--output-dir` | 目录路径 | . | 输出目录 |

### 模型选择

| 场景 | 模型 | 大小 | 速度 |
|------|------|------|------|
| 快速测试 | tiny | ~75MB | 极快 |
| 日常转写 | base | ~150MB | 快 |
| 高精度 | large-v3 | ~3GB | 中速 |
| 高精度快速 | large-v3-turbo | ~1.5GB | 较快 |

### 输出格式示例

```bash
# SRT 字幕
python scripts/transcribe.py audio.m4a --output-format srt

# JSON（含时间戳，适合程序处理）
python scripts/transcribe.py audio.m4a --output-format json

# 英语转写
python scripts/transcribe.py audio.m4a --language en
```

### 环境说明

- Python 3.12 虚拟环境位于 `.venv/`（brew 强制要求 PEP 668）
- 模型缓存：`~/.cache/huggingface/`
- 引擎优先级：mlx-whisper（Metal GPU 加速）> faster-whisper（备选）> openai-whisper（兼容层）

## 色彩体系（stringzhao-life）

本项目 UI / 状态栏统一采用「苔绿 Sage」色彩体系（来源 [stringzhao.life/colors](https://stringzhao.life/colors)）。完整设计资产沉淀在 [`statusline-sage/COLORS.md`](statusline-sage/COLORS.md)：品牌色、核心色板、辅助色板、色彩关系、CSS Tokens、交互原则。

核心语义色：
- 苔 **Sage** `#3A7D68` — 品牌主色、clean git `⎇`、低用量指标（<60%）
- 苔浅 **Sage Light** `#52A688` — 路径 / 分支名 / 项目名（活跃态）
- 琥 **Amber** `#D4920A` — warning / 中用量（60–85%）/ worktree 标记
- 朱 **Vermillion** `#D94F3D` — destructive / 高用量（≥85%）/ dirty 计数 / **高峰期倍率警示**
- 天 **Sky** `#3B87CC` — info / 模型名
- 烟 **Smoke** `#8F8F8D` — 分隔符 `│`、辅助标签

设计原则：纸/墨铺底、苔绿点睛；三级灰阶（雾/烟/炭）承接信息层级；琥/朱/天对应 warning / destructive / info 语义状态。**朱红仅用于"高代价/警示"语义**——高峰期 token 3 倍消耗即归此列。新增 UI 一律按此取色；换配色改 `statusline-sage.sh` 顶部色彩函数的 RGB 三元组（truecolor 24-bit 实现）。

## 注意事项

- Hermes Agent 主模型走自定义 provider（`providers.glm-flash`，`transport: anthropic_messages`）；换 provider 后记得 pin 带 provider/model 快照的 cron 任务，否则 drift_skip 会 fail closed
- 配置文件 `~/.hermes/config.yaml` 格式为 YAML，修改后 `hermes` 会自动加载
- API 密钥等敏感信息存放在 `~/.hermes/.env`，不要提交到版本控制
- 会话数据（SQLite）在 `~/.hermes/sessions/`，支持 FTS5 全文搜索
- 网关支持 Telegram、Discord、Slack、微信、飞书等 15+ 平台
- `--accept-hooks` 和 `--yolo` 会跳过安全确认，仅在信任的环境下使用
