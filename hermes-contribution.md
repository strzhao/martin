# hermes 开源共建切入思路

> 沉淀于 2026-07-31。基于近 30 天 250 个 merged PR 的数据分析 + kshitijk4poor（唯一高频外部共建者，23 PR）的打法逆向。**做 hermes 共建前先读此文档。** 数据是快照会过时，规律性结论才是重点。

fork：`strzhao/hermes-agent` → `NousResearch/hermes-agent`。gh token 已加 workflow scope。

---

## 1. 现状诊断：PR 为什么没合（不是"太小"）

我的 3 个 PR（#65100 qqbot tier / #65112 yuanbao adapter flag / #65794 image feedback）提交后长期无活动。**真实原因（按权重）：**

1. **无 issue 支撑** —— 是"自己发现的 gap"，上游不知道有用户需要。kshitijk4poor 的 23 个 PR 几乎每个都 `closes #issue` 或 `salvages #PR`，**有明确需求来源**。
2. **领域冷门** —— qqbot/yuanbao 是中国平台，上游欧美 maintainer 无体感；display tier 是边角配置。
3. **影响面窄** —— 只影响特定平台用户，不碰核心链路。

**"太小"是误判**：被合的外部 PR 中位数 200-500 行，≤20 行的小改也合了 29 个。规模不是障碍。
**"被冷落"也是误判**：大量外部 PR 都停滞在 07-12（20+ 个），是普遍现象不是针对我。

---

## 2. 被合入 PR 画像（30 天 250 个，截至 2026-07-31）

| 维度 | 分布 |
|------|------|
| **作者** | 内部 ~84%（teknium1 110 含 sweeper bot / OutThisLife 75 / app/hermes-seaeye 19 是 fmt bot / rob-maron 4）；外部只有 **kshitijk4poor 高频（23）**，其余新人各 1-2 个 |
| **类型** | fix（104）>> feat（19）> refactor/perf（各 13）—— **修复类是绝对主流** |
| **领域** | **desktop（44）> js(19) > gateway(18) > photon(8) > cli(7)** —— 桌面端最活跃 |
| **规模** | 中位数 220 行；主流 101-500 行（105 个）；≤20 行 29 个；>500 行 74 个 |

**需求来源（看 kshitijk4poor 样本）：**
- `salvage of #74522` / `salvage #64141, closes #25016` —— 捡起停滞 PR
- `(#70856)` / `(#65977)` —— 关联明确 issue
- 主题：micro-compaction / MCP loop drain / shutdown memory flush / cron failure / LSP 回收 —— **全是核心链路可靠性 bug**

---

## 3. kshitijk4poor 的打法（黄金教材，逆向出的 4 条）

1. **salvage 停滞 PR** —— 大半 PR 是 `salvage of #N`，主动捡起别人废弃/停滞的 PR 重新推进。**维护者最感激这种行为**（清理他们的 backlog）。
2. **每个 PR 关联 issue/PR 号** —— `closes #N` 或 `salvages #N`，有明确需求来源。
3. **专攻核心链路可靠性** —— compression / mcp / shutdown / cron / cli，影响所有用户的真 bug。
4. **先用 chore 刷信任** —— 1-2 行的 AUTHOR_MAP 映射、ci retry，低门槛建立信任后再上大 PR。

---

## 4. 共建三路径（按推荐度）

> **⚠️ 09-02 更新**：本节写于 07-31 快照。anchor 占位路径已被 AI farm 生态卷死（issue→PR 以小时计），三路径的现行收窄版见 **§11 策略主轴 2.0**——salvage 流程（§5）仍有效，成为第三腿。

### 🌟 路径 A：salvage 停滞 PR（最优，kshitijk4poor 核心打法）
找"sweeper review 过 + salvageability=high/medium + 作者停滞 >15 天 + mergeable=dirty"的 PR，接手推进。维护者优先合"推进停滞工作"的人。

### 路径 B：认领 open issue（有需求来源）
找高反应 issue（用户痛点）：`gh issue list -S "is:issue is:open sort:reactions-+1-desc"`。挑能复现、影响核心链路的 bug。

### 路径 C：核心链路 bug（自找，最难）
compression / mcp / shutdown / cron / gateway 可靠性。需深挖代码，但影响面大。

---

## 5. salvage 流程（学 kshitijk4poor）

