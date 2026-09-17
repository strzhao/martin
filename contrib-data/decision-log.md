# contrib 决策台账（decision log）

> 2026-09-17 由 kanban 永久卡 t_2d57344d 迁移而来（用户拍板：永久卡退役，台账入 git）。
> 此文件是 contrib 域设计决策/判例/审计结论的单一寄存处：新条目 append + git commit，不做编辑改写（历史即事实）。
> 迁移时含 20 条评论、32 条事件。原卡已归档，kanban 不可再写。

## 原卡元信息

- id: t_2d57344d
- title: [list] 已知缺陷清单（常驻卡 · won't-fix/待复活 + V1 待修队列）
- 建卡: 2026-09-13 18:59
- 终态: blocked（已归档）

## 原卡 body（设计稿头，截 3000 字符）

```
# 已知缺陷清单（常驻卡 · 板 = 记忆）

**契约来源**：设计稿 `~/workspace/martin/docs/operator-autonomy-design-v3.1.md` §4.3 / §6.1 / §6.3 / §13-3（用户 2026-09-13 晚全量拍板 11 项）；落地卡 = `t_3f667a32`（V0）。operator skill §11 是本节的口径入口。

## 用法（谁读、怎么用）

- 本卡是 `won't-fix` / 待复活缺口的**唯一家**：**每个缺口一条评论**（禁止把多个缺口并成一条评论——容量按**缺口数**计，不按评论行数计）。
- 每条评论必带：`defect-entry:` 机器行 + 登记日 + 缺口一句话 + 「不修会怎样」（可计量损失 + 兜底）+ `falsify:`（一条命令 + 一个数字阈值）+ `escalate:`（可观测触发）+ **Sunset 日** + 红队复核状态。
- 判 `won't-fix` 的缺口**必须经红队复核才能登记**（设计 §4.3；红队是两分法的裁决者，不只管 fix 路）。V0 落卡时**红队轮尚未跑**——本卡相应条目标「待红队复核」，不假装已完成。
- 复活：`escalate:` 条件一命中即升修复流（当班修），并在对应评论追加一行「复活：<触发证据>」。
- 三道闸（设计 §6.1）：① 入清单必须有**可观测**的 `escalate:`（未来条件句 / 负存在命题 = 形式违规）；② Sunset 30 天到期**不得直接删行**，删行须附证据（无证据删行 = 形式违规）；删后同缺口重登必须在评论里标「**重登**」；③ 容量 >10 个缺口 ⇒ 判为判断放水，本周剩余缺口不得再判 `won't-fix`，必须逐件落到 `fix` / `upstream` / `already-covered`。
- 周审（P9 fresh-context auditor + 既有报告通道，零新角色）只做**事后收敛**：清单体检（`escalate` 是否仍成立 / 删行是否附证据 / 容量 / 重登数）+ 同形合并（合并成结构件并删除被取代者）+ 删除回滚扫描 + `$CONTRIB/ops-journal.md` 缺口行 ↔ 看板卡标题/id **对账**（差集 ≥1 = incident）。周审不审「该不该修」（那是四问 + 红队的事），也不让任何缺口因它而等待。

## ⚠ 本卡自身的两个坑（09-13 实查，写进来防踩）

1. **本卡不派发，也不要被当任务跑**：它是容器不是任务。`initial_status=blocked` 会被 kernel promote 成 ready 并派发 ⇒ 若本卡被派发，**唯一正确动作** = `kanban_block(kind="dependency", reason="常驻容器卡，勿执行")`；**禁止 `kanban_complete` / 禁止 archive**（那等于把清单清空）。
2. **评论里不要字面复述「到期机器行 token」**（心跳钳夹契约行，skill §4.1）：钳夹取数 = `status ∈ ('scheduled','blocked')` 且评论含该 token，并**未**校验日期形状 ⇒ 本卡停在 blocked 时，一旦评论里字面出现该 token 且其后续 10 字符以非数字开头（空格/引号），本卡会被判「已到期」误唤醒。⇒ 本卡内一律写作「**到期机器行**」，不写那个 token。

## 索引（登记日 2026-09-13；改动请同步更新本段计数）

- **清单存量（`won't-fix` / 待复活）：2 条** —— L1 台账假阳性；L2 kernel 停放语义（本域半件）
- **V1 待修队列（`fix` verdict、本卡红线内未实施；不计入清单存量）：2 条** —— V1-1 inventory「载体已死」终态（**首件真卡**，按落地卡指定走完整四问 + 跨模型族红队）；V1-2 钳夹读取 + 解析 + 日期守卫（结构件；**含 09-13 18:44 新落地的 naive 放宽所引入的守卫缺失，建议列 V1 首位**）
- **已闭合（留档供周审核对）：1 条** —— C1 到期机器行必须写在 comment（`already-covered`，口径已入 skill §4.1）
- **红队复核**：V0 无红队轮 ⇒ L1 / L2 标「待红队复核」；V1 首件真卡走完整红队流程
- **周报取数**：清单存量 C 条（Δ 本周期）+ 重登数 → 周报辅助行（设计 §8.2）

