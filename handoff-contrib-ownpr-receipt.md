# handoff: contrib own-PR 完成回执补上（contrib-cc 主线遗留项）

> 移交自 contrib-cc 分支会话（2026-09-08 晚）。任务自包含，无需原会话上下文。

## 背景（一句话）

contrib-cc lane 已下线，own-PR 执行走 coder lane 全自动（execute.sh 建 coder 卡 → worker 驱动 claude -p → push fork + gh pr create → worker 收尾），改造已入库（`5f2540c` + `c9fe9c2`），两轮演练含真实 L2-A 审批环全过。

## 缺口

worker 收尾只做 `rq.sh set executed` + `kanban_complete`，**用户微信零感知**——旧人工路有回执，新自动路没人发。

## 方案（已定，勿重设计）

worker 收尾步追加 `notify.sh receipt`（机械模板卡，符合外发消息规范的豁免类；notify.sh 发送失败自动留痕、明晨对账补报，天然幂等）。

**notify.sh receipt 签名已核实**（`scripts/contrib/notify.sh:756-772`）：

```bash
bash /Users/stringzhao/workspace/martin/scripts/contrib/notify.sh receipt <rq-id> --summary "<文本>"
```

## 改动点（仅 2 处，均在 ~/.hermes，不入 git）

### 1. `~/.hermes/profiles/coder/skills/claude-run/SKILL.md` §⑦ 步骤 4

现文（_worker 实测修正后的版本，注意先 grep 确认现状再改_）：

> 4. **收尾（你执行，不是 claude）**：确认 claude 日志里 push fork 成功 + `gh pr create` 返回 PR URL 后，`rq.sh set <rq-id> executed --note "<pr_url>"`（路径见 body 红线 ③；按实际结果也可 revise/failed），然后 `kanban_complete(...)`。

改为三步收尾：

1. `rq.sh set <rq-id> executed --note "<pr_url>"`（现有，不动）
2. **微信回执（必须）**：`bash /Users/stringzhao/workspace/martin/scripts/contrib/notify.sh receipt <rq-id> --summary "own-PR <rq-id> 已自动执行完成（<mode>）：分支 <branch>，PR <pr_url>"`——新自动链唯一用户触达，漏发=用户全程无感知
3. revise/failed 终态**不发 receipt**，改发事件进告警聚合（受每日 3 条硬闸）：`bash /Users/stringzhao/workspace/martin/scripts/contrib/notify.sh event own-pr-failed --key "own-pr-<rq-id>-$(date +%F)" --summary "own-PR <rq-id> 自动执行未完成（<终态>）：<一句话原因>，分支与现场保留"`

### 2. `~/.hermes/profiles/coder/SOUL.md`「own-PR 执行卡收尾职责」第 3 条

现文末尾追加一句：「随后发微信回执：executed → notify.sh receipt（模板卡）；revise/failed → notify.sh event own-pr-failed——详见 claude-run §⑦。」

## 验证

```bash
# 干跑：rc=0 且零真实外发（NOTIFY_DRY_RUN 语义）
NOTIFY_DRY_RUN=true bash /Users/stringzhao/workspace/martin/scripts/contrib/notify.sh receipt rq-dryrun-test --summary "dry-run 回执验证"
# 真实验证：等下一个真实 own-PR 走全链（或再看一次演练），确认微信收到 ✅【contrib 回执】卡
```

## ⚠ 约束与坑

1. **不碰 `scripts/contrib/**`**——hkstock 会话在 martin 仓有 staged 未 commit 文件，仓库面零改动可彻底避开冲突；本任务全部改动在 ~/.hermes（不进 git，worktree 无关但文件全局生效）
2. **开工前先 grep SKILL §⑦ 现状**——coder worker 有往 SKILL 写回实测修正的习惯（上轮它自己加了「裸跑」修正），以磁盘现文为准做增量 Edit
3. **claude 不碰 martin 仓**原则不变——receipt/event 都由 worker（不是 claude -p）执行
4. 生产 own-PR 首跑仍未发生：队列 rq-20260906-104230 / rq-20260907-104430 queued；首个真实 own-PR 时盯一次裸跑模式的 push 约束（slash+flags 秒退是框架 bug，上游报候选）

## 状态快照（2026-09-08 晚）

- `contrib-data/config.json` `allow_own_pr_push=true`（急停拨 false 即全线退人工）
- 演练件 rq-20260908-999901/999902 executed、rq-20260907-104693 rejected（issue 被上游收编）
- 相关记忆：`contrib-watch-pipeline` ⑦ 节、`cc-shell-anthropic-env-hijack`（CC shell 调 hermes 须 `env -u ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY ANTHROPIC_BASE_URL`）
