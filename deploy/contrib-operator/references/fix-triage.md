# 修复判断四问（§9 全文）

> 本文 = contrib-operator SKILL.md 的渐进披露引用文件（2026-11-06 拆分），由 SKILL.md §5 路由表按需索引。修改真源后随 SKILL.md 一起双点部署。

**Contents**：§9.1 卡模板 · §9.2 四种归宿 · §9.3 四问判据 · §9.4 当班修复流 · §9.5 红队复核协议


## 9. 修复判断四问（`[fix]` 卡模板 + 红队复核）

> **授权来源（用户已拍板，非本 skill 自撰）**：2026-09-13 晚用户**全量拍板 11 项**（设计稿 `~/workspace/martin/docs/operator-autonomy-design-v3.1.md` §13 清单；落地卡 = 看板 `t_3f667a32`）。三条授权变更：① **「调度链」红线收窄**（只认「何时唤起系统」；钳夹逻辑归 AI）② 落点在 git 之外的**部署面算域内可逆**（附两条硬条件，见 §10）③ **首次进修复流不需人批**（四问 + 红队就是门槛）。
> **默认动作 = 不修**：缺口先过四问，并答得出「不修会怎样」；答不出 ⇒ 进 §11 清单。**修与不修的裁决只由「具体损失 + 净零件数」决定，不由时钟决定**——无周议程、无严重度门槛、无「流血例外」。
> **当班立卡义务**：当班发现的缺口必须**当班**落 `[fix]` 卡——缺口只躺在 `ops-journal` 里 = 四问 / 红队 / 清单三闸全部未启动；周审用 `journal ↔ 看板` 对账抓它。
> **阶段**：V0（文字 + 一张清单卡）2026-09-13 已落地；V1（当班修复流）首件真卡 = §11 清单 V1-1，V1-2 建议同批。

### 9.1 卡模板（直接粘进 body）

```
标题：[fix] <一句话缺口>          （禁「优化 / 重构 / 加固 / 完善」类无缺口标题）
──────────────────────────────────────────────────────
Q1 第一性原理
   最小事实：<一行代码 / 一条命令级别的事实，无「可能 / 大概」>
   症状→根因链：症状 = <观测> → 层1 = <证据> → 根因 = <最小事实>   （≤3 层）
   复发判据：修完后，下一次同形缺口还会不会以另一种形状复发？<是 / 否 + 理由>
Q2 已有基建 sweep（逐项点名，附命令 + 输出要点；不许「我知道有」）
   git 覆盖：<命令> → <输出要点>          ⇒ 这件要回答的问题是否已被 git 答了？
   看板覆盖：<命令> → <输出要点>          ⇒ 状态 / 历史是否已可读？同形已有几件？
   既有钳夹覆盖：<命令> → <输出要点>      ⇒ 校验是否已有（测试 / mutation / 对拍）？
   .bak / 数据面：<现状>                  ⇒ 写回是否有兜底？
   知识层覆盖：<skill 节> → <是否已吸收>  ⇒ 该口径是否已写进 skill？
   部署面：<落点是否在 git 之外>          ⇒ 改完靠什么自证生效？（§10 的 diff 一条命令）
   结论：已覆盖 <X>；未覆盖 <Y>（这就是这件要修的全部）
Q3 KISS 阶梯（每级必须答「为什么这级不行」，要证据不要感觉）
   能删不改？  <候选动作> → <不行，因为…>
   能改配置？  <候选动作> → <不行，因为…>
   能改一行？  <候选动作> → <不行，因为…>
   ⇒ 落到哪级：<删 / 配置 / 一行 / 一段 / 新建>
Q4 剃刀
   最少假设：能解释全部观测的假设集合 = {…}   （附「多余假设为什么被排除」）
   新增零件计数：脚本 <n> / 文件 <n> / 字段 <n> / 常量 <n>；删除抵扣 <n> ⇒ 净 <N>
   回退：<具体命令>（仓内 = git revert <sha>；数据面 = cp .bak-<ts> <file>；部署面 = cp 真源 + diff）；跑过吗？<是 / 否>
   净 N > 0 时逐项答：为什么零新增不行？<…>
不修会怎样（默认动作 = 不修，修复需要论证）
   可计量损失：<次数 / 延迟 / 一次性成本，带数字>      不可计量损失：<…>
   已兜底手段：<巡检 / 契约 / 口径> ⇒ 现有兜底是否已把损失吸收？<是 / 否>
             兜底若为「口径」（skill 条款）：<触发该口径失效的查询 —— 跑它能看出兜底已经不管用>
             ⚠ 当班新写的口径不得作为本卡的兜底引用（自产兜底 = 自己给自己发免修证）
──────────────────────────────────────────────────────
falsify: <一条命令 + 一个数字阈值>      （跑出 >N 即 REBUT；红队有权换更强的独立证伪手段）
escalate: 若 <可观测触发> 则升修复流   （触发必须是可观测的：一条命令 / 一个事件）
verdict: fix | won't-fix | upstream | already-covered
new_parts: <净零件数>   （红队核对项）
── falsify / escalate 是本模板的**机器行**（可 grep、红队逐字核）；缺行 = 形式缺陷，红队直接打回。
── falsify 格式条款：只接受「一条命令 + 一个数字阈值」。写成「若再次发生…」「无人拦 / 无人发现」这类**未来条件句或负存在命题** = 格式违规，红队直接打回。
```