```

## 决策与判例时间线（评论全量，按时间正序）

### [2026-09-13 19:00] contrib (comment #121)

defect-entry: won't-fix | slug=ledger-false-positive | 登记=2026-09-13 | Sunset=2026-10-13 | 红队=待复核

**缺口**：`forge.sh check` 的 `in-flight` 状态 ≠ 有货 —— 消费者问的是「有没有货」（观测），`check` 答的是「状态列写了什么」（声明）。实查（09-13）：`in-flight` 7 件里 **7 条零提交空壳**（`git rev-list --count origin/main..refs/heads/forge/<b>` = 0）。

**不修会怎样**：可计量 = 每次判 goods 多一条 `git rev-list`（约 1 秒）+ 可能的 1 次错判（09-13 发生 1 次，已被口径拦下）。不可计量 = 无。兜底 = **有**（skill §3.2「in-flight ≠ 有货：判 goods 前必查载体现状」，09-13 起 0 复发）。

```
falsify: `forge.sh check | grep -c in-flight`（当前 7）→ 对每条跑 `git rev-list --count origin/main..refs/heads/forge/<b>`
         阈值：出现「空壳（count=0）被直接写进 goods=offered / forge-lane 结论」≥1 次 ⇒ REBUT（取值口 = journal 与卡评论里的 `goods=` 行）
escalate: 同一份判定里出现 ≥2 次「照抄 status 列、未逐条实查」的痕迹 ⇒ 升修复流（那时它已不是单件疏漏而是习惯）
```

**口径**（设计 §9.4）：第 2 个同形件出现 ⇒ 与同形件一起做结构件（当场并，不等周末）。

### [2026-09-13 19:00] contrib (comment #122)

defect-entry: won't-fix(本域) + upstream(根因) | slug=kernel-park-semantics | 登记=2026-09-13 | Sunset=上游修好后（负债型 Sunset） | 红队=待复核

**缺口**：本域用 `blocked` 表达「到期前勿派发」，而 kernel 的 `blocked` 是**终止性**状态（需 unblock 才重新 re-gate，`kanban_db.py:3767-3790` docstring），`scheduled` 无唤醒 actor（`kind='unblocked'` 事件史 = 0）⇒ 语义错配在 kernel，不在本域代码里（本域没有调度权）。

**不修会怎样**：可计量 = 每张停放卡白烧 1 轮 worker（09-13 当天 4 次；37 条 promoted 实证）。兜底 = 本域补偿钳夹（心跳扫到期机器行）+ worker 自保 block + skill §4.1 处置；代价是每张卡一轮 run。

```
falsify: `sqlite3 "file:<board>.db?immutable=1" "select count(*) from task_events where kind='promoted'"`（09-13 实查 37）
         阈值：下一个工作日内该计数增量 ≥ 上一日增量 × 2（白烧在加速）⇒ REBUT
escalate: 同一日内出现 ≥3 张卡「created(blocked) → 60 秒内 promoted」⇒ 升修复流（09-13 已 4 张）
```

**根因修法 = 轴一**（issue-first → L2，本职 KPI），不本地改 kernel。**补偿件是负债：上游修好后必须删**（本行即 Sunset 依据）。

**同形第二件**（09-13 18:08 `t_4f4367e9`：停在 blocked 态的 [watch] 卡不被钳夹唤醒）已于 **2026-09-13 18:44** 以结构件形态落地（提交 `d0b4f3c`：心跳钳夹取数放宽到 blocked + 新增分诊收口钳夹）——但该落地形态**带缺陷**（缺日期形状守卫、读取仍 `mode=ro` 吞失败）⇒ 见本卡 V1-2 条目。

### [2026-09-13 19:00] contrib (comment #123)

fix-queue: fix | slug=inventory-dead-state | 登记=2026-09-13 | **未实施**（V0 红线）| **首件真卡**（按落地卡 `t_3f667a32` 指定）

**缺口**：`forge.sh:144-145` 的 `set-status` 值域 = 5 值（`ready|stale|in-flight|spent|needs-decision`），而 `contrib-data/inventory.json` 实有 `status=idea` **1 条**（20 件：ready 9 / in-flight 7 / needs-decision 2 / stale 1 / idea 1）⇒ 唯一写入口的值域与台账现实**双向不符**；根因 = 缺「载体已死」终态 + 已有漂移未收编。

**净零件 = +1**（新增枚举词）。Q4 必答「为什么零新增不行」已在设计 §9.3 回答：不新增就只能把死件塞进 `spent`，而 skill §8 判例已明令禁止（`spent` = 已被收编 = KPI 正信号，混进去污染计数）。

```
falsify: `forge.sh check | grep -c needs-decision`（当前 2）+ 逐条 `gh pr view <载体> --json state,merged_at`
         阈值：出现「载体 state=CLOSED 且 merged_at=null 的件被写进 goods=offered / forge-lane 结论」≥1 次 ⇒ REBUT
