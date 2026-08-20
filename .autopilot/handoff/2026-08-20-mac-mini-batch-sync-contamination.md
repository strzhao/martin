# Handoff：Mac mini batch-sync 污染 hermes PR 分支事故修复

> 生成于 2026-08-20，来自 MacBook（HIH-L-7478）的排查会话。
> **本文档是给 Mac mini 上的 AI 看的操作单**：先读懂问题，再按「修复步骤」执行，最后按「验收」确认。
> 排查证据全部来自 GitHub API + 本机排除法，可信度高。

---

## 一、发生了什么（60 秒版）

Mac mini（hostname `agents`，git 身份 `agent@agents-Mac-mini.local`）上的某个 **batch-sync 例程**（定时扫描本地仓库、把未提交改动打包成 `chore: batch sync local changes` commit 并 push），在 **2026-08-18 09:15:30Z** 对 hermes-agent fork 分支推了一个污染 commit `1c68b13d1e`：

- 改了 `contributors/emails/agent@agents-Mac-mini.local`：`momomojo` → `skip-agent`
- 带了 `Co-Authored-By: Claude Fable 5` trailer
- commit message 是模板化的 "chore: batch sync local changes"

**这个改动不是任何人有意做的**，是 case-collision 病理的机械产物（见下）。

### 后果（已在 MacBook 侧修复）