### 9.2 四种归宿（默认时点 = 现在）

| verdict | 去向 | 记录处 |
|---|---|---|
| `fix` | 当班修复流（§9.4） | 卡 + 提交说明（why）|
| `won't-fix` | §11 清单——**必须经红队复核才能登记** | 清单卡一行（登记日 + 缺口 + 不修会怎样 + `falsify` + `escalate` + Sunset）|
| `upstream` | 轴一（issue-first → L2），本职 KPI | 卡 + rq |
| `already-covered` | 直接关（知识层 / 基建已吸收，不改代码）| 卡上写清是哪条口径 / 哪个基建项 |

### 9.3 四问判据（填卡人自查；红队拿命令重跑，不接受转述）

- **Q1**：最小事实能**一条命令复现**吗？「换个写法就好了」= 症状级 ⇒ 打回。对照实验必须**同刻**——单点观测足以把修法带偏（09-13 14:13「静止态必失败」→ 15:06 修正为「竞态型」的实证）。**时间戳算术纪律（10-19 #131748 gen3 勘误实证）**：涉时刻的时长/先后算术一律走 `python3 -c` / `date -r <epoch>` 工具复算，且 **Z 后缀不可当本地钟面数字改读 +08**——`21:40:40Z` 被当本地 21:40 起算时差恰好多出整 8h（16.13d 假读数，真值 15.80d），json/ledger/journal/queue title 四处账面同源污染后逐处勘误；Z 与 +08 混排的时间轴（§3.4 双班竞速条同形）同理只做工具换算，不心算。**「声称已修」复核纪律（10-19 #131748 gen4 body 勘误实证）**：任何数据面改动（板库 body/台账/json）以回读复验为准才算已修（写连接断言 + 独立只读连接交叉复验，不信工具返回）；注意 `hermes kanban edit` 在 delegate 子上下文被闸（rc=1 "delegate_task child contexts cannot mutate Kanban tasks via the CLI"）——板库数据勘误走 sqlite 直写（全量旧文乐观锁 + 备份 + 回读），未回读不得声称已修。
- **Q2**：**答不出「查过了」= 打回**。逐项点名是防自由回忆：「AI 知道 git」≠「AI 会说 git 已覆盖这个需求」。sweep 的目的不是「查了就不修」，是**查了才知道该修多小**，以及**同形已有几件**（决定这件是补丁还是结构件）。
- **Q3**：从上往下走，每级「不行」都要有证据；跨级必须有理由。序：**删 > 配置 > 一行 > 一段 > 新建**。
- **Q4**：零件计数含新增脚本 / 文件 / 字段 / 常量（周流程也算）；删除抵扣；净 >0 必须答「为什么零新增不行」，答不出 ⇒ 打回 Q3 再降一级（多半能降到「删」或「配置」）。回退命令**首次进修复流时必须真跑一次，输出贴回卡上**。
- **「不修会怎样」**：只接受**可证伪的损失陈述**。「暂无具体损失」不足以下 `won't-fix` —— 必须同时给出 `falsify:` 与 `escalate:` 两个机器行；**裁决权在红队**（找不到反例 ⇒ `won't-fix` 成立；找到反例 ⇒ `REBUT`）。
- **兜底栏**：兜底三形态（巡检 / 契约 / 口径）里「口径」最容易自产（skill 由 operator 全权管理、写进即生效）⇒ ① 口径类兜底必须给出「触发其失效的查询」；② **当班新写的口径不得作为本卡的兜底引用**（防「当班写口径 ⇒ 当班宣布损失已被吸收 ⇒ 当班判 won't-fix」的自证闭环）。

### 9.4 当班修复流（过四问即修）