escalate: 又一件库存件的载体被关闭/合并而未如实登记，或 `inventory.json` 出现第 2 个值域外 status ⇒ 升修复流
```

**关联**：原 [draft] `t_550b3bc1`（09-13 15:06 建，blocked 停放）。本件是 **V1 首件真卡** —— 必须走**完整四问 + 跨模型族红队**（`GO` / `GO-WITH-FIXES` / `REBUT`）才算过闸；落地后部署面为仓内文件（`forge.sh` 在 martin 仓，无 git 之外的部署副本）。

### [2026-09-13 19:00] contrib (comment #124)

fix-queue: fix | slug=clamp-read-parse-guard | 登记=2026-09-13 | **未实施**（V0 红线）| **建议列 V1 首位**

**缺口（结构件）**：覆盖设计 §9.1 缺口 1 + §9.2 同形第二件 + 09-13 18:44 新落地形态的守卫缺失，三处同一支 SQL：

1. **读取**：`sqlite3 "file:<DB>?mode=ro"` 在静止态（`-wal`/`-shm` 不在场）rc=14 `unable to open database file`，被脚本 `2>/dev/null || true` 吞掉 ⇒ 竞态型静默失败（用无 sidecar 的库副本可复现；09-13 实测同刻 `?immutable=1` rc=0）。
2. **解析**：窗口 `substr(..., instr(...,'<到期机器行 token>')+11, 10)` 无锚定 —— token 后两个空格 ⇒ 窗口以空格开头 ⇒ 误判已到期；散文复述 ⇒ 取到中文 ⇒ 反向漏唤醒。
3. **守卫缺失（新）**：2026-09-13 18:44 提交 `d0b4f3c` 把取数放宽为 `status in ('scheduled','blocked')`，但**未加日期形状守卫**、也**未**换 `immutable=1` / 未落失败日志 ⇒ 已具备「当天误唤醒」条件。

**实查证据（18:58，用部署脚本原样 SQL 跑 live 库）**：该 due 查询返回 **`t_8bc51715`**（一张 [draft] 卡，不是到期卡）。其评论里 token 后的 10 字符窗口实测 = `[ 行请编排层 unb]`（c166）、`[<date>\` 且日]`（c167）、`['\`，**只读评论表]`（c171）—— 首字符空格 0x20 / 引号 0x27 字典序 < 数字 0x32 ⇒ 恒判「已到期」。**下一次心跳（:02）即会误 unblock 它 → 白烧一轮 worker。**

**对照（放宽的今日净效果）**：6 张真 watch 卡复查日 = 09-15 / 09-16 / 09-16 / 09-17 / 09-18 / 09-20 ⇒ 今天无一到期；故今日唯一命中就是上面这次误唤醒。

```
falsify: 用部署脚本的 due 查询原样跑一次（live 库或静止副本）
         阈值：返回任意「非到期卡」≥1 张 ⇒ REBUT（当前实查 1 张 ⇒ 缺陷成立）
escalate: 心跳后 `task_events where kind='unblocked'` 计数 ≥1，且命中卡不是复查日到期的卡 ⇒ 立即升修复流
```

**成稿已存在（勿重写）**：`$CONTRIB/heartbeat-clamp-fix-20260913.patch`（方案 B = 放宽 + **日期形状守卫 glob** + `mode=ro`→`immutable=1` + 失败落 `logs/heartbeat-clamp.log`；`bash -n` OK、`git apply --check` rc=0、静止副本按 09-13..09-20 逐日模拟零误唤醒）。**18:44 落地的是未含守卫的 naive 版**。

**修复流固定最后一步**：部署面 `diff`（仓内真源 `scripts/contrib/heartbeat.sh` ↔ `~/.hermes/scripts/contrib-heartbeat.sh`，逐字节）。

### [2026-09-13 19:00] contrib (comment #125)

closed: already-covered | slug=due-token-in-comment | 关闭=2026-09-13

**原缺口**（设计 §9.5）：到期机器行必须写在 comment 而非 body（心跳钳夹 SQL 只 `join task_comments`），同一约定在两处不同步，失效时**无声**。

**verdict = `already-covered`**：知识层已吸收（skill §4.1 契约 + 建卡后立刻补 comment + 每班实读窗口核验；09-13 起 4/4 卡落对），本域零动作、零件 0。

**复发探测（若需要）**：用钳夹同一条 SQL 做 dry-run，取回行数 = 0 而卡内 body 有 token ⇒ 该卡的到期判据永不被读取 ⇒ 那时与 V1-2 **合并成同一结构件**（同一 SQL 常量供自验与实跑共用）。

### [2026-09-13 19:03] contrib (comment #126)

## V0 落地记录（2026-09-13 19:05，卡 `t_3f667a32`）

**① 宪法已落地**：operator skill 新增 §9（修复判断四问模板 + 四问判据 + 当班修复流 + 红队复核协议）、§10（轴二边界 + 六条红线 + 部署面两条硬条件 + 风险登记册）、§11（本卡契约）；另在 §1 闸表加「域内机制改动 = 可逆性判据」行、§4.1 写入钳夹新状态与跨板写不可达、§5 加设计稿路由、§7 加六条红线、§8 加 2 条判例。授权变更（用户 09-13 晚拍板）在 §9/§10 头部注明来源与日期。

**② 本卡位置的一个问题（需一次编排层/交互会话动作）**：本卡原计划建在 **contrib 板**，实际落在 **default 板**（`~/.hermes/kanban.db`）—— 原因是 worker 上下文的 `kanban_*` 被 env pin 到「派发本卡的板」，`board=` 参数不生效（实证：`kanban_create(board="contrib")` 仍落 default；对 contrib 板卡 id 调 comment 报 `unknown task`；CLI 被 write fence 拒 `delegate_task child contexts cannot mutate Kanban tasks via the CLI`）。⇒ **迁移动作**：由 contrib 板派发的班卡或交互会话执行 `hermes kanban --board contrib create …` 重建，或在班卡 survey 里固定读本卡。skill §11 已记该局限与建议。

**③ escalate 命中（按 §6.1 记账）**：L2（kernel 停放语义）的 `escalate` 条件「同一日内 ≥3 张卡 created(blocked) → 60 秒内 promoted」**今日已命中**（5 张实例：`t_8bc51715` / `t_550b3bc1` +25s / `t_4f4367e9` +10s / 本卡 +3s）。本域补偿已由 `d0b4f3c` 落地（naive 版，见 V1-2），根因在 kernel ⇒ 应走轴一 issue-first（V1 或下个可用班次；本卡红线不含对外动作，故只记账不执行）。

**④ 三张 draft/watch 卡的回链评论未能落地**：`t_8bc51715` / `t_4f4367e9` / `t_550b3bc1` 均在 contrib 板，跨板写不可达（见 ②）。它们的处置已完整记在本卡 **L2 / V1-1 / V1-2** 条目里（含「t_8bc51715 今天可能被误唤醒」「t_4f4367e9 的缺口已由 18:44 提交闭合但形态带缺陷」「t_550b3bc1 = V1 首件真卡」）。

**⑤ 回退（诚实交代）**：skill 目录**不在 git**（`git -C ~/.hermes/profiles/contrib rev-parse --show-toplevel` = fatal），故设计稿 §12 写的「V0 回退 = `git revert` skill 提交」**不成立** —— 实际回退 = 反向补丁（整段删除 §9/§10/§11 三节；5 处小改的锚点见卡 `t_3f667a32` 的完成 summary）。INDEX.md 与 ops-journal 的改动同理（INDEX 在 git 内、`git checkout -- INDEX.md` 可退；journal 是 `contrib-data/` 数据面、不在 git）。

### [2026-09-13 20:05] worker (comment #128)

defect-entry: won't-fix(域内) + 人门(调度链) | slug=clamp-host-paused | 登记=2026-09-13 | Sunset=2026-10-13 | 红队=**待复核**

**缺口**：钳夹（scheduled 卡到期唤醒）的**宿主 cron job 被 paused**，而钳夹代码本身已修好并部署（`aae37c1`/`e3cc6df`，部署面 diff 自证）。实查证据：`~/.hermes/cron/jobs.json` → job `94cb4b0779fd`（name「contrib-operator 心跳」, script `contrib-heartbeat.sh`, `no_agent=true`）：`enabled=false` / `state=paused` / `paused_at=2026-09-13T19:55:29`；`last_run_at=2026-09-13T19:02:59`（= `e3cc6df` 19:50 部署**之后从未运行过**）。全机 13 个 job 无第二个引用 heartbeat；新驱动 `3e5c6e23e260`（「contrib-operator 班次（cron agent）」, `2 * * * *`, `script=null`）⇒ 只跑 skill，**不跑 clamp、不跑脚本侧 flush**。

**同形/取代说明（§9.4 Q2）**：本件与 V1-2（`clamp-read-parse-guard`）及原 [draft] `t_4f4367e9` 形状不同但**相互取代** —— 前者修钳夹的读/解析/守卫，后者是「blocked 卡不被扫」，本件是「宿主根本不运行」⇒ 本件成立则前两者的修复进入「**已部署但不可执行**」状态。建议（不擅自改，交编排层/周审落账）给 V1-2、`t_4f4367e9` 各加一行「生产面依赖 slug=clamp-host-paused 复活」。

**不修会怎样**：可计量 = [watch] 到期唤醒延迟 ≤1 个班次（班次为小时级 cron；最早到期日 2026-09-15 `t_1621971d`）。不可计量 = ①钳夹类改动的**生产验证面消失**（其 `falsify`/`escalate` 判据不可观测，红队判词里「09-15 首个真考验」不再是可观测事件）②脚本侧 digest/告警自动推送停摆（本班 20:05 `notify.sh flush` 实跑 rc=0、零 pending ⇒ 暂无可计量损失）。兜底 = operator 班次的 scheduled 列实读巡检（**先于本卡存在**：shift-18 18:15 journal 已记「兜底策略不变：班次巡检仍是到期日前唯一可靠 actor」）。⚠ 按 §9.3，本班刚写进 skill §4.1 的那段口径**不作为本条兜底引用**。

```
falsify: `grep -A40 '"id": "94cb4b0779fd"' ~/.hermes/cron/jobs.json | grep -c '"enabled": true'`（本班 dry-run = 0）
         阈值：≥1 ⇒ REBUT（宿主已复活、缺口不存在）
escalate: 2026-09-15 当日复核 —— `sqlite3 "file:<contrib board>.db?immutable=1" "select count(*) from task_events where kind='unblocked' and date(created_at,'unixepoch','localtime')='2026-09-15';"` = 0 且班次未在当日醒来 t_1621971d ⇒ 升修复流（请人门：重启用 94cb4b0779fd，或把钳夹段迁进新驱动 job）
```

**为什么不是 `fix`（Q3 阶梯）**：唯一能真修的一行 = 重启用该 job（或删掉钳夹）——两者都是**调度链** ⇒ 人门（§10 红线表：cron job 定义）。域内无任何代码级改动能把宿主拉回来。

**索引计数**：存量 `won't-fix` 2 → **3**（本卡 body 索引段请下周审同步；本班不改 body 以免与容器卡契约冲突）。

### [2026-09-14 11:38] worker (comment #155)

**新增待修项（09-14 主会话登记）**：「已闭环的 pipeline-failure 仍进告警批」——09-14 04:00 collect-fail 于 04:06 即 resolve 闭环，但当轮告警批仍把它推给了用户。口径应为：flush 前检查事件的 resolve 状态，**已闭环的故障降级进简报**（用户已明确表示这类「不需要我处理」）。关联：brief_only_classes 已于 09-14 主会话加入 premise-dead/probe-premise-dead（自决，收紧方向）。优先级：中（观察到下一次闭环故障是否复现再动也成立）。

### [2026-09-14 11:43] worker (comment #156)

**口径修正（09-14 主会话，用户拍板方向）**：上一条登记的修法（「flush 前查 resolve 状态」规则）作废——那是补丁思路。用户定调：**告警路由是判断活，应交回 AI 而不是加规则**。结构解法：flush 的推/简报决策移交 operator/摘要层 AI 按原则判断（无决策点不推/已闭环不推/生态损耗不推），`brief_only_classes` 类名单降级为纯兜底（AI 不可用时才用，兜底方向=推）。根因：notify 链路在 run-watch→operator 迁移时是遗留缝——感知/分诊都移交了 AI，路由决定权没移交。连带：09-14 主会话加的 config 两行届时一并回收。按 v3.1 四问走正式修复流。

### [2026-09-14 22:47] worker (comment #160)

**新增待修项（09-14 主会话登记，operator 告警触发）**：宪法文件（contrib-operator SKILL.md）存在**多写者并发编辑**问题——operator cron 班与主会话/其他班会同时改同一文件。09-14 晚实证两连：①operator 回退演练用 `git checkout` 覆盖了另一会话的未提交改动（手法事故）；②提交 909148e 夹带他人未提交改动（归属污染）。本次零损失（§12 已随 99a5f9e 落地），但结构问题在：operator 非独立实体、与主会话共享 default profile 的文件面。候选方向（四问后再定）：①宪法改动前先 `git stash list`+`git status` 检查他人未提交改动（行为契约，零机制）②回退演练禁止 `git checkout`，一律 `git stash` 或可逆命令（行为契约）③真源锁文件（机制，审慎——可能违反 KISS）。倾向 ①+② 写进 §10 部署面纪律，不立机制。

### [2026-09-15 00:16] worker (comment #161)

**新增待修项（09-15 主会话登记，§12 生效首夜实证）**：§12 自决路已生效，但**生效前入队的存量 awaiting-approval 件无人迁移**——rq-20260914-91653（19:41 入队，§12 22:09 落地）仍按旧轨等用户批准+推审批卡（还撞上微信会话死推了 10 次全败）。主会话已按 §12 自决执行该件（评论已投 issuecomment-5667068047，台账「自决」首单，rq 置 executed）。**待办**：operator 下一班应扫一遍 ready-queue 里所有 awaiting-approval 存量件，按 §12 逐件判定——属已批动作类的直接自决执行，属 ALWAYS_L2/新类型/缺依据的保留 L2。这是一次性迁移动作，做完即消失，不需要机制。另注意：rq 状态机 awaiting-approval→executed 需先经 approved（迁移表无直达边），自决执行时按 approved→executed 两步走。

### [2026-09-15 13:14] worker (comment #168)

**human-gate 噪声根治登记（2026-09-15 主会话，卡 t_78e7e276 因 archived 不可评论，落此处）**：gate-remind 对「设计驻停卡」产生第 88 次复读告警，根因 = **human-gate 事件类没有终止态语义**——登记类 [draft] 卡的合法终局就是「永久 blocked 停放」，而 gate-remind 的 SQL 把所有「blocked 超 3h 的 [draft]/[fix]」都当「等用户裁决」，每轮 flush 重落账（key 原位更新 occurrences 只加数字，永远不满足终止条件）。已实查：events.jsonl 中该 key 唯一一行（occurrences=89，pushed=true）——**告警内容本身就是假阳性**（说「均未送达」，实际早已送达）。修复方向（留给 operator 按四问流程评估，本条只登记）：gate-remind SQL 排除「设计驻停卡」，识别特征 = 卡面含「勿派发/勿执行」契约节 + blocked(kind=capability)；或 human-gate 增加 resolved 终态语义。止血：主会话直接归档该登记卡（它已完成历史使命：4 条未竟项中 3 条已落地、1 条已由 shift-24 判「宿主已删除、永久不可观测」结项）。

### [2026-09-15 17:43] worker (comment #175)

**告警路由 v2 定稿（09-15 用户拍板，取代 comment 156 修法并吞并 161/168 两待修项）**

用户原话定调：「AI 的判断力不要做什么限制，他知道目的就可以了，他很强大。」

**判断层设计（goal-oriented，非 rule-based）**：
- 输入只有两样：①**目的**（一段话：用户注意力是稀缺资源，只把「值得他现在知道」的事推给微信，其余进简报，判断全权）②**事实材料**（脚本做厚：occurrence 计数/距上次推送的内容 diff/队列等待时长/账本与事件的矛盾证据）
- **不给判据清单、不给类名单、不给 few-shot 规则**——此前草稿里的「无决策点不推/已闭环不推/复发≥3次转缺陷卡」三原则清单全部作废，那仍是把旷野当窄桥修。AI 按目的自由判断，形态自便（含发明新处置方式），判决结果落账即可（审计是记账不是限制）
- brief_only_classes 名单、24h 机械重推、gate-remind 检测器（整条 SQL）、模板/叙事双路分类——全部退役删除

**机械层保留（非限制判断，是判断失效的兜底，§12 同构）**：ALWAYS_PUSH 常量（产线瘫/发版门/预算熔断——直推不判断）、日推送硬上限（节奏预算）、幂等去重（记账）、摘要层故障看门狗（重试超限→ALWAYS_PUSH「判断层故障」——判断力宕机不能靠判断力自救）。

**移交清单**：①重推判据「有无新信息」→AI ②gate-remind 退役→operator 读板时自然判断哪张卡真需要人 ③日闸满员排序→AI 按价值 top-N ④双路合并单判断层（判决含渲染字段：模板/叙述/不推/进简报）⑤脚本职责=把事实做厚。

**落地**：operator 按四问流程捞起实施；实施验收=本周 4 起真实告警事故（88 次复读/假阳性未送达/prepare failed 误报/已自愈仍推）重放不复发。

### [2026-09-16 19:32] worker (comment #230)

**新增待修项（09-16 用户质疑「弹药域判断又是死规则？」——审计属实，登记）**：宪法 §3.1/§3.5/情报节的弹药域判定存在「判决层规则化」，与 brief_only_classes 同病。病灶三类：①数字阈值当判决（≥3 无出手位/≥5 族谱饱和/≥7 canonical 饱和/≥11 且 space=3 才出手/千级 pass）——饱和度是动态的，冻结数字会误杀也会漏判；②族禁令（「cron fire-claim 族一律 pass」「kanban 面一律 pass」「iLink 链不再新开车」）——「一律」= 停止观察指令，比过滤输出更糟的是关闭感知，族谱变化时禁令不会自己醒来；③15 分制出手门槛 = 「动词注册表」同构（判断算成算术）。**非病灶（保留不动）**：空间测量方法（独占符号召回/files 核对/gh 假空集五形态/UTC 坑/截断坑）= 仪器误差表，属「事实做厚」；用户拍板的策略（review-first/commit KPI/反 slop/不竞速）= 战略非规则；机械层只留深检预算 + L2 闸（§12 同构）。**修法**：情报节逐条从判决式改写为判例式（「当时事实 → 当时判断 → 复检活问题」），operator 每班照跑测量、拿新鲜数字重新回答活问题；五维表降为思考脚手架删算术门槛。改动仅在宪法文本形态、零测量脚本改动、可一行回滚。待用户确认或四问流程捞起。

### [2026-09-16 19:48] worker (comment #232)

**用户已批准（2026-09-16「认可」，接 comment 230）**：弹药域判定去规则化改造获批，执行口径沿用告警 v2 同一手术——①情报节逐条「判决式→判例式」改写（当时事实→当时判断→复检活问题），数字只留测量不留判决；②族禁令「一律 pass」全部废除，改写为「上轮判例+本班复检要求」；③15 分制降为思考脚手架，删算术出手门槛（≥11 等）；④测量方法/仪器误差表（gh 假空集五形态/UTC/files 截断/独占符号）**原样保留**——那是事实做厚的仪器。改动面=宪法文本（真源 deploy/contrib-operator/SKILL.md + 部署双点 cp 自证），零脚本改动，git 可回滚。执行主体=operator 按四问流程捞起（可与告警 v2 同一班实施，两次手术同属「判决层交还 AI」母题）；验收=改写后跑一班 dry 分诊，判例式条目能对当班新鲜数字回答出与旧规则一致或更优的结论。

### [2026-09-16 19:50] worker (comment #233)

**判例式改写第一测试用例（09-16 用户提问沉淀）：「hermes mac app issue 我们为什么不参与」**。现状三层：①五维表「领域契合」行把 desktop 标注为 0 分——标签规则；②09-09 前黑名单直接排除 desktop/dashboard——纯死规则；③底层真实理由=证据权威战略：出手域必须锚定我方生产足迹（weixin/cron/gateway/kanban/state.db 全是 7×24 真跑+有独家取证能力的面），desktop 我方使用薄、生产证据薄、且 farm 波次拥挤。改写后此例应变成活问题三连：「这个面我们在生产跑吗？能产独家证据吗？空间呢？」——desktop 通常三问皆弱 ⇒ pass，但**不是恒 pass**：desktop 插件/CDP DOM 检查面我方有真实工具沉淀（inspect-skills），若 issue 恰好落在该交面（如桌面 app 与 gateway 生命周期交点），答案可以翻成出手。此例作为改写 PR 的第一个验收对照。

### [2026-09-16 20:04] worker (comment #234)

**验收对照第二例获批（09-16「认可 思路对了」，接 comment 233）**：desktop 三问活判断（生产足迹？独家证据？空间？）作为判例式改写的第二个验收对照。改写 PR 执行时须同时通过两例：①弹药域族禁令改判例式（comment 230/232 口径）②desktop 案从查表改三问（comment 233 口径）。至此「判决层交还 AI」母题的改动清单在 t_2d57344d 上已齐：告警 v2（156/175）+ 存量迁移（161）+ human-gate 终态（168）+ 弹药域去规则化（230/232/233），全待 operator 四问流程捞起实施。

### [2026-09-17 09:59] worker (comment #285)

**MCP 延迟加载原理调研完成（09-17 主会话，交付教学结论给委托人）**：核心机制=三层漏斗——①声明层只留名字+描述（工具 schema 不进 system prompt，Anthropic API 内部把 deferred 工具排除出 system-prompt 前缀）②索引层建检索（name/description/参数名/参数描述 tokenize，BM25 或 regex）③激活层按需展开（模型调 tool_search→命中→API 注入 tool_reference 块→展开成完整 schema，**前缀不动所以 prompt cache 保住**）。关键工程事实：a) defer_loading 的定义仍要每次随请求发送（API 服务端要用它跑搜索——省的是上下文不是带宽）；b) 阈值触发（CC auto:5 / Kiro 5% 或 50k token）说明它是大工具库问题，3-5 个常用工具应保持非 deferred；c) 两个已知坑：HTTP transport 曾不延迟（#40314，120K token 事故）+ BM25 top-N 漏掉精确名匹配（codex#21503，假阴性→agent 误判工具不存在）；d) 描述即索引——deferred 模式下 server/namespace 描述成了唯一的「货架标签」，写砸=模型永远搜不到。