1. **礼貌询问作者** —— 在原 PR 评论："还在推进吗？这个 bug 我也碰到，若你无暇我可接手 rebase + 按 sweeper 反馈完善，新 PR 会标 `salvages #N`"。
2. **等 3-7 天无响应** → 确认放弃。
3. **fork 原作者分支** → `rebase` 解冲突（dirty 的 PR 必有冲突）→ 按 sweeper 指出的 Problem 补全 → 新 PR 标题/描述写明 `salvages #N`，@ 原作者致谢。
4. **sweeper 会自动 review 新 PR**（因为是新 push），这是复审闭环的触发点。

**实操验证（2026-07-31，PR #75453 salvage #63004，autopilot fast mode 跑通）**：
```bash
git fetch origin pull/63004/head:salvage-base        # 拉原 PR head
git checkout -b fix/<slug>-salvage origin/main        # 基于最新 main
git cherry-pick <salvage-base 的 head>                # 保留原作者 author credit
# 解行号冲突（rebase 自动，07-12 main → 当前 main 漂移）
# 蓝队补 sweeper 修复作为新 commit（其上）
git push fork fix/<slug>-salvage
gh pr create --head strzhao:fix/<slug>-salvage --body "Salvages #N (credit @原作者)..."
```
cherry-pick 保留原作者 author（committer 变成本机），credit 透明。红队 `.acceptance.test.py` 文件名含多个 `.` → pytest collect 需 `--import-mode=importlib`（本地 QA gate，不进 PR）。

**⚠️ cherry-pick 后审查原作者全部改动**：原作者 commit 可能混入 scope 外的改动。例：salvage #63004 时原作者顺手加了个 `test_read_events_raises_when_ws_none`（测 WebSocket guard），和 ffmpeg drain 无关 —— sweeper 复审（仍 high）要求聚焦，删掉后即过。salvage 前过一遍原作者 diff，剔除无关的（或拆单独 PR），避免 sweeper 挑「scope 不聚焦」。

---

## 6. 当前 salvage 候选清单（截至 2026-07-31）

| PR | 作者 | sweeper | 与我的契合 | 状态 |
|----|------|---------|-----------|------|
| **#63004** qqbot ffmpeg drain | chuenchen309 | **high**（"real QQ inbound-audio failure mode"，drain with communicate 方向认可）| ⭐ 完美（qqbot 专长）| dirty + 停 07-12，作者放弃 |
| #63005 composite tool_call id | liuhao1024 | medium（"normal tool-execution path is a real current-main failure"）| agent 核心链路 | 停 07-12 |
| 更多 | — | — | — | 见下方查询命令 |

**找更多 salvage 候选：**
```bash
# 停滞 >15 天的外部 PR
gh pr list --repo NousResearch/hermes-agent --state open \
  --search "updated:<2026-07-15 -author:teknium1 -author:OutThisLife" --limit 25

# 其中 sweeper review 过的（salvage 价值高）
gh api repos/NousResearch/hermes-agent/pulls/<N>/reviews \
  --jq '.[]|select(.user.login=="teknium1")|.body'
```

---

## 7. 写 hermes PR 的 sweeper 红线（避免被挑）

1. **不断言私有字典 identity**（`_PLATFORM_DEFAULTS[x] is _TIER_LOW`），改测 `resolve_display_setting(...)` 返回值（resolver 外部行为）。
2. **不冗余 snapshot 无关平台默认值**（各有专属测试）。
3. **行为配置走 `config.yaml`** 的 display/streaming 路径，不走 `HERMES_*` env var（AGENTS.md 规范）。
4. **新逻辑与现有同类机制对齐**：streaming 非编辑守卫 run.py 有 proxy/本地两处 setup 都要覆盖；限流已有熔断器别另起。
5. **不读源码形态**：测试禁用 `inspect.getsource`（AGENTS.md:1380），改用 behavior 测试或 `inspect.signature`（签名 API 检查）。

---

## 8. 候选 gap（自己开新 PR 的方向）

- **adapter flag 补齐**：whatsapp_cloud / msgraph_webhook / webhook / relay 无 `edit_message` override 但未声明 `SUPPORTS_MESSAGE_EDITING=False`。display 侧 whatsapp_cloud 已锁 `_TIER_LOW`、其余在 `_TIER_MINIMAL` 间接挡。可提统一补 flag 的 PR（但先搜有没有 issue 支撑）。
- **display 默认值**：追到 `_PLATFORM_DEFAULTS` tier 4 层链（显式 override > global display > _PLATFORM_DEFAULTS > _GLOBAL_DEFAULTS > default= 末端 no-op）。
- **限流 bug 家族**：上游已有活跃 PR（#31393/#35714/#18105/#38838），**别开竞争 PR**。