该 commit 撞进了上游正开着 review 的 PR [NousResearch/hermes-agent#86183](https://github.com/NousResearch/hermes-agent/pull/86183)（FTS5 引擎自愈，reviewer 已确认 "No new issues"）。上游 08-18 22:34 删除了 case-colliding 文件（`693c0e1c62`）后，污染 commit 造成 modify/delete 冲突，PR 卡在 `mergeable_state: dirty`。

MacBook 侧已于 08-20 处理：**分支 ref 已 server-side 退回干净节点 `dd83fb0af8`**，PR 恢复 `mergeable_state: clean`、CI 34 全绿，并留了说明评论。

### 但病灶还在 Mac mini 上

- Mac mini 本地的 hermes-agent clone HEAD 还停在**已废弃的** `1c68b13d1e`
- batch-sync 例程还在运行
- **下次例程再跑、再 push，会把新污染 commit 推到废弃节点之上，force 覆盖刚修好的 ref，PR 再次变 dirty**

---

## 二、病理链（为什么会发生）

1. 上stream repo 曾同时跟踪两个仅大小写不同的文件：`contributors/emails/agent@Agents-Mac-mini.local` 和 `agent@agents-Mac-mini.local`
2. Mac mini 的 APFS 默认大小写不敏感 → clone 时两个文件物理合并为一个 → git status **永远**显示其中一个为 modified（这正是上游删除 commit `693c0e1c62` 描述的病理："perpetually modified in git status, breaking clean checkouts"）
3. batch-sync 例程扫到 hermes-agent clone "有未提交改动" → 模板化 commit + push（commit 身份用的还是 `agent@agents-Mac-mini.local`）
4. 撞进正开着 PR 的分支

**同日 63 秒内该例程还推了 martin 仓库**（09:14:27Z `be52e93`，mac-mini 视角正常动作）——说明它扫的是一批仓库，hermes-agent 是被误伤的那个。

---

## 三、修复步骤（按顺序执行）

### 步骤 0：定位 batch-sync 例程（必做，后续步骤依赖它）

找出是什么在定时跑 `chore: batch sync local changes`。按可能性排查：

```bash
# hermes cron（本机装了 hermes-agent CLI 的话）
hermes cron list

# launchd
ls ~/Library/LaunchAgents/ | grep -iE "sync|batch"
launchctl list | grep -iE "sync|batch"

# 系统 cron
crontab -l | grep -i sync

# ~/.hermes 任务定义
ls ~/.hermes/cron/ 2>/dev/null
grep -rl "batch sync" ~/.hermes/ 2>/dev/null
```

找到后记录：**它是什么、扫哪些仓库、多久跑一次**。

### 步骤 1：把 hermes-agent clone 对齐新 ref（清病灶）

```bash
cd <hermes-agent clone 路径>   # CLAUDE.md 说是 ~/workspace/hermes-agent/
git fetch origin
git status                      # 预期：分支 fix/fts-legacy-engine-integrity，落后于 origin
git checkout fix/fts-legacy-engine-integrity
git reset --hard origin/fix/fts-legacy-engine-integrity   # 对齐到已修复的 dd83fb0a
git status                      # 验证：clean（case-collision 文件已从上游删除，幻影 modified 消失）
```

> 备选：如果这个 clone 不再需要本地保留，直接 `rm -rf` 删除，之后用时重 clone（新 clone 不含已删除的 case-colliding 文件，天然干净）。

### 步骤 2：batch-sync 例程加仓库白名单（防复发，治本）

修改例程逻辑，机械判据（推荐后者，不依赖维护名单）：

- **方案 A（白名单）**：只 sync 明确登记的"同步仓"（如 martin）；hermes-agent 及一切 fork/work 仓库排除。
- **方案 B（防御性检查，更稳）**：push 前检查分支是否被 upstream open PR 引用：
  ```bash
  gh pr list --repo NousResearch/hermes-agent --head "$(git branch --show-current)" --state open
  # 非空 → 分支被 open PR 引用 → 跳过 auto-commit/push，输出告警
  ```
- 无论 A/B：**绝不对非本人手工创建的改动 auto-commit**（`git status` 里的幻影 modified 不该被捡进 commit）。
- 顺带修 commit 模板：batch-sync 不该带 `Co-Authored-By: Claude` trailer（上游贡献红线，martin/CLAUDE.md 有记录）。

### 步骤 3：验证不会复发

手动触发一次 batch-sync 例程（或等到下次调度），确认：
- hermes-agent clone 不再被扫出"待提交改动"，或被扫到但**跳过 push**
- GitHub 上 `strzhao/hermes-agent` 的 `fix/fts-legacy-engine-integrity` 分支 head 仍是 `dd83fb0af8`：
  ```bash
  gh api repos/strzhao/hermes-agent/branches/fix/fts-legacy-engine-integrity --jq '.commit.sha[0:10]'
  # 必须输出 dd83fb0af8
  ```

---

## 四、验收清单

- [ ] batch-sync 例程已定位并记录（是什么 / 扫描范围 / 频率）
- [ ] hermes-agent clone 本地 HEAD == `dd83fb0af8`（或 clone 已删除）
- [ ] 例程加了白名单或 open-PR 防御检查
- [ ] 手动/等待一轮调度后，远端分支 head 仍是 `dd83fb0af8`
- [ ] PR #86183 仍为 `mergeable_state: clean`（`gh api repos/NousResearch/hermes-agent/pulls/86183 --jq .mergeable_state`）

## 五、相关信息速查

| 项 | 值 |
|---|---|
| 污染 commit | `1c68b13d1e`（已废弃，勿恢复） |
| 干净节点 | `dd83fb0af8`（当前分支 head，review 确认过） |
| 受影响 PR | NousResearch/hermes-agent#86183 |
| 上游删除 commit | `693c0e1c62`（remove case-colliding entries） |
| fork 分支 | `strzhao:fix/fts-legacy-engine-integrity` |
| 涉事文件 | `contributors/emails/agent@agents-Mac-mini.local`（上游已删） |
| MacBook 侧说明评论 | https://github.com/NousResearch/hermes-agent/pull/86183#issuecomment-5358019817 |

## 六、背景（为什么这个 PR 重要）

#86183 是 hermes 上游 FTS5 跨引擎索引不一致的自愈方案（engine-version 门控 + integrity sweep + 修复链），reviewer Enough1122 已确认 follow-up 全部落地、"No new issues"，维护者 andrexibiza 亲自在分支上推过 docstring 修正。事故时它正处于「等维护者合并」的就绪态——这正是污染 commit 危害大的原因：任何新 push 都会重置这个状态。

修复完成后，若 ai-todo 任务「Mac mini batch-sync 污染修复」存在，用 `tasks:complete` 关闭它。