### [2026-09-17 20:14] worker (comment #298)

**三链路保障度审计完成（2026-09-17，回答「当前机制能否很好保障」）**。逐链结论：**链1（issue→抢 PR）：机制保障 = 无**，且属结构性放弃——09-02 拍板「anchor ≠ merge，分钟级占坑竞速不参与」（实证 8 辆当日抢坑零合入），journal 里 farm 6-12 分钟接车是常态，我们**主动不打这条**。这是策略选择不是缺陷，但需明确：这是三条里唯一没有机制的，因为它已被生态证伪。**链2（issue 有车→专业 review→commit 提过去）：机制保障 = 新成型**——review-first 主动线（用户 09-17 拍板）首单 t_bcabf30b 已交付：3 份执行级实测 review 上线 + 1 个 forge 件（b0401fe4）入库；§12 自决让发 review 零排队；offer 措辞有 §11 规范（lift 保署名显式首选）。弱点：①「review→发现→造货」目前靠专项卡驱动，**operator 每班分诊还没有把「值得 review 的活车」当标准动作**（只有「有独家证据」才判 review-evidence 出手，被动）；②review 产出的 forge 件缺「下次 offer 时机」的挂钩。**链3（有价值 PR 作者失联→沟通接手）：机制保障 = 最弱**——§5 salvage 流程文档齐全（礼貌询问→3-7 天窗口→fork→rebase 保署名→salvages #N），probe-salvage 三路裁定先例在（t_8600ffe7，09-13），**但近 30 天 probe-salvage 卡仅 9 张、最后一次 09-14**——缺一个「停滞 PR 雷达」的常态化扫描（宪法只在每日 08:07 对 PR 做停滞雷达，且主靶是自家车）；kshitij 式批量 salvage 已成生态常态（kshitij 60 秒 13 辆），我们反而手工作坊。**总判**：三链路保障度 = 链2 > 链3 >> 链1。结构性短板两个：A) 链2 的 review 选靶未进 operator 班次常备动作（用户拍板后只跑了一单专项）；B) 链3 缺常态化 salvage 候选扫描（§6 的候选清单还停在 07-31 快照）。建议两项收口：①operator 宪法加一条班次动作「每班从净增量里标 review 候选（我方生产域+有实质内容），当日至少评估 1 个」；②重启 §5/§6 的停滞 PR 雷达为周级节奏（找 sweeper review 过+salvageability 高+停滞>15 天的面）。待用户拍板后落。