---

## 9. 邮件时滞坑（核实 PR 状态时注意）

review 通知邮件是 sweeper 发 review 那刻的快照，**不会因后续修复 push 而更新**（GitHub 不发"已修复"邮件）。morning cron 简报读这些旧邮件时，"必须解决/待处理"措辞可能是时滞。**核实用 `gh pr view <n> --json headRefOid,mergeable,mergeStateStatus` 看远程实际 head + mergeable，而非邮件措辞。**

---

## 10. sweeper 机制深挖（2026-08-23 全 gh 实证）

**回答「为什么有些 PR 有 sweeper review、有些没有」：不取决于 PR 质量/是否 force-push，取决于创建时间是否落在 sweeper 活跃窗口。**

### triage 生态全景（4 角色）

| 角色 | 行为 | 证据 |
|------|------|------|
| **alt-glitch**（AI triage） | PR 创建后 ~1-4h 打全套标签（type/comp/P\*/`sweeper:risk-*`/`needs-decision`）+ 发 "*This was generated by AI during triage*" 查重评论；**只跑一次，force-push 不重跑** | 9 个 PR 的 label events 全在创建当日；#92949/#92929 被其查重评论点 dup 后作者当天自行关闭 |
| **hermes-sweeper**（@teknium1 账号） | 发 "Automated hermes-sweeper review"（keep_open salvageability + Problems）；AGENTS.md 授权按 `implemented_on_main`/`cannot_reproduce`/`incoherent` 三理由关 PR（品味类 close 留给人类）；**用 hermes 自身跑**（env docs：HERMES_INFERENCE_MODEL "useful for scripted callers (sweeper)"）；也补打 sweeper:risk-\* 标签 | #65794(07-18)/#75453(07-31)/#67660(07-25) 有完整 review；#86183 在 08-16 01:55 被补打 `sweeper:risk-compatibility` 但**无 review 帖** |
| **teknium1 本人** | 日合 30-40 PR（几乎全自己当日开当日合）；外部 PR 合入全走他个人注意力 | 08-23 当日 40 merged = 36 teknium1 + 3 kshitij(同日) + seaeye |
| 社区 AI reviewer | coderabbit / Enough1122 / GottZ，评论性质无约束力 | — |

### 关键结论：sweeper 完整 review 模式 8 月静默

- 7 月中~7 月底创建的 PR 拿到过完整 sweeper review（我方 #65794/#75453、他人 #67660）
- **8 月创建的 PR（我方 + 他人）零 sweeper review**：#87655/#86062/#84006/#85548/#86622/#81214 全只有 alt-glitch 标签
- 08-06 尚见 sweeper 活动（review PR#80009），之后未见新 review 帖
- → **"等 sweeper 复审"当前是无效策略**；force-push 最多触发标签补打（#86183 的 08-16 标签），不触发 re-review
- → **旧 review 会被删**（#65100/#65112/#75771 的 sweeper review 已从 API 消失）——**判断 PR 是否被 triage 过看 labels，勿看 reviews**

### 其它实证

- **mergeable=UNKNOWN 不是封印**：head 落后 >1000 的 PR 普遍 UNKNOWN（#86680 挂着 UNKNOWN 照样 MERGED）；GitHub 对极落后 head 懒计算，rebase 后恢复 MERGEABLE
- **needs-decision 是 alt-glitch 的 triage 标签**（#81214/#85548 创建当刻打的），非维护者手动标记，含义 = 需人拍板
- **当天外部快速关闭全是作者自己关的**（跟 alt-glitch 查重评论走），未见 sweeper 行使关闭权——keep_open 类 PR 无被自动关风险
- **外部 PR 快速合入通道仍在**：#86680（P2+新症状）约一天合入——**新鲜 + P2 + 真实症状**依然快

### 我方 9 PR 处置结论（08-23）

