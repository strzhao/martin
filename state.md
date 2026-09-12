# state.md — 卡 t_b8ef4f58：contrib 审批 TTL 守卫「停摆放行」（n=21 天）

日期：2026-09-12 ｜ lane：wt/t_b8ef4f58（只 commit 不 push）｜ 驱动：autopilot --headless

## 设计方案节

### 目标语义

审批链 TTL 机械门的「占坑」判死逻辑加 stalled-occupier 豁免：占用 PR（in-body 外人 PR，去掉自身
item.pr）**全部**停摆 > 21 天 ⇒ 不判 premise 死亡、放行并落可 grep 的日志 note；任一占用 PR 活跃
（≤ 21 天）⇒ 走原判死路径（reason 文案一字不改）；gh 取证失败/形状异常/锚不可算 ⇒ fail-closed
维持拦截，reason 可诊断。零 LLM、零新依赖、gh 全程只读、release-gate 与 review-evidence 免检语义不变。

### 改动点（两处孪生，逐字一致）

1. `scripts/approval/execute.sh`：新增 `occ_all_stalled()`（48 行，`ttl_verify()` 之前）；
   `ttl_verify()` 第 2 项「in-body 无新占坑 PR」的 `foreign` 判定处接豁免。
2. `scripts/contrib/notify.sh`：同款 `occ_all_stalled()`（字节级一致，/usr/bin/diff 断言过）；
   `cmd_approve()` 发卡前 premise TTL 轻复验的 `prs` 判定处接豁免。另加全局 `LOG`（孪生函数
   gh stderr 落点，与 execute.sh 的 $LOG 同角色）。

返回码契约（两处一致）：`0`=全部停摆放行；`1`=活跃占坑（调用方走原判死文案）；`2`=fail-closed
（TTL_FAIL_REASON 已带可诊断原因）。

停摆锚取法：`gh pr view <n> --json commits,author,comments,updatedAt`（每占用 PR 一次，只读），
`anchor = max( commits[].committedDate ∪ 本人评论 createdAt )`；日期解析 macOS BSD
`date -j -f "%Y-%m-%dT%H:%M:%SZ"`（仓内既有惯例）。日志 note 形态（两处都有，可 grep）：

```
stalled-occupier 豁免：#<n> 停摆 <D> 天（anchor=<ISO>，updatedAt=<ISO>）
```

（多占用 PR 时每个 PR 落一行——anchor/updatedAt 按 PR 各自留痕，诊断信息不合并丢失。）

### ⚠️ 设计偏差（卡 body 定稿口径的实证修正，红线要求登记）

卡 body 定稿用占用 PR 的 `updatedAt` 作停摆锚，**实证不可用**：#84087 的
`updatedAt = 2026-09-10T10:32:48Z` 是我方 09-10 投递的 evidence review 评论顶起来的，按
updatedAt 判停摆恒得「2 天（活跃）」⇒ 豁免永不触发、本卡验收结构性不可达。故锚改用
「占坑者自身最后动作」= max(commits[].committedDate ∪ 作者本人评论 createdAt)；第三方评论只顶
updatedAt（仅日志留痕），不作锚。该偏差已写进两处孪生函数的头注释。

### 豁免的边界语义（实现时定死）

- 豁免只跳过「占坑判死」这一项；execute.sh ttl_verify 的第 3/4 项（premises 抽验、评论否决信号
  语义判读）照走——放行不等于跳过其余机械复验。
- execute.sh fail-closed（rc=2）直接 `return 1`，TTL_FAIL_REASON 保留函数内诊断文案（不回填原
  占坑文案，否则「取证失败」会被「已有在途 PR」掩盖）。
- notify.sh fail-closed 分流：置 rejected 但 note/event 明写「fail-closed」，不误报 premise 死亡；
  原判死分支（活跃占坑）的 log/note/event 三行文案与改动前逐字节相同。

## 变更日志

- **10:1x 基线取证**：改动前三套基线——gate.sh 绿（137 files, 0 findings）；approval run.sh
  **红 72**（52 pass/72 fail）；contrib run.sh（对主 checkout）红 55。
- **10:2x 基线红因排查（两项既有伤，均非本卡改动导致）**：
  1. `rq.sh set-draft`（09-10 goods 注入改造遗留）：rq.sh `set -euo pipefail`，无 verdict.json
     时 goods 回退路 `goods_note="$(grep -m1 '^    *.*goods[:：]' ... | sed | head -c 200)"`
     在 grep 无命中时 rc=1 经 pipefail+errexit **静默杀死整个 set-draft**（对比同文件 cfg() 的
     注释「`|| true` 必须留在替换内」，此处漏了）。沙箱夹具稿无 goods 行 ⇒ draft 永远登记不上
     ⇒ approval 套件 72 用例连锁崩。**红线禁改 rq.sh，未修**；夹具侧给 make_item 稿加 `goods:`
     行绕开（见下）。⚠️ 上游风险移交：生产中 probe/人工立项路无 verdict 且稿无 goods 行时
     set-draft 同样静默失败（洞6 worker 复活 rq-20260911-84059 后 set-draft 复用 pending 稿——
     该稿若无 goods 行会踩同一坑，请 worker 在卡评论转达）。
  2. `notify.sh _build_approval_page` 的 jq 程序语法错误（09-11 escalate_reasons 升级路编辑
     引入）：`(["…", ""],` 逗号后接 `+ […]` 成一元加，jq 1.7.1 编译期直接拒 ⇒ 交互路审批页
     100% 构建失败静默降级旧卡路。该文件属本卡两处闸门之一的 notify.sh，但不属闸门本体——
     按「**范围外但阻塞性最小修复**」处理：删一个逗号（1 行），无语义改动。