### [2026-09-17 20:21] worker (comment #299)

**三链路 AI First 改造方案 v1（2026-09-17，用户三条方向已给，本稿待确认后动手）**

**链1「试着抢抢看」——AI First 设计**：
- 不恢复任何规则禁令，也不建「抢坑 checklist」。给 operator 的是**目的更新**：主轴 2.0 的「分钟级竞速不参与」改写为判例式——「09-02 时 8 辆抢坑零合入，但那是 slop 质量的抢法；我方质量高，抢法应是『首车即终态』：issue 出来后第一个 PR 就带复现+修+mutation 自证+测试，让后到者无从差异」。AI 每班自判：这个 issue 我是否能在质量轴上做出「首车即终态」？能→抢（走 forge+coder lane 快速路）；不能→pass，不发垃圾车。
- 抢的手速保障：operator 感知到新 issue 时已有全套上下文（域/判据/库存），出手即起草。L2 自决已覆盖（own-PR 属已批类），零审批延迟。
- 验收：抢 3 单，看首车质量是否形成「strzhao 车不可超越」的品牌信号（这正是质量竞争对 slop farm 的降维打击）。

**链2「高质量 review 是稀缺差异化」——AI First 设计**：
- 宪法不加数字，改写 §11 三腿的「触发条件」语义：给 operator 一段目的——「在上游，高质量 review（执行级实测+mutation 自证+file:line receipts）是稀缺品，这是 strzhao 品牌的差异化根基。每班感知到的活车里，凡你能产出真验证价值的，就做 review——频率由你判断，质量红线由你自己守（发出去的每条都要经得起作者和维护者的复核）。」
- **直接发 PR（用户拍板「不等 offer 时机」）**：review 发现缺口 → 造货 → **立即开我方 PR（salvages/fixes 关联对方车或 issue）+ review 评论里邀对方 cherry-pick**（§11.3 措辞：lift 保署名显式首选）。这消解了「等时机」的被动——PR 本身就是 offer 的载体，库存不再囤积。t_bcabf30b 的 b0401fe4 就是第一个按此处理的存量（operator 下一班直接开 PR）。
- 库存台账语义随之更新：inventory 从「等分发渠道的资产」变为「已发 PR 的台账」——件的生命周期 = 造→发→盯收敛，不再有「ready 待 offer」态的长期滞留。

