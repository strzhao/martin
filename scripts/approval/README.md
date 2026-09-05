# scripts/approval — L2-A 短码审批链（微信「点开即批」）

contrib-watch 快车道审批环的交互升级（2026-09-05 立项）：审批卡带 `?key=<短码>` 链接 → 用户在
tunnel 审批页点选 批准/否决/需修改（短码已自动回填名字栏，零打字）→ launchd 90s 轮询收集判定 →
确定性执行链投递。**降级路（微信文本回复「批/否 #id」「改 #id: 意见」→ hermes-contrib-l2 skill）全程保留，两路共用 rq 状态机互斥。**

页面与判定层在 tunnel-cli 仓（`tunnel drops approve` / `tunnel drops decision`，1.8.0+）；
本目录只做编排：发卡（notify.sh）、轮询（collect.sh）、执行（execute.sh）。

## 文件

| 文件 | 职责 |
|---|---|
| `collect.sh` | 90s 轮询收集器：decision 判定 → 消费（`rq.sh set approved`）→ 调 execute；顺带回收搁置/过期公开页 |
| `execute.sh` | 确定性执行器（无 LLM）：TTL 复验 → gh 投递 → approved.log → 状态推进/回收/回执 |
| `com.stringzhao.approval-collect.plist` | launchd 定义（**仓内文件，未装载**） |
| `tests/run.sh` | 沙箱集成测试（全 stub / 全 dry-run，零真实外发） |

## 装载（人工，特性上线时执行一次）

plist 刻意**不随代码自动装载**——带 bug 的 90s 轮询器不该夜里自己上线。确认 tunnel-cli ≥1.8.0
且 `scripts/approval/tests/run.sh` 全绿后，人工执行：

```bash
# 装载
launchctl bootout gui/$(id -u)/com.stringzhao.approval-collect 2>/dev/null
launchctl bootstrap gui/$(id -u) ~/workspace/martin/scripts/approval/com.stringzhao.approval-collect.plist
launchctl print gui/$(id -u)/com.stringzhao.approval-collect | head -20   # 复核

# 卸载
launchctl bootout gui/$(id -u)/com.stringzhao.approval-collect
```

手动跑一轮（不等 90s）：`bash ~/workspace/martin/scripts/approval/collect.sh`
日志：`contrib-data/logs/approval-collect.log`（收集）/ `approval-execute.log`（执行）/ `approval-collect-{stdout,stderr}.log`（launchd）

## 特性开关（暗 launch）

`contrib-data/config.json` 增 `"approval_interactive": true` 即切换到交互路（缺省/false = 旧文本卡路，
行为完全兼容）。**当前真实 config 未加该键 = 特性关闭**；发布步骤 = 上面 plist 装载 + config 加键 +
发一条 drill 卡（见下）人工点一遍。一键回退 = 删掉该键（无需卸载 plist，collector 只处理带短码的项）。

## 短码与安全模型（C4）

- slug `[a-z0-9]{10}`（页面地址）、短码 `[a-km-np-z2-9]{6}`（去 0/o/1/l 易混字符），均一次性
- 短码只存在于三处：微信卡片、URL `?key=`、rq 台账（`.tunnel.code`）
- 审批页公开可读可提交，提交有效性唯一凭据 = 名字栏与卡内短码一致；防机会主义枚举/泄露扫描
  （tunnel submit 端点 20 次/600s IP 限流），不防设备攻破（知情接受）
- mismatch（名字≠短码）→ 只记事件不消费，页面继续等正确提交；审后即删 + 48h 搁置回收 + 7 天强删三层兜底

## 环境变量 seam（沙箱/演练用）

| 变量 | 生产缺省 | 说明 |
|---|---|---|
| `CONTRIB_DATA_DIR` | `$MARTIN/contrib-data` | 队列/配置/账本整体重定向 |
| `TUNNEL_BIN` / `GH_BIN` | `tunnel` / `gh` | 命令替换为 stub |
| `APPROVAL_DRY_RUN` | `false` | true = collect/execute 一切写路径只打印（判定命令照常，只读） |
| `APPROVED_LOG` | `$MARTIN/approved.log` | 台账路径重定向（测试绝不碰真实账本） |
| `NOTIFY_DRY_RUN` | 读 config `notify_dry_run` | true = 卡/回执只打印不发送 |

## 全链演练（drill，零真实外发）

```bash
export NOTIFY_DRY_RUN=true APPROVAL_DRY_RUN=false
# 沙箱变量见 tests/run.sh 开头 seam 表；演练件 rq id 以 -drill 结尾 → 不进 approved.log、不计深检预算
bash ~/workspace/martin/scripts/approval/tests/run.sh     # 沙箱全链（stub，可重复执行）
```

真实演练（真部署 + 真点一次 + 真收集）：扫码点开 drill 卡 → 选「批准」→ 手动跑一轮 collect.sh →
核对 `rq.sh show <id>-drill` 终态=executed、approved.log **零新增**（drill 不入账）。

## 状态机与幂等

- 消费标记 = `rq.sh set <id> approved`（awaiting-approval→approved 只可能一次；collect 90s 轮询与微信文本回复路并发时，后到者在 `rq.sh set` 处失败自然退出）
- execute.sh 只接受 state=approved 的项；执行失败 → `set failed`（合法迁移）+ pipeline-failure 事件
- verdict 三路：approved=投递入账 / rejected=否决不入账 / revise=意见入 rq note 等下轮重写

## 边界（YAGNI 已声明）

- own-PR 项被短码批准后**不自动投递**：确定性执行器不做 push（需 `allow_own_pr_push` 闸门 + 分支/worktree 上下文），保留 approved 态 + `approval-manual-required` 事件交回会话路
- premises「抽验」是机械筛选（dead/字段空缺）；语义级 premise 复核仍是会话路职责
- revise 项的审批页不立即删（等 rq sweep 48h 搁置回收 / 7 天强删兜底）