```
四问过（Q1 最小事实 / Q2 已查 / Q3 落到删|配置|一行|一段|新建 / Q4 净零件有数）
  → 改（按 Q3 落点，取最小级）
  → 跑既有验证（scripts/contrib/tests/run.sh + 相关 mutation 自证 + 真库只读对拍）
  → 回退命令真跑过一次（输出贴回卡上）
  → 部署面 diff 自证（若落点在 git 之外，见 §10）
  → 红队复核（§9.5：GO / GO-WITH-FIXES / REBUT）
  → 提交说明写 why + 卡上落归宿
```

- **不设批量窗口、不设严重度门槛**：没有「流血例外」这个东西——没有延迟就不需要定义例外。
- **唯一的刹车是零件计数**：净 >0 且答不出「为什么零新增不行」⇒ 打回 Q3。
- **同形刹在第二次**：Q2 答出「同形已有 ≥1 件」时，本件正确落点**默认是结构件**（合并已有 + 删除被取代者），不是再打一个同形补丁。要推翻这个默认，必须在卡上写明「为什么这两件不是同形」并接受红队核（否则 `REBUT`）。**「默认」不是「可以论证推翻」的软词**。
- **REBUT 的回滚义务**：当班修 + 跨班红队 ⇒ 存在「改动已 live 而判词未到」的窗口 ⇒ **REBUT 到达时若改动已生效，默认动作 = 立即执行 Q4 登记的回退命令**，再谈重做；**`REBUT` 不得以「弃」结束**（必须落到四种归宿之一并写回卡评论，否则一个已被红队确认的损失会从账面上完全消失）。
- **开卡先跑「可改面 ∩ 写保护名单」；命中即改走「预产补丁 + 可执行人门问句」（09-14 两轮实证，2 次真实代价）**：`[fix]` 卡的可改面若含 agent 指令文件（`CLAUDE.md` / `AGENTS.md` / `SOUL.md` / `.cursorrules`），**headless 下必然被 Hermes 写保护拦下**（审批提示无人在场 → timeout = 拒；工具原文 `BLOCKED: write to protected agent-instruction file(s) … Do NOT retry it or attempt the same edit via another path`）。先认清闸的性质：这是**逐次操作**的人批闸——`tools/file_tools_write_guards.py:178-245`（docstring 原文 `one-operation approval EVERY time, no persisted scope, fail-closed without a human channel`；`allow_permanent=False` / `allow_session=False`），无人类通道时 `_NO_HUMAN` fail-closed（`:238`）；CLI 路靠 `_get_approval_callback()`、网关路靠 session 的 notify cb，worker 两条都没有 ⇒ 本机 `approvals.timeout: 60`（代码默认 300）到点即拒。⇒ 五条：
  - ① **建卡时**就在 body 写明该文件走**人批路**——「可改面 ∩ 名单」在开卡那一刻求交，不要等改到一半才发现。
  - ② **交付形态固定 = 预产补丁**（这类卡唯一有落笔路径的形态，不是「请人放行」四个字）：`contrib-data/pending/<slug>/xxx.patch` + 同目录 `howto.md`（写人工两处改法 + 写清回退命令），产稿时 `git apply --check` 自证可干净套用；**卡面/评论给出的必须是一条可直接执行的命令**（`cd ~/workspace/martin && git apply <patch>`）。非保护文件照常当班落地提交，闸门卡在有决策点的地方（`kanban_block(kind=needs_input)`）。
  - ③ **人门问句必须可执行、且与 unblock 语义分离**：只写「人工落笔（跑那条 `git apply`）」或「在**有人在场的会话**里让我改（面板 60s 内点批准）」；**禁写「请放行」**——`unblock ≠ 写授权`（第 2 轮 12:29:32 人 unblock 该卡后，12:33 同路径重试仍必拒 ⇒「block(needs_input) → 人 unblock」闭环对这类卡是**空转**，还让人误以为已授权）。可达形态有先例：09-11 01:16 用户在微信说「同意改 CLAUDE.md」后 `feff35e` 当场落地。
  - ④ 这类卡**不得判 `REBUT`**——falsify 会因被拦文件恒 >0，红队判词必须**分流**「实现失败」与「授权被拦」（后者 = 停在 `needs_input`，不是 REBUT），否则人手审批环会被机械判词反复打回。
  - ⑤ **不许绕过**（不写临时副本、不走 terminal/sed、不换路径）：这是红线，不是建议。
  - 证据：`t_d4dedfc7` 第 1 轮提交 `41bfe48`（3 文件落地、falsify 11→2、剩 2 行全在 `CLAUDE.md:58/:72`）；第 2 轮 12:33 重试同拒 + 预产补丁 `contrib-data/pending/claude-md-doc-layer-20260914/`（`git apply --check` rc=0、以改写稿顶替重跑 falsify=0），卡两次 `needs_input` 后自动升 triage。