**链3「复活雷达 AI First」——script 只做准基础数据**：
- **script 层（机械，只做准）**：周级扫描脚本产出结构化事实清单：停滞>15 天的 open PR + 每辆的 {作者最后活动时间/sweeper review 结论+salvageability/mergeable/文件域/我方契合度原始信号}。只采集不判断，数据质量要求=每字段可复跑验证。
- **AI 层（判断，全权）**：operator 拿清单后自决三件事：①哪些值得介入（判断依据是目的不是阈值：对方是否真失联、我方接手是否能做成、与在飞车/库存的关系）；②介入形态（probe 评论先探→等窗口→fork+rebase 保署名→salvages #N 全流程，或直接放弃）；③节奏（一周介入几个，AI 按带宽与质量标准自定）。
- 消解旧病灶：不再有「≥N 天即候选」的机械阈值——script 给的是「最后活动时间」这个事实，多少天算失联由 AI 结合 PR 内容判断（一个有 maintainer review 等回复的车和一辆零回应死车不是同一种停滞）。

**落地形态（待确认）**：①宪法 §11 策略主轴改判例式（含链1 新口径）+ 三腿触发语义改目的式；②新增周级 stats script（数据面，挂既有 tick harness）；③t_bcabf30b 的 forge 件按新口径直接开 PR（首发单）；④部署双点+cmp 自证。预计一轮 operator 班次可完成，git 可回滚。

