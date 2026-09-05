---
name: contrib-watch
description: hermes 上游机会流水线——增量扫描新 issue 后智能研判（评分→五分类决策）、停滞 PR 雷达（salvage 供给）、本地自动 PR 构建（产出分支+PR 草稿，绝不 push/绝不建 PR）、就绪队列快车道（验证付清项→微信 L2-A 审批环）。四种模式：scan（研判 pending 命中+入队）、radar（每日雷达+自有资产+premise 复验+至多 1 个自动构建）、build <issue#>（本地 PR 构建流水线）、deep-check <rq-id>（三轮审自动化：strategist preflight+fresh-context 红队）。
argument-hint: [scan | radar | build <issue#> | deep-check <rq-id> --phase preflight|redteam] [附加说明]
allowed-tools: Read, Write, Edit, Grep, Glob, Bash, Agent
---

# contrib-watch — hermes 上游机会流水线

数据目录 `$CONTRIB = /Users/stringzhao/workspace/martin/contrib-data/`（运行产物，不入库）：
`config.json`（旋钮）/ `scan-cursor.json`（游标）/ `pending-hits.json`（待研判）/ `ready-queue.json`（就绪队列，唯一写入口 `scripts/contrib/rq.sh`）/ `budget.json`（深检预算账本）/ `pending/<rq-id>.md`（待审成稿）/ `events.jsonl`（告警账本）/ `briefs/YYYY-MM-DD.md`（每日简报）/ `radar/YYYY-MM-DD.md`（雷达）/ `runs/`（构建+深检记录）/ `ledger.md`（观察台账）/ `logs/`。

策略知识库（研判/构建前必读，是评分与纪律的唯一权威）：
- `/Users/stringzhao/workspace/martin/hermes-contribution.md`（共建策略 + §10 sweeper 机制）
- `/Users/stringzhao/workspace/martin/.claude/agents/hermes-contrib-strategist.md`（形态选择框架/锚定铁律/验证纪律全文）

对外动作分级（不可逾越）：**scan/radar/deep-check = L1 只读上游**（gh 读 + 本地文件写；微信推送/写 ready-queue 是本地渠道动作，属 L1）。**「草稿自动备好 + 推送审批」属于 L1；发出（gh 写：评论/issue/PR/push）永远过 L2**，两路等效：**L2-A 微信批准**（ready-queue `awaiting-approval` → 用户「批 #rq-id」→ hermes 侧执行方 TTL 复验 → 落弹 → martin/approved.log）或 **L2-B 会话内明示**（同样记 approved.log）。两路执行前都查 approved.log 去重。**所有对外草稿必须过 strategist preflight 才能进 awaiting-approval**（deep 车道另加 fresh-context 红队；probe 车道单轮 strategist 免红队）。**build 只到本地为止**——`git push`/`gh pr create` 仅当对应 own-PR 项获 L2-A 批准**且** `config.allow_own_pr_push=true` 时由执行方执行，其余场景绝对禁止。

---

## 模式一：scan（研判 pending 命中）

launchd 每小时粗滤后有域内命中时调用。步骤：

1. 读 `$CONTRIB/pending-hits.json`。空数组 → 输出「无待研判」结束。
2. 逐条 `gh issue view <N> --repo NousResearch/hermes-agent`（正文+labels+评论数），对每条打分（满分 15）：

| 维度 | 0 | 1 | 2 | 3 |
|---|---|---|---|---|
| **领域契合** | desktop/无关 | 边缘（browser/kanban/单平台冷门） | 相邻（tools/cli/update） | 核心链路（cron、gateway、sessions/state.db、weixin、compression、memory） |
| **独家证据/自利** | 无 | 间接相关 | 影响我们部署 | 我方有生产取证/取证能力直接适用（weixin 取证包、state.db 修复线、forensics 栈） |
| **空间状态**（实查） | 拥挤（≥3 PR 或活跃车+无空间） | 活车（他人 PR 在动） | 死车（PR 停滞 >14 天） | 空（无 PR 锚 + substance 查重也空） |
| **需求真实度** | needs-repro/无细节 | 单一环境无实据 | 有 repro/日志 | 生产环境+多站点共鸣/官方已跟踪的类 |
| **可剥离性** | 大簇/多关注点 | 需维护者先拍板方向 | 可拆但依赖多 | 单关注点、可测、可复现 |

   查重纪律：空间状态必须实查 `gh pr list --search "<N> in:body"`；标题含竞品机制关键词再搜一轮 PR（substance 层）。时间紧张时可先按 labels/正文粗判，但 own-PR 候选必须实查后才能给。

3. 五分类决策：**own-PR**（≥11 且 空间状态=3）/ **probe-salvage**（死车 2 分档，写 probe 评论草稿进简报）/ **review-evidence**（活车但我方有独家证据，写 review 要点进简报）/ **watch**（写入 `ledger.md`，含复检日期）/ **skip**。
3.5 **入队就绪队列**：决策 ∈ {own-PR, review-evidence, probe-salvage} 且得分 ≥ `config.ready_min_score`（默认 11）→ 逐条 `scripts/contrib/rq.sh add`：
   - `--premises-json` 必填：本项成立所依赖的关键前提逐条登记（`{"claim": "…", "evidence": "file:line 或 PR 号", "verified_at": "…"}）`——radar 复验与执行前 TTL 复验都以此为清单
   - `--ammo-json`：我方独家弹药清单（一句话/条）；`--age-hours`：issue 龄（排位新鲜度用）；probe-salvage 同时把完整 probe 草稿写 `$CONTRIB/pending/rq-<日期>-<issue>.md` 并在 `--note` 里注明草稿路径
   - 简报条目「下一步」改指 `rq-<id>`（不再写"建议手动 build/发"）
4. 追加 `$CONTRIB/briefs/$(date +%F).md`（格式见下），然后 `scan_gate.sh --drain` 清空 pending。（微信推送由 run-watch.sh 尾部统一 flush，模式内不直接调 hermes send。）
5. 终端输出一行摘要清单（编号/标题/决策/分数 + 入队 id）。

简报条目格式：

```markdown
## #<N> <标题>
- 决策：<own-PR | probe-salvage | review-evidence | watch | skip>（<得分>/15）
- 空间：<实查结果一句话——锚/竞品 PR 编号与活跃度>
- 为什么：<一句话我方角度>
- 下一步：<own-PR→"雷达将自动构建"或"建议手动 /contrib-watch build <N>"；probe-salvage→附 probe 草稿；review-evidence→附 review 要点；watch→复检日期>
```

---

## 模式二：radar（每日雷达，08 窗口）

1. **停滞 PR 雷达**：`gh pr list --state open --limit 1000 --json number,title,author,updatedAt,createdAt,labels`（**全量口径**——`--limit 300` 在洪流下只盖 ~3 天，09-04 已实测失效），过滤 updatedAt 距今 > `config.stale_pr_days`（默认 10）天、作者排除 `teknium1 / OutThisLife / app/ 前缀 / hermes-sweeper`、排除 duplicate 标签。对 top 候选（按域契合排序，最多 15 条）逐个 `gh pr view` 补：是否有 issue 锚、mergeable、行数、我方契合点。给建议动作（probe-salvage / review / watch / skip）。
2. **自有资产盘点**：`gh pr list --author strzhao --state open` 逐个看 updatedAt/mergeable/reviews/comments——**写 `$CONTRIB/assets-snapshot.json`（PR→{updatedAt, mergeable, reviewDecision, 最新评论作者}）并与上份快照 diff**：新增维护者/sweeper/collaborator 评论、mergeable 翻转、MERGED、>7 天停滞标黄 → `notify.sh event own-pr-activity --key "<PR>-<事件>-<日期>"`。停滞 >7 天的在简报给 ping/再 rebase/关停建议（ping 是对外动作，只建议不执行）。
3. **观察台账复检 + ready-queue premise 复验**：读 `ledger.md`，到期 watch 项逐个复查状态，状态变化则更新台账并写进简报。然后遍历 `$CONTRIB/ready-queue.json` 中 state ∈ {queued, awaiting-approval} 的活项，**逐条实查 premises**：issue 仍 OPEN？`gh pr list --search "<N> in:body" --state open` 无新占坑？**in-body 抓不到机制占坑（#103315 教训：PR 不引用 issue 号也能占坑，08:29 挂出、08:40 复验漏检）——还须按 issue 的机制关键词/触碰文件再搜一轮**：`gh pr list --search "<机制词1> OR <机制词2>" --state open` + 对照 touched paths；关键 file:line 在当前 origin/main 仍成立？——任一死亡 → `rq.sh set <id> expired` + `notify.sh event probe-premise-dead --key "<id>-<日期>"`（#102413 教训：过期 premise 的审批卡绝不能推）。
4. **自动构建**（本日仅当 `config.auto_build=true` 且当日 `runs/` 无已完成构建）：从今日 briefs 里挑分数最高且决策=own-PR 的 issue；≥`config.min_build_score` 则直接执行模式三（构建 1 个）；没有候选则跳过。
5. 产出 `radar/$(date +%F).md`（两节：外部雷达 / 自有资产+台账+构建记录+ready-queue 复验结果），并在 `briefs/$(date +%F).md` 追加「⭐ 雷达摘要」节。（微信推送由 run-watch.sh 尾部统一 flush。）

---

## 模式四：deep-check <rq-id> --phase preflight|redteam（三轮审自动化，由 launchd 09:37 调起或手动）

对就绪队列某项执行深检准备。**两阶段由两个独立 `claude -p` 进程分别执行，中间只靠文件版次传递（v1 草稿 → preflight 吸收 → v2 → 红队吸收 → final）= 结构性 fresh-context**。全程零 gh 写、零 push、不调 hermes send。

**`--phase preflight`**（阶段 1）：
1. 读 `$CONTRIB/ready-queue.json` 该项（premises/ammo/score）+ 简报中原始素材（review 要点/probe 草稿）。
2. **必须**用 Agent 工具调 `hermes-contrib-strategist` 子代理出 preflight 审视报告 → `$CONTRIB/runs/deep-check/<id>/preflight.md`（红旗清单/形态裁决/数字修正/发不发结论）。
3. 对报告逐条「亲手核」：对当前 origin/main 实查（修行号、核事实），吸收成草稿 v2 写 `$CONTRIB/pending/<id>.md`（头部注释记版次与依据）。
4. `rq.sh set <id> deep-check`（阶段开始时）→ 阶段末不推进状态（等 redteam）。

**`--phase redteam`**（阶段 2，全新进程，**不得读 preflight.md 结论先入为主**）：
1. 只读 `$CONTRIB/pending/<id>.md`（v2）+ 必要的上游实查工具。
2. 把 v2 拆成可验证断言编号 A1..An，逐条独立核验（log 引用逐字比对、时长算术复算、引用保真、敏感信息扫描、语气/定位终检）→ `$CONTRIB/runs/deep-check/<id>/redteam.md`（必修/建议分级）。
3. 必修+建议全吸收 → final 版（覆盖 `$CONTRIB/pending/<id>.md`），history 记 `redteam_absorbed=n/m`；`rq.sh set <id> awaiting-approval --note "final 就绪"`。

**失败处理**：任一阶段 exit≠0 → `rq.sh set <id> failed --note "<阶段>"`；预算按 `config.refund_failed_deep_check` 决定是否返还（默认不返还）；次日 gate 可自动重试（`failed → queued` 迁移由 gate 执行）。

---

## 模式三：build <issue#>（本地 PR 构建流水线）

**铁律（每一步都要自检）**：只在本地 worktree 工作；**禁止** `git push`、`gh pr create`、`gh api` 写方法、`gh pr merge`；上游 commit **不带 Co-Authored-By trailer**；主 checkout `~/workspace/hermes-agent` 只 fetch 不 checkout（worktree 范式）。

0. **前置核查（任一不过→放弃并写明原因进 runs 记录）**：
   - `gh issue view <N>` 仍 open
   - `gh pr list --search "<N> in:body" --state open` 无占坑 PR（出现竞品→改判 review-evidence，停）；**另按机制关键词搜一轮**（in-body 抓不到机制占坑，#103315 教训）
   - substance 查重：按机制关键词 `gh search prs` 一轮，无活跃竞品
   - **premise 四问**（strategist agent §5）：intentional design？确切行为行？原本在保护什么？复活被否决方向？——答不全→停在「补证据」建议
1. **worktree**：`git -C ~/workspace/hermes-agent fetch origin main` → `git worktree add ~/workspace/hermes-contrib-<N> -b fix/<slug> origin/main`（slug 从标题提炼，≤5 词）。
2. **复现优先**：能写失败测试先写（垂直回归，走公开入口；参考 AGENTS.md Testing 段与 strategist §5 测试三禁令）。跑 `scripts/run_tests.sh` 范式验证测试在修复前失败。
3. **修复**：最小 diff；行为配置走 config.yaml 不走 env；不碰 `uv.lock`；不加新 hook 进正被分解的 godfile。
4. **验证**：新测试过 + mutation 自证（把修复退化回去测试必须失败）+ 邻居测试 + `ruff check`。
5. **commit**：单关注点 message（`fix(<scope>): ...`，正文 2-5 行说清机制）。**自检**：`git log -1 --format=%B` 确认无 `Co-Authored-By` 行，有则 `git commit --amend` 剥离。
6. **PR 草稿**：写 `$CONTRIB/runs/$(date +%F)-issue<N>/PR-DRAFT.md`——完整可直接粘贴的 body：Summary / Changes（逐文件）/ Validation（测试+mutation 证据，真实数字）/ Related issue（`Fixes #<N>`）/ References。同目录 `BRANCH.md`：分支名、worktree 路径、测试证据摘要、README 一行「待人工审查后手动 push+建 PR」。
7. **收尾**：在当日 briefs 追加构建记录（issue/分支/测试结果/残留风险）；**终端末行明确输出「本地分支就绪，未 push——请人工审查」**。push 两路：用户手动 `git push fork fix/<slug>` + `gh pr create`（push 目标 remote 是 `fork`，`origin` 是上游 403）；或该项入 ready-queue 走 L2-A——微信批准后由 hermes 侧执行方 push+建 PR（**仅当 `config.allow_own_pr_push=true`**，默认关）。

---

## 异常处理

- gh 网络抖动：重试 2 次（sleep 5/15），仍败则日志记一笔、简报标「本轮缺失」，下轮自愈
- pending 里 issue 已被关闭/已出现 PR：研判时如实降级（skip + 原因），不硬做
- 自动构建失败（premise 不过/测试无法写/环境问题）：runs/ 留失败记录与原因，不硬凑 PR
- deep-check 中途失败：`rq.sh set <id> failed`，draft 停在最后版次、run.log 留证；预算不返还（默认）；次日 gate 自动重试
- 每次 scan/radar 花费与结果异常时，在简报头部加一行 `⚠` 注记，并 `notify.sh event pipeline-failure`（微信层由 run-watch 尾部统一推送）