| PR | 状态 | 判断 |
|----|------|------|
| #86183 | **MERGEABLE/CLEAN** + P2，head 落后 1296 | 最有价值的等待资产，无任何阻塞纯等 teknium；策略改 rebase 后精准 ping |
| #81214 | OPEN+needs-decision，**内容已随 #85452 进 main（08-13）** | ⚠️ dangling——应自己关闭（评论标 superseded by #85452），释放 triage 注意力 |
| #85548 / #86622 | P2，08-16 后无动静 | 正常排队；#85548 safe-mode 语义需维护者拍板 |
| #75771 / #75453 | sweeper high/medium 已处理，head 落后 4000+ | 有效资产，下次触碰时 rebase |
| #65100 / #65112 | P3 冷门域，落后 4000+ | 无 issue 支撑难合；冻结不再投入，或关闭止损 |

### 09-02 规律更新：anchor 层已卷死，evidence authority 是唯一持续优势

09-02 全量扫当天 60 条 issue 的实证：**头部候选 issue 全部在当天（数小时内）被 PR 占坑**——#101093→#101095、#101064→#101085+#101081、#101039→#101055、#100946→#100976、#100943→#100974、#100954→#101108。背后是一批高velocity AI 贡献者（dionysoslin615/foma-agent/chelsealong/Sahilvishnaliya/686f6c61/mustafaturksavas…），单日 issue→PR 转化以小时计。**结论**：① §4 路径 A/B/C 中的「空+锚占位」（#96472 模式）对人类节奏已基本不可用——发现即占坑的窗口 <24h；② 模式选择框架收窄为：**evidence authority**（生产取证/独家证据生态，如 weixin TTL 模型、state.db 修复线）+ **salvage**（等 AI 批量 PR 停滞后捡，供给端比以前充足）+ **substance 层查重后剩余人迹罕至的深水区**；③ #86622 被 teknium salvage 保署名合入（09-02）证明：写得「单关注点+可剥离」的 PR 即使不合，也在 maintainer 的 salvage 池里增值——own-PR 仍值得提，但价值实现形式变了。

---

## 11. 策略主轴 2.0：review-first，让维护者做 pick（2026-09-02 拍板）

> 取代 §4 的路径推荐（§5 salvage 流程仍有效，成为第三腿）。用户拍板：专注高质量 review，review 中搭车我方 commit，让收敛者 pick。

### 证据链（09-02 侦察 + 我方历史四实证）

- **上游已是 AI farm 生态，三种架构并存**：① 自锚打包（@leomcamilo：#101093 issue 08:22 发 → #101095 PR 08:23 开，**1 分钟间隔**，长文 issue+PR 预打包背靠背提交）② 消防 hose 竞速（@fangliquanflq：单日 7 PR、30 分钟 turnaround 认领他人 issue；#101064 被 @rainbowgore/@JoaoMarcos44 30/36 分钟双抢）③ issue 农场（@dionysoslin615：只发 issue + 58 次 DeleteEvent=agent 临时分支清理指纹；@foma-agent 简介自白 "An AI agent with human oversight"）。commit trailer 全部干净（同样遵守上游无 trailer 惯例）
- **当日 8 个抢坑 PR 零合入**（7 OPEN + 1 CLOSED）→ **anchor ≠ merge**；瓶颈=维护者注意力+质量+证据。分钟级占坑竞速不参与，SLA=当日内+决策质量（唯一例外：深水区+独家证据域，如 weixin 族）
- **三代收敛文化**：erosika #83500 → kshitij #85452 → teknium #99375/#100916，皆从 PR 池 cherry-pick 保署名收编
- **我方四实证**：#86622 被 #100916 salvage（3 commits 署名保留，09-02）/ 1d0e71e822 被 #86062 cherry-pick（"Adopted your idea @strzhao"）/ #96437 review 33 分钟被全盘接受 / #94862 收敛覆盖我方 review 指出的两残余缺口（无 credit 但实际塑形了收敛内容）

### 三腿分工

| 腿 | 动作 | 触发条件 |
|---|---|---|
| **evidence authority** | 生产取证型 review/评论 | 域内 PR/issue + 我方独家证据（weixin TTL/取证包、state.db/FTS、cron 投递可观测性）|
| **cherry-pick invitation** | review 指出缺口 + offer 库存 commit（#86062 模式）| review 真发现缺口 && 库存有货 |
| **salvage** | 停滞 PR 雷达 → probe → 接手（§5 流程）| farm 洪水 → 批量停滞的工业化供给 |