## 事件流水（原卡生命周期）

| 时间 | 事件 |
|---|---|
| 2026-09-13 18:59 | created |
| 2026-09-13 18:59 | promoted |
| 2026-09-13 18:59 | claimed |
| 2026-09-13 18:59 | spawned |
| 2026-09-13 18:59 | heartbeat |
| 2026-09-13 19:00 | commented |
| 2026-09-13 19:00 | commented |
| 2026-09-13 19:00 | commented |
| 2026-09-13 19:00 | commented |
| 2026-09-13 19:00 | commented |
| 2026-09-13 19:00 | heartbeat |
| 2026-09-13 19:01 | heartbeat |
| 2026-09-13 19:03 | commented |
| 2026-09-13 19:03 | heartbeat |
| 2026-09-13 19:04 | heartbeat |
| 2026-09-13 19:05 | heartbeat |
| 2026-09-13 19:05 | blocked |
| 2026-09-13 20:05 | commented |
| 2026-09-14 11:38 | commented |
| 2026-09-14 11:43 | commented |
| 2026-09-14 19:05 | dead_letter |
| 2026-09-14 22:47 | commented |
| 2026-09-15 00:16 | commented |
| 2026-09-15 13:14 | commented |
| 2026-09-15 17:43 | commented |
| 2026-09-16 19:32 | commented |
| 2026-09-16 19:48 | commented |
| 2026-09-16 19:50 | commented |
| 2026-09-16 20:04 | commented |
| 2026-09-17 09:59 | commented |
| 2026-09-17 20:14 | commented |
| 2026-09-17 20:21 | commented |