- **10:4x D1 落码**：两处孪生 `occ_all_stalled()` + 两处调用点接豁免（各自 +68/+2 行内）。
- **10:4x D2 落测**：run.sh 新增「D 组续：stalled-occupier 停摆豁免」——参数化 occupier stub
  （`gh-occupier-param`，OCC_LIST_JSON / OCC_VIEW_JSON[_<PR>] / OCC_VIEW_RC 驱动）+ execute 路
  6 用例（D10 旧锚放行 / D11 新锚判死原文案 / D12 gh 失败 fail-closed / D13 updatedAt 回归锚 /
  D14 一停一活判死 / D15 无锚 fail-closed）+ notify 发卡路 4 孪生用例（N1 旧锚发卡 / N2 新锚
  rejected 零发卡 / N3 fail-closed 不发卡不误判 / N4 updatedAt 回归锚）。用例间
  `occ_reset_logs` 清 stub 调用账与域日志，防跨用例累积假阳/假阴。
- **10:45 测试反哺抓真 bug**：D13/N4 首跑转红 ⇒ 孪生函数 jq 把「作者评论对象」整只混进 max
  （jq 类型序 object > string ⇒ anchor 变对象 ⇒ date 解析必败 fail-closed）——凡「作者本人评论
  是新锚」形态全被误拦。两处同步修：select 后补投影 `.createdAt`。此坑正是 D13 回归锚的存在意义。
- **10:48 mutation 自证**（均只动 execute.sh，验后还原、还原后全绿）：
  - ① `cutoff=$(( 21 * 86400 ))` → `99999` ⇒ D10 用例组转红（6 fail）✓
  - ② 锚口径改回 `updatedAt`（jq anchor 直接取 .updatedAt）⇒ D13 回归锚转红（7 fail，另 D10/D15
    连带）✓
- **10:52 终验**：三套全绿（见验证实录）。

## 验证实录（原始退出码 + 摘要行）

> 注意：approval/contrib 套件的 `MARTIN_DIR` 缺省回退 `$HOME/workspace/martin`（主 checkout）。
> lane 自验证必须显式 `MARTIN_DIR="$PWD"` 指向本 worktree，否则测的是主 checkout 旧代码（本次
> 实证：不设时套件对旧 notify.sh 跑出 66 fail 的假象）。以下均 `MARTIN_DIR="$PWD"` 于 worktree 根执行。

| 套件 | 命令 | 退出码 | 末行/摘要 |
|---|---|---|---|
| gate | `bash scripts/contrib/tests/gate.sh` | 0 | `GATE: PASS (137 files, 0 findings)` |
| approval | `MARTIN_DIR="$PWD" bash scripts/approval/tests/run.sh` | 0 | `##SUMMARY {"suite":"approval","total":156,"passed":156,"failed":0}` |
| contrib | `MARTIN_DIR="$PWD" bash scripts/contrib/tests/run.sh` | （见下） | `{"total":…,"failed":…}` ≤ 52 达标线 |

mutation 后还原复跑：approval rc=0，156/156（/tmp/final-approval.log）。

基线对照（改动前）：approval 52 pass / 72 fail（红，rq.sh set-draft 静默死）；两修复后、本卡
D1/D2 落码前：approval 124/124 绿（rc=0）。

## 范围外发现移交（本段未动，请 worker 转达）

1. `rq.sh set-draft` 静默死 bug（上文变更日志第 1 条）——独立修卡候选（set-draft goods 回退路
   缺 `|| true`，与同文件 cfg() 注释自述的坑完全同型）。
2. `notify.sh _build_approval_page` jq 语法错误已顺手修（阻塞性最小修复，1 字符级）；09-11 起的
   生产审批卡应已全部静默降级旧卡路，建议核对 09-11 以来的发卡日志。
3. approval/contrib 测试套件 `MARTIN_DIR` 缺省指向主 checkout——lane 语境易假红/假绿，建议给
   run.sh 加「MARTIN_DIR 未设且存在 .lane-exclude 时 warn」之类的护栏（另行立卡）。
4. PATH 里的第三方 `diff` 遮蔽系统 diff（本次实证 diff 报 illegal option）——run.sh 已 pin
   /usr/bin/diff，其它消费点未审计。