### 9.5 红队复核协议（`[redteam]` 卡 + 独立进程）

**三条硬纪律**：① **换进程**（独立 agent 进程 / 会话；同 context 自我复核不算）② **只给产物**（卡 + 产物 + 证据 + 原则；**不给**修复者的论证叙事）③ **换模型族**（红队固定与修复方不同的 `provider`；卡上写 `fixer_provider:` / `redteam_provider:` 两个机器行，可与 config 逐字核对）。
- **卡面写 pin ≠ 生效（09-14 实证，纪律③ 曾静默失效）**：红队卡 `t_4577a9a9` 卡面明写 `kimi-coding/k3`，但任务记录 `model_override=null` ⇒ 实跑 contrib profile 默认 `deepseek-v4-flash` = **与修复方同族复核**（复核者自己在判词里上报了这条）。⇒ **建红队卡必须用 `kanban_create(model=…, provider=…)`** 把 pin 落到 `model_override` / `provider_override` 列；建完用板库实查自证（`select model_override,provider_override from tasks where id=…`）。
- **「建卡与 pin 同一动作序列」的正解 = `kanban_create` 的内联 `model`/`provider` 参数（09-25 shift-216 第三次实证 t_faaac59e）**：工具面 `kanban_create` 原生支持 `model=`/`provider=` 参数——建卡时不传、事后分离 `set-model` 补，恒输给 dispatcher 秒级 claim（本例 28 秒后首跑已用默认 glm-5.3-flash 起跑 = 红队纪律③同族复核报废）。下张 worker 卡需要 pin 时**必须内联传参，禁用「建卡→回头补 pin」两步**。**补救通道 = `hermes kanban --board contrib reclaim <id> --reason "..."`**（09-25 实测）：worker 已在跑但**尚未产生外部副作用**（红队只读、零 gh 写）时，reclaim 释放 claim → 卡回 `ready`（set-model 落好的 pin 在下次 dispatch 生效）→ 实证重派后 `model=k3 provider=kimi-coding` 真跑（`grep "conversation turn" ~/.hermes/profiles/contrib/logs/agent.log` 验证）。被 reclaim 的旧会话 partial 分析作废——只对「零对外副作用」的卡安全；worker 已 gh 写过的卡不可 reclaim 重跑（会双发）。
- **pin 生效 ≠ pin 可服务：pin 到配额耗尽的 provider = protocol_violation 死循环，每 tick 烧一个 worker run（09-15 实证）**。**且建卡与 pin 必须同一动作序列（09-22 03:02 t_85821c09 二次实证；01:07 t_4dc09492 首证）**——「建完回头补 pin」必然漏：forge 卡建卡 28 秒内即被 claim 白烧（3 run × 6 次 respawn_guarded），set-model k3 后 45 秒止血（claimed + 连续 heartbeat）。B 账号墙未解除期间，建 worker 卡的动作内直接跟「探活 → set-model → 板库实查」，不拆后续步骤。症状（一眼可辨）：同一张卡每分钟一轮 `claimed → spawned → heartbeat → protocol_violation (retry_status=ready) → gave_up`，`error` 原文「worker exited cleanly (rc=0) without calling kanban_complete or kanban_block」、`failures` 递增到 `effective_limit`（3）后落 `blocked`；根因 = pin 的 provider 返回**不可重试**的 403（k3 周配额用尽），agent 一次工具调用都没有就正常退出。**诊断三命令**：① 板库读事件链（上列 kind 序列）② `grep "conversation turn" ~/.hermes/profiles/contrib/logs/agent.log | tail -5`（看 `model=k3 provider=kimi-coding` = pin 真生效）③ `grep -n "403\|quota" ~/.hermes/profiles/contrib/logs/errors.log | tail -3`（看 provider 侧真相）。**处置三步**：① 探活替代族（`hermes -z "Reply with exactly: PROBE_OK" -m <model> --provider <provider>`，一条命令出 `PROBE_OK` 才算可用）② `hermes kanban --board contrib set-model <id> <model> --provider <p>`（**位置参：`set-model <task> <model> --provider <p>`**），板库实查 `model_override`/`provider_override` 自证 ③ `unblock`（reason 里写清配额根因），再看事件链是否出现连续 `heartbeat` 而无 `protocol_violation`。**探活正形（10-14 21:3x 实证，三连失败后定型）**：探活二进制 = **`~/.local/bin/hermes`**（PM 安装壳，带全套 extras），不是 repo `.venv/bin/hermes`（缺 anthropic extra 报 "package is required"；`.hermes/installs/<sha>/environments/current/bin/hermes` 路径不存在——installs 目录按 sha 命名无 current 链）；**HERMES_HOME 必须保持默认**（换 mktemp -d 会把 `~/.hermes/.env` 凭据一起洗掉报 "No usable credentials"）——只 unset 代理环境变量（HERMES_DELEGATED_CHILD_CONTEXT/HERMES_SINGLE_QUERY_SESSION/HERMES_KANBAN_DB/HERMES_KANBAN_BOARD）即可。⇒ **纪律③ 的「换模型族」不是静态常量而是「可用族列表」**：deepseek（修复方族）之外的候选族每次出手前都必须当场探活，`kimi-coding/k3` 属**周配额型** provider（09-08 与 09-15 两次耗尽），不可默认可用。
- **判词到得比 complete 晚时的核销义务（09-14 实证）**：改动当班 live、红队判词后到 ⇒ parent 可能已被 worker complete ⇒ 「必修项逐项核销才可推终态」落空（`t_5421e45a` 即此形：18:16 complete、18:24 判词 GO-WITH-FIXES）。⇒ operator 巡检见 `done` 卡带 `[redteam]` 子卡且判词为 GO-WITH-FIXES/REBUT 时，**必须补核销**：代码面必修当班修（新 `[fix]` 卡 + 红队子卡），登记/文本面必修在父卡写评论更正（已终态卡不可改写正文），并把核销表落 journal。
**审法（逐问，必须拿命令重跑）**：Q1 最小事实能否一条命令复现、对照是否同刻；Q2 逐项重跑 sweep 并核「同形已有几件」（漏项、尤其漏「git 已覆盖」= `REBUT`）；Q3 每级证据 + 有无跨级；Q4 计数有无漏计（常量 / 字段 / 周流程都算）、净>0 论证是否成立、**回退演练输出是否贴回卡上**（不接受「跑过吗：是」这个自报布尔）、部署面 `diff` 是否做过；**红线两问由红队独立核一遍**（能不能一行退回 / 错了多久可见；答不出 ⇒ 该件不进修复流，转人门）；「不修会怎样」是重点战场（机器行在不在、格式合不合规、能否真的证伪）。
**不审**：路径白名单、diff 行数上限、参数方向表——那是 v1/v2 的许可表面，已被用户否掉（审它们 = 把判断换回枚举）。
- **worktree 探针必须 `PYTHONPATH=<worktree>`，否则 venv editable install 静默解析到 main 仓（10-24 t_b28f830f 实证）**：用主仓 `.venv/bin/python` 跑 worktree 行为探针时，`python script.py` 的 sys.path[0] = 脚本目录、editable 安装指向主仓 ⇒ `import agent.redact` 拿到的是 **main 的代码**，探针输出全错成「head=main 行为」（实证症状：head 探针与 main 探针逐行雷同、worktree 新符号 `_FLAG_VALUE_RE` AttributeError）。判别一命令：探针里 `import agent.redact; assert hasattr(agent.redact, "<head 独有符号>")`。pytest 不受影响（conftest/rootdir 会插 worktree 路径），裸 `python` 探针必中招。
**判词归宿**：`GO` / `GO-WITH-FIXES`（必修项**逐项核销**才可推终态，否则只是一个软 `GO`）/ `REBUT`。判词与处置都留卡评论（可 grep）⇒ 周审机械抽样与周报「REBUT 数」都有取数口。
**红队自己也要过 KISS**：红队卡 = 既有 kanban 卡（`[redteam]`）+ 独立 `claude -p` 进程，**零新建 profile / 零新建 lane**。
**诚实边界（写死在宪法里，别假装已解决）**：四问是文字指导，强度上限 = **复核者的对抗强度**；**红队是本设计的单点依赖**——红队退化成套话，本设计对「该不该修」的机械约束 = 0。对冲只有三条：换模型族 + 周审机械抽样人核（<60 秒：抽本周最后一张 `[redteam]` 卡的判词 + 本周唯一回滚件的演练输出）+ 周报 `REBUT` 数。**纯自律条款**（配不出探测器，不假装有约束）：症状→根因链 ≤3 层 / 红队「不得由被审者本人起」（单 operator 域内无法机械核实）/ 红队「只给产物」的实际投喂 / 周报第③行必须含「最差一件」。