---

## 2026-09-18 · 判例：#113999 的 68 分钟窗口（新政的活标本）

> 来源：operator 班次留痕（09-18 00:40，原卡 t_2d57344d 评论文本），因该卡已归档转入本台账。
> 记：本条由 coder worker（卡 t_9396bbf3 收尾轮）代录入 —— operator 侧 heredoc 写入被审批闸拦下。

**事实**：用户问「#113999 我们本来有机会提 PR 被直接 cherry-pick 么」→ 实查时间线：我方 review 12:10Z 上线，clempat 修复 commit 13:18Z，**68 分钟窗口**。修复内容（CANTOPEN→disk 桶后置 / locked 保住 / divert 挪 flush 点）是单关注点小改，在 forge ≤20min 基准内 ⇒ 窗口内造货 + offer 完全可行。实际：他手工重写全盘采纳（含独立复证我方证伪的机制声明），我方署名归零。

**归因**：①当晚预算姿态一单一 forge（#114091 占用了造货面）；②「review 发现缺口 → 立即开我方 PR」的新政在事发之后才拍板。

**判例价值（新政的活标本）**：review 塑形价值（拿到）≠ commit 署名价值（丢掉），两者要同时拿。**此后每份 review 出手同步问一句**：这个缺口 20 分钟能否造出货？

**残余窗口**：#113999 CI 等放行未 merge；我方 #114159（`forge/sqlite-sidecar-read-guard`，源于 #114091 的读侧缺口）仍 OPEN = 活 pick 候选。

**关联**：本条所举例的新政（review→发现→造货→立即开 PR）已由卡 t_9396bbf3 落进宪法并与本台账同批入 git：`hermes-contribution.md` §11 目的段 + 三腿分工触发列、`deploy/contrib-operator/SKILL.md` §3.1/§3.2/§3.4 判例式改写 + 新增 §3.7 停滞雷达 AI 判断面。
