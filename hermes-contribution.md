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

## 相关记忆
- `hermes-contribution-followups.md` —— 4 个 PR 的具体进度 + sweeper 反馈机制
- `hermes-weixin-rate-limit.md` —— 限流根因（weixin iLink）
