---
name: contrib-watch
description: hermes 上游机会流水线——增量扫描新 issue 后智能研判（评分→五分类决策）、停滞 PR 雷达（salvage 供给）、本地自动 PR 构建（产出分支+PR 草稿，绝不 push/绝不建 PR）、就绪队列快车道（验证付清项→微信 L2-A 审批环）、GitHub 通知邮件研判（三通道分流）、叙事告警摘要卡（digest：三段式人话+send-digest 唯一外发）。六种模式：scan（研判 pending 命中+入队）、radar（每日雷达+自有资产+premise 复验+至多 1 个自动构建）、build <issue#>（本地 PR 构建流水线）、deep-check <rq-id>（三轮审自动化：strategist preflight+fresh-context 红队）、mail（邮件三通道：auto 流水线动作/important 微信卡/routine 简报）、digest 摘要卡（叙事告警三段式摘要+发送）。
argument-hint: [scan | radar | build <issue#> | deep-check <rq-id> --phase preflight|redteam | mail] [附加说明]
allowed-tools: Read, Write, Edit, Grep, Glob, Bash, Agent
---

# contrib-watch — hermes 上游机会流水线

数据目录 `$CONTRIB = /Users/stringzhao/workspace/martin/contrib-data/`（运行产物，不入库）：
`config.json`（旋钮）/ `scan-cursor.json`（游标）/ `pending-batches/`（研判批次文件，唯一待研判数据源）/ `ready-queue.json`（就绪队列，唯一写入口 `scripts/contrib/rq.sh`）/ `budget.json`（深检预算账本）/ `pending/<rq-id>.md`（待审成稿）/ `events.jsonl`（告警账本）/ `briefs/YYYY-MM-DD.md`（每日简报）/ `radar/YYYY-MM-DD.md`（雷达）/ `runs/`（构建+深检记录）/ `ledger.md`（观察台账）/ `logs/`。

own-PR 小时级机械盯梢（09-10）：`scripts/contrib/own_pr_watch.sh`（run-watch 段 2.5 每小时跑，零 LLM 机械 diff）——问「我的 PR 有没有新动静 / 为什么没收到 PR 告警」→ 看该脚本头注释（exit 语义/事件三级契约）+ 快照 `$CONTRIB/own-pr-watch-snapshot.json` + 日志 `$CONTRIB/logs/own-pr-watch.log`；高级事件（外部评论/merged/closed→微信）受 `config.own_pr_alert_per_day`（缺省 2/日）子上限，低级（mergeable 翻转/停滞→简报）不受限。

策略知识库（研判/构建前必读，是评分与纪律的唯一权威）：
- `/Users/stringzhao/workspace/martin/hermes-contribution.md`（共建策略 + §10 sweeper 机制）
- `/Users/stringzhao/workspace/martin/.claude/agents/hermes-contrib-strategist.md`（形态选择框架/锚定铁律/验证纪律全文）

**品牌姿态红线（2026-09-11 用户拍板，一切起草动作前置自检）**：以 strzhao 名义起草的每条对外文本都是品牌资产——不索取署名/credit（署名是做出来的不是要来的，#103661 实证）、让路有让路的样子（一句确认+收工，不诉苦不夹条件）、不低姿态（不催 review/不堆感叹号/不写空话客套，认可对方就具体说好在哪）、竞争上吸收>差异化>观望不免费优化对手。全文见 martin 仓 hermes-contribution.md §11「品牌姿态红线」。

对外动作分级（不可逾越）：**scan/radar/deep-check = L1 只读上游**（gh 读 + 本地文件写；微信推送/写 ready-queue 是本地渠道动作，属 L1）。**「草稿自动备好 + 推送审批」属于 L1；发出（gh 写：评论/issue/PR/push）永远过 L2**——L2 三路等效：**L2-auto 自动批准**（09-06 用户拍板默认路：深检末段红队/preflight 写 `verdict.json`，确定性闸门 `scripts/approval/auto-gate.sh` 硬条件全过——评论类可逆动作 + auto/high/low + score≥12 + 非 own-PR——则跳过微信卡直接进执行链，台账标 L2-auto，回执照常推送）、**L2-A 微信批准**（升级路：闸门任一不过 → 审批卡置顶「我定不了的点」清单 → 用户「批 #rq-id」→ TTL 复验 → 落弹 → approved.log）、**L2-B 会话内明示**。三路执行前都查 approved.log 去重。**所有对外草稿必须过 strategist preflight 才能进 awaiting-approval/auto-gate**（deep 车道另加 fresh-context 红队；probe 车道单轮 strategist 免红队）。**build 只到本地为止**——`git push`/`gh pr create` 仅当对应 own-PR 项获 L2-A 批准**且** `config.allow_own_pr_push=true` 时由执行方执行（09-08 起**执行方 = coder lane worker**：execute.sh 自动建 coder 卡，worker 驱动 claude -p 全自动 push+建 PR），其余场景绝对禁止（own-PR 永不进 L2-auto）。

---

## 模式一：scan（研判 pending 命中）

launchd 每小时粗滤后有域内命中时调用（主路 = contrib 研判卡 worker；claude -p 仅兜底，两者共用本模式）。步骤：

1. 读数据源（唯一数据源=批次文件，契约 1b 已于 T6 收口）：读 `$CONTRIB/pending-batches/batch-*.json` 中**最新且含 `state=="pending"` 项的批次文件**（按文件名 ts 降序取首个含 pending 项的）。为空数组 → 输出「无待研判」结束。
2. 逐条 `gh issue view <N> --repo NousResearch/hermes-agent`（正文+labels+评论数），对每条打分（满分 15）：

| 维度 | 0 | 1 | 2 | 3 |
|---|---|---|---|---|
| **领域契合** | desktop/无关 | 边缘（browser/kanban/单平台冷门） | 相邻（tools/cli/update） | 核心链路（cron、gateway、sessions/state.db、weixin、compression、memory） |
| **独家证据/自利** | 无 | 间接相关 | 影响我们部署 | 我方有生产取证/取证能力直接适用（weixin 取证包、state.db 修复线、forensics 栈、kanban 多 profile 派单面） |
| **空间状态**（实查） | 拥挤（≥3 PR 或活跃车+无空间） | 活车（他人 PR 在动） | 死车（PR 停滞 >14 天） | 空（无 PR 锚 + substance 查重也空） |
| **需求真实度** | needs-repro/无细节 | 单一环境无实据 | 有 repro/日志 | 生产环境+多站点共鸣/官方已跟踪的类 |
| **可剥离性** | 大簇/多关注点 | 需维护者先拍板方向 | 可拆但依赖多 | 单关注点、可测、可复现 |

   查重纪律：空间状态必须实查 `gh pr list --search "<N> in:body"`；标题含竞品机制关键词再搜一轮 PR（substance 层）。时间紧张时可先按 labels/正文粗判，但 own-PR 候选必须实查后才能给。

### 竞品吸收决策树（2026-09-11 用户拍板，替换"见竞品→发 review 帮改"旧路）

发现竞品 PR（占坑/机制重叠）后 **30 分钟内**做吸收评估，三选一，产出 absorb-plan 落 `runs/deep-check/<id>/absorb-plan.md` 并登记 `contrib-data/absorb-ledger.json`：

| 情形 | 判定 | 动作 | 产出 |
|---|---|---|---|
| **A 对方有我缺的**（更全覆盖/更好测试形状/更深根因） | absorb | 拆可剥离要点 → `forge.sh init` 升级我方库存件/own-PR（≤20min 基准）；goods 注记"吸收自竞品 X 的 Y" | 我方件升级，下次出手带更强货；对方好想法以我方 commit 形态回流 |
| **B 对方有洞**（且我方有独家证据/互补面） | differentiate | 我方 PR/库存件调成互补面（覆盖对方没碰的 case）；**不发 review 帮它修** | 两车不撞，我方变唯一可行解 |
| **C 对方全面更好且无我方利益** | stand-down | 高姿态一句话确认+关闭/让路我方件（#103661 模式：Nice work + better landing spot，零索取零条件），退场 | 不烧 token 不丢姿态 |

**红线**：绝不发"帮竞品修洞让它更易被合"的 review——那是用我方 token 武装对手。评估全程 gh 只读；吸收动作（改我方件）走 forge 正常红线（本地为止）；对外发声走 L2。

**台账**：`contrib-data/absorb-ledger.json`（`{competing_pr, our_asset, verdict: absorb|differentiate|stand-down, absorbed_points[], flowed_into, decided_at}`）——radar 巡检存活期 follow-up（A 路吸收件 register ready 后补 offer）。

### 部署前提（2026-09-09 刷新，独家证据/自利评分必读）

本机**多 profile + kanban 重度生产部署**（不是单 profile；09-08 曾记「profiles=[]」系实查方法错误——判断部署面看 `~/.hermes/profiles/` 目录与各 profile 的 gateway/cron 运行，不是看 config.yaml 顶层 profiles key）：

| profile | 用途/运行 | 相关取证面 |
|---|---|---|
| default | 微信主入口（本会话） | weixin 取证、会话/TTL |
| coder | kanban 编码执行 worker（claude -p 无头驾驶） | 卡生命周期、worktree、goal_mode |
| contrib | 共建研判 worker（gh 只读） | — |
| hkstock | 盘前简报/理财 worker（kanban cron 派单） | cron 调度、kanban 依赖链 |
| life | 生活/点评 worker | kanban 依赖链 |
| wx-echo | 微信回声 | weixin |

**kanban 域 09-09 起不再黑名单排除**（scan_gate 已修订）——kanban 相关 issue 需按真实部署面评分，勿再以"零 kanban 部署"为由 skip；多 profile/multiplex/调度类 issue 评估弹药时引用本表。

3. 五分类决策：**own-PR**（≥11 且 空间状态=3）/ **probe-salvage**（死车 2 分档，写 probe 评论草稿进简报）/ **review-evidence**（活车但我方有独家证据，写 review 要点进简报）/ **watch**（写入 `ledger.md`，含复检日期）/ **skip**。
3.5 **入队就绪队列**：决策 ∈ {own-PR, review-evidence, probe-salvage} 且得分 ≥ `config.ready_min_score`（默认 11）→ 逐条 `scripts/contrib/rq.sh add`：
   - `--premises-json` 必填：本项成立所依赖的关键前提逐条登记（`{"claim": "…", "evidence": "file:line 或 PR 号", "verified_at": "…"}）`——radar 复验与执行前 TTL 复验都以此为清单
   - `--ammo-json`：我方独家弹药清单（一句话/条）；`--age-hours`：issue 龄（排位新鲜度用）；probe-salvage 同时把完整 probe 草稿写 `$CONTRIB/pending/rq-<日期>-<issue>.md` 并在 `--note` 里注明草稿路径
   - 简报条目「下一步」改指 `rq-<id>`（不再写"建议手动 build/发"）
4. 追加 `$CONTRIB/briefs/$(date +%F).md`（格式见下）。**写回批次文件（卡路协议）**：每条研判完立即写回批次文件该条——`state="done"` + `decision`/`score`/`breakdown`/`rationale`/`space_check` 五字段（崩溃只损当前一条）。人工兜底清账 = `scan_gate.sh --drain`（把批次内 `state=pending` 项改写 `drained`），仅在人工确认已消费时使用。（微信推送由 run-watch.sh 尾部统一 flush，模式内不直接调 hermes send。）
5. 终端输出一行摘要清单（编号/标题/决策/分数 + 入队 id）。

简报条目格式：

```markdown
## #<N> <标题>
- 决策：<own-PR | probe-salvage | review-evidence | watch | skip>（<得分>/15）
- 空间：<实查结果一句话——锚/竞品 PR 编号与活跃度>
- 为什么：<一句话我方角度>
- 下一步：<own-PR→"雷达将自动构建"或"建议手动 /contrib-watch build <N>"；probe-salvage→附 probe 草稿；review-evidence→附 review 要点；watch→复检日期>
```

### 卡模式工作约定（contrib 研判卡 worker 必读，T1 起生效）

以 hermes kanban contrib 卡跑本 skill 时（run-watch 建卡 → contrib profile worker 执行），除上述步骤外遵守：

1. **批次文件协议**：数据源与写回见模式一第 1/4 步——批次文件元素 = 原始 hit 字段（number/title/labels/author/created/comments）+ `state:"pending"|"done"` + 研判结果五字段（decision/score/breakdown/rationale/space_check）。逐条写回、立即落盘；全部 done 后不再调 `--drain`。
2. **收尾双传**：调 `kanban_complete` 时**必须同时传 `summary` 与 `result`**——只传其一视为收尾不完整（上游 tasks.result 仅在显式传入时非空）。
3. **-q 模式禁脚本形态**：`python -c` / `jq -e` / 任何 `* -e` 脚本调用一律不可用（-q 沙箱拦截）；写回批次文件用文件读写工具完成。
4. **红线**：gh 只读（零 issue/PR 写、零评论、零 push）；`rq.sh` 只允许本地渠道动作（list/add/set/set-draft），禁任何对外动作；不写 briefs 与 ready-queue 之外的争议面。
5. **零订阅语义**：CLI 建卡默认零微信订阅——卡终态变化零推送；摘要类推送需求走 T5 notify 摘要卡 + notify-subscribe 补订，勿在 scan 卡内直接 `hermes send`。

---

## 模式二：radar（每日雷达，08 窗口）

1. **停滞 PR 雷达**：`gh pr list --state open --limit 1000 --json number,title,author,updatedAt,createdAt,labels`（**全量口径**——`--limit 300` 在洪流下只盖 ~3 天，09-04 已实测失效），过滤 updatedAt 距今 > `config.stale_pr_days`（默认 10）天、作者排除 `teknium1 / OutThisLife / app/ 前缀 / hermes-sweeper`、排除 duplicate 标签。对 top 候选（按域契合排序，最多 15 条）逐个 `gh pr view` 补：是否有 issue 锚、mergeable、行数、我方契合点。给建议动作（probe-salvage / review / watch / skip）。
2. **自有资产盘点**：`gh pr list --author strzhao --state open` 逐个看 updatedAt/mergeable/reviews/comments——**写 `$CONTRIB/assets-snapshot.json`（PR→{updatedAt, mergeable, reviewDecision, 最新评论作者}）并与上份快照 diff**：新增维护者/sweeper/collaborator 评论、mergeable 翻转、MERGED、>7 天停滞标黄 → `notify.sh event own-pr-activity --key "<PR>-<事件>-<日期>"`。停滞 >7 天的在简报给 ping/再 rebase/关停建议（ping 是对外动作，只建议不执行）。
   - **事件产出移交（09-10）**：own-pr-activity 的 event 产出已移交 `own_pr_watch.sh`（小时级机械盯梢，watcher 是唯一生产者）——radar 盘点/assets-snapshot/简报语义不变，但**不再直接发 own-pr-activity 事件**（防 08 窗与 watcher 同日双报 + 挤占子上限计数）。
3. **观察台账复检 + ready-queue premise 复验**：读 `ledger.md`，到期 watch 项逐个复查状态，状态变化则更新台账并写进简报。然后遍历 `$CONTRIB/ready-queue.json` 中 state ∈ {queued, awaiting-approval} 的活项，**逐条实查 premises**：issue 仍 OPEN？`gh pr list --search "<N> in:body" --state open` 无新占坑？**in-body 抓不到机制占坑（#103315 教训：PR 不引用 issue 号也能占坑，08:29 挂出、08:40 复验漏检）——还须按 issue 的机制关键词/触碰文件再搜一轮**：`gh pr list --search "<机制词1> OR <机制词2>" --state open` + 对照 touched paths；关键 file:line 在当前 origin/main 仍成立？——任一死亡 → `rq.sh set <id> expired` + `notify.sh event probe-premise-dead --key "<id>-<日期>"`（#102413 教训：过期 premise 的审批卡绝不能推）。
3.4a. **竞品吸收台账巡检（09-11 用户拍板）**：读 `contrib-data/absorb-ledger.json`——A 路（absorb）项：对应 forge 件 register ready 了吗？未 ready 且超 48h → 简报催办；ready 后存续期内在竞品 PR 评论补 offer（走 L2）。`absorb-eval-pending` 超 48h 未裁决 → 简报提醒完成 A/B/C 判定。C 路（stand-down）项：确认我方件已 close（gh 实查）。

3.5. **库存新鲜度 + 造货率巡检（09-09 上线；09-11 二次修正：goods-drought=造货能力报警——none 须有硬理由，无理由的 none 是欠账）**：`bash scripts/contrib/forge.sh check` 列库存台账（id/status/kind/loc/base_sha/checked龄）——ready 的 forge-commit 项对 base_sha 实查落后量：`git -C ~/workspace/hermes-agent rev-list --count <base_sha>..origin/main`，>50 commit 或 checked 超 14 天（check 已标 STALE）→ `forge.sh set-status <id> stale`，简报列「需 rebase/复验」；`in-flight` 超 7 天 → 简报报警。读 `$CONTRIB/goods-metrics.json` 近 5 条 deep-check 的 goods 状态：**连续 ≥3 次 `none` = 造货能力报警**（goods-drought 事件置顶；逐条复检：每条 none 的硬理由是否成立？能翻案的补 forge 立项——没有及时提供的货就是颗粒无收，第一 KPI=commit）→ `notify.sh event goods-drought --key "goods-<日期>"` 进简报置顶。
4. **自动构建**（本日仅当 `config.auto_build=true` 且当日 `runs/` 无已完成构建）：从今日 briefs 里挑分数最高且决策=own-PR 的 issue；≥`config.min_build_score` 则直接执行模式三（构建 1 个）；没有候选则跳过。
5. 产出 `radar/$(date +%F).md`（两节：外部雷达 / 自有资产+台账+构建记录+ready-queue 复验结果），并在 `briefs/$(date +%F).md` 追加「⭐ 雷达摘要」节。（微信推送由 run-watch.sh 尾部统一 flush。）

卡模式（T3）：radar 研判由 run-watch 建卡（`--kind radar`，贡献卡 worker 执行本模式），产出 `radar/$(date +%F).md` 照旧；补跑旗标由 run-watch 管理，卡内不用关心。

---

## 模式四：deep-check <rq-id> --phase preflight|redteam（三轮审自动化，由 launchd 09:37 调起或手动）

对就绪队列某项执行深检准备。**两阶段由两个独立 `claude -p` 进程分别执行，中间只靠文件版次传递（v1 草稿 → preflight 吸收 → v2 → 红队吸收 → final）= 结构性 fresh-context**。全程零 gh 写、零 push、不调 hermes send。

**`--phase preflight`**（阶段 1）：
1. 读 `$CONTRIB/ready-queue.json` 该项（premises/ammo/score）+ 简报中原始素材（review 要点/probe 草稿）。
2. **必须**用 Agent 工具调 `hermes-contrib-strategist` 子代理出 preflight 审视报告 → `$CONTRIB/runs/deep-check/<id>/preflight.md`（红旗清单/形态裁决/数字修正/发不发结论）。
3. **Goods 判定（commit 进仓优先硬闸，09-09 用户拍板升级：机制层强制）**：三态必答，结论写入 preflight.md 的「Goods 判定」节，并**必须随阶段 4 写进 v2 草稿头部注释块**（redteam 只读 `$CONTRIB/pending/<id>.md`，verdict.goods 以 v2 头部携带的 Goods 结论为准——缺该节 = 阶段 4 不得成稿；机械兜底在 auto-gate：goods.status 缺失/非法一律升级人工）。判定序：
   - `offered`：`bash scripts/contrib/forge.sh check` 输出的 ready 库存与本缺口**域匹配** → 评审稿直接带 cherry-pick offer（#86062 模式；offer 措辞按 hermes-contribution.md §11 署名排序规范，lift 保署名=显式首选）
   - `forge-lane`：无库存货但缺口**可造**（单关注点 / 可剥离）→ **评审稿照常发（不等待造货）**，同刻 `forge.sh init` 立项造货入库存；成稿发出后 PR 存活期内以 follow-up 评论补 offer（**PR 开窗期 = offer 变现最优期**：可直接 cherry-pick 进在飞 PR；等合入后再 offer 就降级成新 PR 排队）——09-09 #106199 实证：深检发现双缺口但手无货，快合窗内只能眼睁睁
     - **工时基准（09-10 用户拍板：禁无测量先验）**：单关注点 forge 件默认 **≤20 分钟**（09-10 实测锚点：weixin 4 件连造 12min、kanban-retry-notify 单件含入库 2.6min）。判定「来不及造」必须附测量依据（真实设备依赖/多文件重构/难复现环境），无依据一律按 20 分钟基准判可造。
     - **时效窗与审批解耦（09-10 用户拍板，重点）**：深检 review 类（review-evidence，评论可逆动作）走 **L2-auto 高置信自动批准**，**审批不构成等待项**——「等用户批会错过窗口」不成立，以此为由放弃造货 = 判定错误。时间压力只来自 PR 本身的合并节奏（作者活跃度/在飞状态），与人工审批无关。escalate 仅限真不可逆/预算类。
   - `none`：**仅限真不可造**——缺口需维护者拍板方向 / 多文件 schema 级重构 / 域外 / 纯观察，且须在 note 写明硬理由（「没有现成的」不算理由——现成的可以造）。none 是例外不是默认；连续 ≥3 次 none = 造货能力报警（goods-drought），radar 简报置顶。第一 KPI=commit 进仓：因没带货错失合并窗 = 颗粒无收（#106199 教训），这类损失不可接受（09-11 用户二次拍板：修正 45ba126 的过度回调）
4. 对报告逐条「亲手核」：对当前 origin/main 实查（修行号、核事实），吸收成草稿 v2 写 `$CONTRIB/pending/<id>.md`（头部注释记版次与依据，**必须携带 Goods 判定结论**供 redteam 产出 verdict.goods）。
5. `rq.sh set <id> deep-check`（阶段开始时）→ 阶段末不推进状态（等 redteam）。

**`--phase redteam`**（阶段 2，全新进程，**不得读 preflight.md 结论先入为主**）：
1. 只读 `$CONTRIB/pending/<id>.md`（v2）+ 必要的上游实查工具。
2. 把 v2 拆成可验证断言编号 A1..An，逐条独立核验（log 引用逐字比对、时长算术复算、引用保真、敏感信息扫描、语气/定位终检）→ `$CONTRIB/runs/deep-check/<id>/redteam.md`（必修/建议分级）。
3. 必修+建议全吸收 → final 版（覆盖 `$CONTRIB/pending/<id>.md`），history 记 `redteam_absorbed=n/m`；`rq.sh set <id> awaiting-approval --note "final 就绪"`。
4. **final 稿头部注释块必须含「审批页中文摘要（L1，不随评论发出）：」段**（09-06 审批体验重构）：一句话（L0，给审批者 30 秒决策）+ 3-5 条要点（这条评论/PR 说了什么、证据是什么、给对方带来什么、风险一句）+ 时效。审批页模板从该段渲染中文摘要层；它在注释块内，投递时随注释剥离，**绝不外发**。缺该段 = 成稿不完整，审批页退化为标题+premises。
5. **必须写判定文件 `$CONTRIB/runs/deep-check/<id>/verdict.json`**（09-06 用户拍板：默认自动、例外升级——preflight 单轮的 probe 车道同责，由其阶段 1 写出）：

```json
{
  "decision": "auto | escalate",
  "confidence": "high | medium | low",
  "risk_level": "low | medium | high",
  "goods": {
    "status": "offered | forge-lane | none",
    "note": "三态判定依据一句：offered=库存 sha+域匹配；forge-lane=缺口可修已立项（forge <slug>）；none=不可修/域外原因"
  },
  "reasons": ["升级时必填：每条 = 一个具体的、你定不了的点，写给用户裁决"]
}
```

**goods.status 必填且由 auto-gate 机械校验（fail-closed）**——缺字段/非法值一律升级人工。

**auto 门槛（09-11 用户拍板重构：目标是逐渐减少对人的依赖）**：仅当「断言全部核验通过 + 零必修残留 + 动作可逆（评论类）」就判 auto。**escalate 只剩三种正当理由**：①不可逆动作（own-PR 的 push/开 PR/关 PR）②预算/资源类 ③**缺判断依据**——且 reasons 必须写成「我需要什么才能决策」（缺的事实/缺的授权/缺的原则），**禁止写成「你选 A 还是 B」**。取舍类问题（语气拿捏/措辞/站队/让利）一律按已有原则自决：品牌姿态红线、竞品 A/B/C、goods 口径、反 slop——原则是判断的输入，不是新的规则清单；**不要为维护规则而限制判断力，拿不准时选「更保守的可逆选项」直接定**（例：措辞拿不准→删掉争议句再发；让利拿不准→不发，记进简报由用户事后纠偏）。goods 三态判定不是升级事由（域匹配带 offer、可造就造、不可修才 none）。**自决的取舍在 reasons 留一行「自决：按<原则名>定了<X>」**，进每日简报的「AI 自主决策清单」供用户回溯——用户纠的是原则，不是单条。

**失败处理**：任一阶段 exit≠0 → `rq.sh set <id> failed --note "<阶段>"`；预算按 `config.refund_failed_deep_check` 决定是否返还（默认不返还）；次日 gate 可自动重试（`failed → queued` 迁移由 gate 执行）。

### 卡模式工作约定（T4 起生效：深检主路 = kanban 依赖卡链）

深检两阶段的**主路**由编排层（run-watch 快车道 / run-deepcheck 09:37，共用 `scripts/contrib/deepcheck_card.sh`）建 preflight 卡（`--kind deepcheck`，attempt 级幂等键 `deepcheck-<rq-id>-<epoch>`，flight 登记 `kanban-flight-deepcheck.json`）；本节是 preflight/redteam 卡 worker 的职责契约。claude 编排（`deep-check.sh`）降格为 fallback（建卡失败才走），不再是 worker 的执行形态。

**preflight 卡 worker 职责**：
1. 读卡 body 传入的 rq-id/lane → 按模式四 `--phase preflight` 阶段 1-3 执行（strategist agent + 亲手核 + 草稿 v2 + 产出 `$CONTRIB/runs/deep-check/<id>/preflight.md` 与 `$CONTRIB/pending/<id>.md`）。
2. `rq.sh set <id> deep-check`（阶段开始时项仍为 queued——编排层建卡时不动状态，状态推进是 worker 职责）。
3. **lane 分叉（钉死）**：
   - `lane=deep` → 按 body 命令模板**自建 redteam 子卡**：`hermes kanban create ... --parent <本卡 id> --assignee contrib --idempotency-key "deepcheck-redteam-<id>-<attempt-epoch>" ...`（**必须带 `--assignee contrib`**，default_assignee 是 default profile，缺省会错轨）；子卡 body 必含模式四 redteam 段职责 + verdict.json 契约原文。
   - `lane=probe` → **免红队、不建子卡**（probe 单轮免红队策略红线）：自己写 verdict.json + `rq.sh set <id> awaiting-approval` 后收尾。
4. 收尾双传（kanban_complete 同时传 summary 与 result）。

**redteam 卡 worker 职责**：fresh-context（模式四阶段 2 铁律：不得读 preflight.md 结论先入为主）→ 逐断言核验 → final 吸收 → **必须写 verdict.json**（契约原文见模式四第 5 点）→ `rq.sh set <id> awaiting-approval` → complete 双传。审批卡推送由编排层 auto-gate/补推 sweep 承担，worker 不调 `hermes send`、不重复推。

**授权边界（钉死）**：worker 的 `rq.sh` 仅限 `set/list/show` 且只针对本项；**`budget reserve/refund` 为编排层专属，卡内绝对禁碰**（rq.sh refund 对 used 计数每调必减，双调=预算超发）。gh 只读；-q 模式禁 `python -c` / `jq -e` 脚本形态。

**链悬挂纪律**：redteam worker 无法完成时必须先 `rq.sh set <id> failed` + `notify.sh event pipeline-failure` 再收尾——编排层下轮 harvest 的 failed 分支接管 refund；子卡 blocked 由编排层补查收口（`-deepcheck-stale` 事件）。

**编排层链完成判定（worker 不感知，仅供理解）**：preflight 卡 done ≠ 链完成；编排层每轮 harvest——verdict+awaiting-approval → auto-gate（rc0 自动批准进执行链）；deep-check → 补查子卡终态；failed → 清+refund；查无/异常 → `-deepcheck-orphan`。

---

## 模式三：build <issue#>（本地 PR 构建流水线）

**铁律（每一步都要自检）**：只在本地 worktree 工作；**禁止** `git push`、`gh pr create`、`gh api` 写方法、`gh pr merge`；上游 commit **不带 Co-Authored-By trailer**；主 checkout `~/workspace/hermes-agent` 只 fetch 不 checkout（worktree 范式）。

0. **前置核查（任一不过→放弃并写明原因进 runs 记录）**：
   - `gh issue view <N>` 仍 open
   - `gh pr list --search "<N> in:body" --state open` 出现占坑 PR → **进竞品吸收评估（09-11 用户拍板，替换旧"改判 review-evidence 帮改"路）**：30 分钟内按 A/B/C 决策树处置（详见下方「竞品吸收决策树」），产出 absorb-plan 落 runs；**另按机制关键词搜一轮**（in-body 抓不到机制占坑，#103315 教训）
   - substance 查重：按机制关键词 `gh search prs` 一轮，无活跃竞品
   - **premise 四问**（strategist agent §5）：intentional design？确切行为行？原本在保护什么？复活被否决方向？——答不全→停在「补证据」建议
1. **worktree**：`git -C ~/workspace/hermes-agent fetch origin main` → `git worktree add ~/workspace/hermes-contrib-<N> -b fix/<slug> origin/main`（slug 从标题提炼，≤5 词）。
2. **复现优先**：能写失败测试先写（垂直回归，走公开入口；参考 AGENTS.md Testing 段与 strategist §5 测试三禁令）。跑 `scripts/run_tests.sh` 范式验证测试在修复前失败。
3. **修复**：最小 diff；行为配置走 config.yaml 不走 env；不碰 `uv.lock`；不加新 hook 进正被分解的 godfile。
4. **验证**：新测试过 + mutation 自证（把修复退化回去测试必须失败）+ 邻居测试 + `ruff check`。
5. **commit**：单关注点 message（`fix(<scope>): ...`，正文 2-5 行说清机制）。**自检**：`git log -1 --format=%B` 确认无 `Co-Authored-By` 行，有则 `git commit --amend` 剥离。
6. **PR 草稿**：写 `$CONTRIB/runs/$(date +%F)-issue<N>/PR-DRAFT.md`——完整可直接粘贴的 body：Summary / Changes（逐文件）/ Validation（测试+mutation 证据，真实数字）/ Related issue（`Fixes #<N>`）/ References。同目录 `BRANCH.md`：分支名、worktree 路径、测试证据摘要、README 一行「待人工审查后手动 push+建 PR」。
7. **收尾**：在当日 briefs 追加构建记录（issue/分支/测试结果/残留风险）；**终端末行明确输出「本地分支就绪，未 push——请人工审查」**。push 两路：用户手动 `git push fork fix/<slug>` + `gh pr create`（push 目标 remote 是 `fork`，`origin` 是上游 403）；或该项入 ready-queue 走 L2-A——微信批准后由 coder lane worker 全自动 push+建 PR（09-08 lane 改造起，**仅当 `config.allow_own_pr_push=true`**，当前已开；false=急停退回人工路）。

---

## 模式五：mail（GitHub 通知邮件三通道研判，由 run-watch 阶段 1.5 调起或手动）

输入 `$CONTRIB/mail-pending.json`（mail_gate.sh 预取：id/subject/from/to/date/message_id/preview）。文件缺失或空数组 → 输出「无待研判邮件」结束。**只依据 preview 研判，不碰邮件客户端**（himalaya 写操作绝对禁止；需要更多上下文时用 gh 实查对应 issue/PR——邮件是快照信号，gh 是事实源，hermes-contribution.md §9）。

逐封归入三通道：

| 通道 | 判定 | 动作 |
|---|---|---|
| **auto** | 无需人介入的流水线内部信号：维护者对我方 PR/issue 实质互动（→ `notify.sh event own-pr-activity --key mail-<message_id或id> --summary ...`）、新 issue 信号（→ 正常 scan rubric 简评入队 `rq.sh add`，走既有队列而非绕过）、CI/premise 变化需复验（→ 当日 briefs 记录） | 调既有通路，**不新增任何对外写动作** |
| **important** | 需要用户本人关注且时效敏感（微信推送，受每日 3 条告警硬闸）：维护者提出直接问题/要求我方行动、own-PR mergeable 翻转/被 close、我方关注 issue 出现占坑竞争、premise 死亡级资产变化 | `notify.sh event mail-needs-user --key <message_id 或 mail-<id>-<date>> --summary "<30 字内：发生了什么+为何重要>"` |
| **routine** | 盯梢类：triage 机器人互动、label 变化、无关仓库动态、CI 波动 | 追加当日 briefs 一节「## 邮件动态」（每封一行：主题→一句话），不推送 |

分级纪律（用户 09-07 拍板）：**宁进简报不进微信**——不确定 importance 时降级 routine；同主题多封（同 PR 评论连发）合并为一个 event，key 取最新 message_id。

卡模式（T3）：mail 研判由 run-watch 建卡（`--kind mail`，贡献卡 worker 执行本模式）。卡内约定：输入为 `$CONTRIB/mail-pending.json` 绝对路径（mail_gate 预取快照，只读）；三通道判定表以上表原文为准；**卡内禁碰 himalaya 写操作**（mark/move/delete/send 一律禁止，只依据 preview 研判，需要更多上下文用 gh 实查）；**完成后不要自行 commit-cursor、不动 mail-cursor.json**——游标由 run-watch 按卡终态（done + cursor 快照守卫）异步推进。

收尾：briefs 追加「## 邮件研判」统计行（auto/important/routine 计数）；**不要自己动 mail-cursor.json**——退出码 0 后 run-watch 会调 `mail_gate.sh --commit-cursor` 推进游标，研判中途失败则游标不动、pending 下轮重研判（event --key 保证重复研判不重复推送）。

---

## 模式六：digest 摘要卡（叙事告警三段式摘要+发送，由 notify.sh flush 调起，T5 起生效）

- 简报固定小节「AI 自主决策清单」（09-11 用户拍板）：从近 24h 的 verdict.json 收集 decision=auto 且 reasons 含「自决：」前缀的项，一行一条（rq-id + 按什么原则 + 定了什么）供用户回溯纠偏——用户纠的是原则，不是单条。

contrib 域告警推送的 AI 整理层卡化形态：notify.sh flush 遇叙事事件批（非机械类）时建 digest 卡（`--kind digest`），事件快照落 `$CONTRIB/pending/digest-<ts>.json`，worker 在卡内生成三段式摘要并经 notify 内部接口发送。**这是全流水线唯一允许 worker 调用微信外发的卡型**（外发消息规范：先 AI 整理后推送的实现载体）。

**worker 职责（按卡 body 顺序执行）**：
1. 读卡 body 给出的事件快照 JSON（权威数据源，只读）
2. 生成三段式摘要（规范见卡 body「摘要规范」段：发生了什么 → 为何重要 → 建议动作；≤300 字；首行报头 `🟠【contrib 告警】MM-DD`；黑话对照表翻译，不照抄；同类事件归并）写入卡 body 指定的摘要输出文件（`$CONTRIB/pending/digest-<ts>.digest.md`）
3. 调 **`bash scripts/contrib/notify.sh send-digest --digest <摘要文件> --batch <事件快照>`**（普通命令形态，-q 模式可用）
4. 据 send-digest 输出收尾：stdout `OK` 且批次快照尾部出现 `sent:true` 控制行 → kanban_complete（**必须同时传 summary 与 result**）；stdout `FAIL <原因>` → 同样 complete 但 summary 写明 FAIL 原因（限额/锁超时/发送失败/空卡）

**红线（钉死）**：
- **唯一外发通道 = `notify.sh send-digest`**——禁 hermes send 直调、禁其他任何外发；send-digest 内部已接空卡守卫/日 3 条限额/dry-run/账本标记，worker 不重复做这些事
- **永不 raw dump**：外发内容只允许摘要文件，原始事件 JSON 绝不直推（卡路/fallback 路/osascript 兜底路三路同样成立）
- -q 模式禁脚本形态（`python -c` / `jq -e` / 任何 `* -e`）
- 限额拒发（`FAIL limit`）是**正常失败收尾**，不是异常——summary 写明原因即可，编排层（flush flight 检查）对失败终态自动走 fallback 兜底
- attempts 计数由 flush fallback 路管理，worker 不碰事件账本（send-digest 只按批次 keys 标 pushed）

---

## 异常处理

- gh 网络抖动：重试 2 次（sleep 5/15），仍败则日志记一笔、简报标「本轮缺失」，下轮自愈
- pending 里 issue 已被关闭/已出现 PR：研判时如实降级（skip + 原因），不硬做
- 自动构建失败（premise 不过/测试无法写/环境问题）：runs/ 留失败记录与原因，不硬凑 PR
- deep-check 中途失败：`rq.sh set <id> failed`，draft 停在最后版次、run.log 留证；预算不返还（默认）；次日 gate 自动重试
- 每次 scan/radar 花费与结果异常时，在简报头部加一行 `⚠` 注记，并 `notify.sh event pipeline-failure`（微信层由 run-watch 尾部统一推送）