### review 红线（COI 防御）

1. 主载荷 = **对维护者的验证价值**：file:line receipts + mutation 自证（#96437 评论格式为模板）
2. 自己的 PR/commit 只在**缺口驱动**场合出现；没货就纯 review，不硬带
3. offer 措辞规范（**09-07 #103650 教训**：lift/absorb 对称措辞 → substance 被逐字采纳但作者默认走成本最低的 absorb 路径，我方 2 commits 署名归零）——**排序推荐，永不并列**：
   - ① **lift 保署名 = 显式首选**：「the filters and tests lift as one small commit keeping authorship」
   - ② absorb 须点名 credit：「if you'd rather rewrite it yourself, a Co-authored-by on the absorbing commit would be appreciated」
   - ③ follow-up PR = 我方兜底（对方两条都不要时才摆出）
   - 模板：「这个缺口我有一个单关注点 commit 已修（fork sha），测试齐全——**首选**你整块 cherry-pick/rebase（署名保留）；如你倾向自己重写，麻烦在该 commit 上带 Co-authored-by；两者都不合适我再出 follow-up」
   - **禁语**：「随你方便」/「equally fine」/任何把 lift 与 absorb 等权呈现的句式
4. **每周深检预算 1-3 个**（三轮验证 strategist→亲手核→fresh-context 红队成本高）；其余新 PR 只内部研判不发帖——不做全仓免费 QA（~~09-02 定 1-3/周~~ **09-04 用户拍板放宽为周 30/日 3——token 充裕，配额只做防突发节流；COI 防线移由 rubric 门槛 + premise 复验 + 每项微信审批承担**；由 `contrib-data/budget.json` 机械记账，散文预算状态以账本为准）
5. 筛选 rubric：**域契合 × 合入临近度（CI 绿/review 收敛/mergeable）× 独家弹药 × 可收敛性 × 作者质量史**

### §11.1 执行通道机械化（09-04 上线：ready-queue + L2-A 微信审批环）

- **入队**：scan/radar 把「验证成本已付清、只差 L2 批准」的项写 `contrib-data/ready-queue.json`（唯一写入口 `scripts/contrib/rq.sh`；premises 逐条登记，radar 每日复验 + 执行前 TTL 复验双保险——#102413 教训制度化）
- **准备**：launchd 09:37 对预算内 top1 自动三轮审（两次独立 `claude -p` 进程 = 结构性 fresh-context；probe 车道单轮 strategist 免红队、不占深检预算）；成稿推微信 🟡 审批卡（tunnel 只读 URL，审后即删）
- **执行**：用户「批/改/否 #rq-id」→ hermes 侧 `hermes-contrib-l2` skill：TTL 复验 → 逐字投递 → approved.log（L2-A，与会话内 L2-B 等效且互查去重）→ 回执；48h 搁置（09:17 cron 对账）。own-PR push 另需 `allow_own_pr_push=true`（默认关）

### 可 pick 库存台账（资产；review 是分发渠道）

| 资产 | 域 | 搭车场景 |
|---|---|---|
| #96472 import sanity canary（CI 绿、review 闭环、等复审）| gateway 启动/lifecycle | 同域 PR review 顺带提 |
| #85548 safe-mode memory provider（needs-decision）| config/safe-mode | 同域 issue/PR |
| #75771 poll-loop guard salvage / #75453 ffmpeg drain salvage | process/cron 执行 | process 域 PR review 时 offer rebase |
| #65794 image feedback 层 | vision/gateway 图片 | 图片路由域 PR（#94423 watch 中）|
| 1d0e71e822（FTS 四点加固，在 #86062 内）| SQLite/FTS | state.db 损坏族收敛（正在进行时：#101093/#101064 + 当日 4 PR）|
| 方向 3 cached-output 重投（#16645 salvage，未开工）| cron 投递 | 按需生产 |

### 漏斗度量

review → adoption（点被采纳）→ **pick（commit 被收编入 main，graph 亮灯）** → 关系信号（@提及/直接 ping/进收敛者视野）。review 本身不入 graph，**pick 才是终极产出**；库存是资产、review 是渠道、信任是复利。

## 相关记忆
- `hermes-contribution-followups.md` —— 4 个 PR 的具体进度 + sweeper 反馈机制
- `hermes-weixin-rate-limit.md` —— 限流根因（weixin iLink）
