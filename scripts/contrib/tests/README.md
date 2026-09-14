# contrib-watch 基建测试套件

为 `scripts/contrib/` 的 6 个生产脚本（notify.sh / rq.sh / forge.sh / kanban_card.sh / l2_ledger.sh / gateway_sentinel.sh）建立的多维回归测试。起因：2026-09-05 事故（notify.sh cfg() 用 jq `//` 把 `notify_dry_run:false` 读成默认 true、脚本在 launchd 下缺 `cd` 导致 claude 找不到项目 skill），同类静默失效必须**在合入前被确定性捕获**。

零外部依赖：纯 bash 3.2 + jq + python3 + shellcheck（全部本机已有），拒绝 bats/pytest——launchd 极简 PATH 下必须自足。

## 怎么跑

```bash
# 一条命令：unit + contract + e2e + static 四维度；末行 JSON 摘要
bash scripts/contrib/tests/run.sh

# launchd 仿真（cwd=/ + env -i 极简 PATH + 临时 HOME）
cd / && env -i HOME=$(mktemp -d) TMPDIR=$(mktemp -d) PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  bash /Users/stringzhao/workspace/martin/scripts/contrib/tests/run.sh

# 入库验收门（pre-commit 同款；秒级）
bash scripts/contrib/tests/gate.sh          # exit 0=全绿 1=有发现 2=依赖缺失
MARTIN_GATE_TARGET=<沙箱副本根> bash scripts/contrib/tests/gate.sh   # 覆盖集根重定向（mutation 自证用）

# 单个测试文件（调试用）
bash scripts/contrib/tests/unit/cfg-semantics.sh
```

## 入库验收门（gate.sh + pre-commit）

`scripts/contrib/tests/gate.sh` 是 contrib/approval 域 .sh 的统一秒级入库门，薄壳自聚合三关，**聚合不短路**（收集全部发现一次报告）：

1. 语法门：`bash -n` / `zsh -n`（按 shebang 分流）；
2. `shellcheck -x -S warning`（仅 bash 系；zsh 豁免，口径同上）；
3. 全角 regex 门：`\$(\w+)` 紧跟全角标点即 FAIL——regex **单源** `lib/fullwidth-pattern.txt`（gate.sh 与 static/gate-fullwidth.sh 同读一个源，contract-drift.sh 机械守卫「两脚本引用单源 && 无内嵌字面量」）；perl 一律字节模式（不带 -C 系标志），契约冻结。

覆盖集：`scripts/contrib/**/*.sh` ∪ `scripts/approval/**/*.sh`（find 圈定，非硬编码）。退出码闭集：**0**=全绿 / **1**=有发现 / **2**=依赖缺失（bash/zsh/shellcheck/perl/git/find 任一不可得即 fail closed，禁空集静默绿）。绿跑输出契约：`COVERAGE scripts/contrib scripts/approval` 覆盖面声明行 + 逐维度 `SCAN <dim>: <N> files`（dim ∈ bash -n / zsh -n / shellcheck / 全角）+ 逐行 `FAIL <file> <类别> <detail>`（类别 ∈ syntax|shellcheck|fullwidth|dep）+ 末行 `GATE: PASS|FAIL (N files, M findings)`。零仓内写入。

接线：`bash scripts/contrib/tests/install-hooks.sh`（= `git config core.hooksPath .githooks`，幂等）→ pre-commit 只在 staged 触及本域 `*.sh` 时跑门；gate FAIL 阻止提交并给修复指引。逃生阀 `MARTIN_GATE_SKIP=1`：跳过门但追加台账行到 `.autopilot/runtime/gate-skip.log`（时间戳+HEAD+staged），永不静默。缺陷注入自证用 `MARTIN_GATE_TARGET=<mktemp 副本根>` 重定向覆盖集根，绝不污染仓内文件。

`static/gate-fullwidth.sh`（run.sh static 维度自动发现）是同一全角门的套件形态：命中即 `_fail` 并打印 file:L<行号> 定位行；沙箱语义——`CONTRIB_TEST_TARGET` 指向沙箱树时只扫 target 树内 .sh，`scripts/approval` 缺失按 N/A skip 显式计数，**target 树零 .sh 文件必须 FAIL**（保负对照）。

每个测试文件**末行**输出 `##SUMMARY {…}`，run.sh 据此聚合；`exit 0 当且仅当 failed==0`。

## 怎么加测试

1. 选维度目录：`unit/`（纯函数 source 级）→ `contract/`（对外 API/exit 码/schema）→ `e2e/`（全链路黑盒）→ `static/`（语法/lint/契约漂移守卫）。
2. 新建 `NN-名字.sh`，骨架：

```bash
#!/bin/bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_ROOT="$(cd "$HERE/.." && pwd)"
TARGET_DEFAULT="$(cd "$TESTS_ROOT/.." && pwd)"
export CONTRIB_TEST_TARGET="${CONTRIB_TEST_TARGET:-$TARGET_DEFAULT}"
export CONTRIB_TEST_STUBS="${CONTRIB_TEST_STUBS:-$TESTS_ROOT/stubs}"
export DIM=e2e
source "$TESTS_ROOT/lib/assert.sh"
source "$TESTS_ROOT/lib/sandbox.sh"
t_init "文件名.sh"
sb_new >/dev/null 2>&1 || { echo "sandbox-fail"; exit 1; }

t_case "用例名"
sb_notify event pipeline-failure --key k1 --summary "…"
assert_exit 0 $?
assert_stub_called_times hermes 1

sb_cleanup
t_finish
```

3. 断言只用 `lib/assert.sh`：`assert_eq / assert_ne / assert_contains / assert_not_contains / assert_exit / assert_file_contains / assert_stub_called(_times) / assert_stub_not_called`；沙箱辅助见 `lib/sandbox.sh`（`sb_rq / sb_notify / sb_run / sb_seed_event / sb_seed_queue_item / sb_state_set / sb_config_set`）。
4. 纪律：
   - **所有读写经 seam 重定向进沙箱**，绝不触碰真实 `contrib-data/`、绝不调用真实 hermes/gh/claude/tunnel/osascript；
   - **时间闸门不 sleep**——回拨 `notify-state.json` 的 `last_flush_epoch` / `alerts` 键构造前置态（用 `sb_state_set`）；
   - 每个用例独立沙箱（`sb_new … sb_cleanup`），env 逐用例注入（`sb_run -e K=V`），禁止跨用例 export；
   - 断言只锚契约（`契约规约`：接口名/字段/状态闭集/exit 码），不锚外发文案措辞。

## Seam 清单（默认值=事故前硬编码，逐字符一致，由 static/seam-defaults.sh 逐字符守卫）

| seam | 默认值（=现状） | 用途 |
|---|---|---|
| `MARTIN_DIR` | `$HOME/workspace/martin` | 6 脚本的项目根（notify/rq 的 RQ/NOTIFY 路径跟随） |
| `CONTRIB_DATA_DIR` | `$MARTIN/contrib-data` | 数据目录（6 脚本全部读写） |
| `NOTIFY_LOCK` | `/tmp/contrib-notify.lock` | notify flush/approve 锁 |
| `NOTIFY_SEND_LAST` | `/tmp/contrib-send-last.json` | hermes send 输出落点（success:true 判据读这里） |
| `RQ_LOCKDIR` | `/tmp/contrib-rq.lock` | rq 写锁 |
| `WATCH_LOCK` | `/tmp/contrib-watch.lock` | 旧 run-watch 防重入锁——**09-13 随 run-watch 退役**，生产面已无消费者（仅 tests/lib/sandbox.sh 仍导出该 env） |
| `DEEPCHECK_TARGET_FILE` | `/tmp/.deepcheck-target` | 旧 gate→deep-check 目标传递——**09-13 随深检族退役**，生产面已无消费者（仅 tests/lib/sandbox.sh 仍导出该 env；见下方退役件登记） |
| `DEEPCHECK_LOCK` | `/tmp/contrib-deepcheck.lock` | 旧深检防重入锁——**09-13 随深检族退役**，同上（仅 sandbox 仍导出） |
| `HERMES_BIN` / `GH_BIN` / `TUNNEL_BIN` / `OSASCRIPT_BIN` / `GATEWAY_PROBE_BIN` | `hermes` / `gh` / `tunnel` / `osascript` / `pgrep` | 外部命令注入点（影子 stub 双通道之一） |
| `CLAUDE_BIN` | 空 → 现有两级探测（PATH → nvm 目录） | claude 注入点（notify/rq 之外的 3 个 LLM 调用方） |
| `NOTIFY_SOURCE_ONLY` / `RQ_SOURCE_ONLY` | unset | source guard：=1 时只加载函数不执行 dispatch（单测复用纯函数） |

沙箱把 `HOME` 指向沙箱内 home 并将 `$HOME/workspace/martin` 软链回沙箱根——**万一哪处 seam 漏配，默认值也落在沙箱里，生产零风险**。另外：notify.sh 的审批卡/回执临时文件（`/tmp/contrib-approval-<id>.txt`、`/tmp/contrib-receipt-<id>.txt`）与 AI 摘要 prompt（`/tmp/contrib-digest-prompt-<pid>.txt`）保持现状（按 id/pid 命名、用后即删，不在冻结 seam 名单内）。

## 写入归属引擎（s4 4.P1 / t1-04 4.1 的生产零写入判据）

**要改「套件对生产 contrib-data 零写入」判据、或看到 4.P1 因生产写手在窗口内落笔而红** ⇒ 先读本节。

判据原口径是「全量 shasum 前后 diff 行数==0」。只要套件运行窗口与**生产写手**（launchd `com.stringzhao.approval-collect` 每 90s 跑 `scripts/approval/collect.sh` 追加 `contrib-data/logs/approval-collect.log`）重叠，diff 必然非 0 ⇒ 门恒定红（恒定红会被训练成忽略；为让它绿去放宽又退回假绿）。归属引擎把「窗口内变更」机械拆成三类：

| 类别 | 语义 | 判据后果 |
|---|---|---|
| `suite` | 套件写的（或无法归属的）：默认 deny | **判红**（`eq "$WA_SUITE" 0`） |
| `external` | 生产写手写的：路径 ∈ 清单 ∧ 追加语义/inode ∧ 记录落字母表 ∧ 时间戳在窗（corroborated-* 另需佐证近邻） | 证据行 + PASS |
| `outside-surface` | 判据面外路径（不匹配任何清单模式） | 证据行 + PASS（**不判失败**，理由见下） |

- **引擎**：`lib/write-attribution.sh`（纯只读；API `wa_registry_default` / `wa_snapshot` / `wa_classify` / `wa_selftest` / `wa_inject` / `wa_wait_external`；exit 码闭集 0/1/2，`wa_classify` 的 2 = 依赖缺失/快照缺失/清单非法/窗口非法/计数恒等式失配）。`diff` 一律落库内（两个 acceptance 文件的命令位 `/usr/bin/diff` 调用点由守卫钉死：s4=2 / t1-04=1）。
- **清单**：`lib/production-writers.tsv`（唯一真源；TAB 五字段 = 路径模式（**shell glob**，bash `case` 语义） / writer-id / mode / 输出字母表（ERE，`|` 连接多形态，**首捕获组=记录时间戳**） / 佐证写手日志路径（`|` 分隔多佐证））。mode 闭集 = `append-records`（追加语义可自证）/ `corroborated-rewrite` / `corroborated-create`（重写类，**只能靠佐证**）。`#` 注释行承载逐形态实测证据（形态 + 出处行号 + 样本条数）。
- **佐证成立** = 佐证日志存在 ≥1 条**在窗**合规记录 ∧ `|佐证记录 ts − 变更文件 mtime| ≤ 30s`（时序近邻：notify 改状态与落 `log()` 行同秒相邻是实证常态；仅「存在性佐证」会被套件恰在写手活跃窗内写入掩蔽 ⇒ 假绿通道）。失败态 evidence 行同样带 `Δt=`/`ts=`（无在窗记录写 `none`），便于事后审计。
- **marker 短路**：变更文件的新增内容含 `S4-P1-` 前缀行 ⇒ 无条件 `suite`（reason=`canary-marker`），**先于**佐证判定——本 harness 注入物是确定事实，真实泄漏仍由存在性 + 时序近邻拦截。
- **注入旋钮**（env，默认空 = 纯生产态；每次注入落 `WA-INJECT` 证据行，注入物由调用方 EXIT trap 清理）：
  - `S4_P1_INJECT=canary-create`：窗口内往注册面 `contrib-data/pending/` 新建 marker 文件（可干净删除、零残留）⇒ 必须判红；
  - `S4_P1_INJECT=canary-append`：窗口内往注册路径追加一行字母表外 marker（留 1 行残留，opt-in）⇒ 必须判红；
  - `S4_P1_INJECT=external-append`：窗口内往注册路径追加与写手 `log()` 逐字同构的合规记录 ⇒ 必须 `external≥1` 且 PASS；
  - `S4_P1_INJECT=wait-external`：`run.sh` 后弹性轮询（`S4_P1_WAIT_MAX`，默认 150s）等**真实生产写手**落笔 ⇒ 必须 `external≥1` 且 PASS。
- **面外语义与残余风险**：面外不判失败的依据是「套件写面由静态 seam 守卫锁死（`static/seam-defaults.sh` 冻结默认值）⇒ 面外路径不是套件可达写目标」+ 实测该面被并发进程高频写（判红即「训练人忽略这道门」）。残余风险（如实登记、不隐藏）：① 形态归属 ≠ 进程归属（套件精确复刻「注册路径 + 字母表形态 + 在窗时间戳」仍可能误判 external；缓解=字母表是实测闭集 + 金丝雀证明注册路径非免死金牌）；② 面外不判失败（套件若往草稿区写文件，4.P1 不红）；③ 佐证漏配（`corroborated-*` 赶上生产写手「改了状态但没落日志」的罕见轮次会误红，可凭 evidence 行的 `Δt=`/`ts=` 诊断）。
- **清单完整性守卫**：`unit/write-attribution.sh` C16 —— 从清单 writer 列反查写手脚本（∪ 其字面调用者）派生源码写点，断言 ⊆ 清单模式（差集为空），并施加三条**声明式排除谓词**（E1 瞬时槽位：basename 以 `.` 开头或含 `.tmp`；E2 运行期产物：路径含 `/runs/`；E3 判据面外数据文件短名单：`logs/sentinel.log` / `inventory.json` / `goods-metrics.json` / `kanban-flight-digest.json` / `logs/launchd*.log`，逐条带理由）。守卫自身可被 mutation kill（删清单一行 / 往写手脚本副本注入新写点 ⇒ 差集非空 ⇒ FAIL）。**残余缺口**：新增**独立**写手脚本（不在清单 writer 列、也未被清单写手调用，例如新装 plist 的脚本）不被派生面覆盖，需带理由显式扩清单或 E3 名单。
- **并发探测注意**：探测是否有同名 acceptance 在跑时用**命令位形态** `bash .*s4-production-zero-touch\.acceptance\.sh`；勿用 `pgrep -f '[s]4-production-zero-touch'`（会命中他卡 `claude -p` 提示词里的同名字符串 ⇒ 假 SKIP，也会误伤相对路径调起的他卡进程）。
- **生产侧复跑配方**（生产主 checkout 上由 worker 执行）：`.autopilot/runtime/sessions/t_cbf34542/requirements/20260914-s4-p1-write-attribution/production-recipe.md`。

## 豁免清单

- **zsh 脚本**（按 shebang 动态识别）不做 shellcheck（SC1071 是工具对 zsh 的误报），以 `zsh -n` 语法门覆盖（static/syntax.sh 生产 3 个 + gate.sh 全部 zsh shebang）。
- **`scripts/approval/tests/*.bash`** 不在 gate.sh 覆盖集内（口径收窄到 `*.sh`），由 approval 套件自测覆盖（`bash scripts/approval/tests/run.sh`）。
- **`stat -f %m`**（macOS 专属）出现在 notify.sh 的 send 回写新鲜度判读（`_send_result_fresh`）——macOS-only 语义，不跨平台。
- **`jq -r '.success // false'`**（notify.sh `_send`）保留 `//` 运算符：这里语义正确（把非 true 输出一律当失败），与被修的 cfg 布尔塌缩不是同一形态。
- **契约外观察项（现状固化，非缺陷断言）**：dry-run 演练轮会把批次事件标 `pushed=true`（演练消费语义）——契约规约只冻结「零传输调用 + stdout 含 [dry-run]」，是否应保留事件待后续拍板（tests/contract/notify-cli.sh 内有登记）。
- `notify_min_interval_min` 拦截轮与限额拒绝轮 exit 0（属正常跳过/拒绝，非失败）；发送失败/摘要失败轮 rc≠0（契约：事件保留重试，由调用方容错）。

## 与设计的对应

- 设计文档：`.autopilot/runtime/requirements/20260905-对这些关键基建做下单/state.md`
- 验收谓词 SSOT：同文档 `## 验收场景`（场景 1-12）；本 README 即「豁免清单」与「E 波退役件登记」的登记处

## E 波退役件登记（引用面清单）

09-13 `fc46a71` 一次性退役 12 个脚本 + detect 族 + e2e 深检族。**删件后文档/注释仍以现在时描述已删件**这件事已两次形成修复卡（run-watch 一次、其余件一次）——本表是**单一登记处**：要查「某个退役名现在归谁」只看这里，别在注释里逐处复述历史。

| 退役件（09-13 E 波） | 现行替代面 |
|---|---|
| `run-watch.sh` | operator 班次（default profile agent cron，每小时 :02）；六节点 感知→分诊→造→过闸→守候→学习 |
| `scan_gate.sh` / `mail_gate.sh` | operator 班次 survey（gh issue 增量 / himalaya 只读邮件面）；建卡走 `kanban_card.sh` |
| `deep-check.sh` / `deep_check_gate.sh` / `run-deepcheck.sh` / `deepcheck_card.sh` | kanban swarm 深检（`--resources deepcheck:global`）。**注意区分**：深检**产物路径** `contrib-data/runs/deep-check/` 未退役，仍被 `scripts/approval/auto-gate.sh` 与 `rq.sh` 消费 |
| `own_pr_watch.sh` | 无自动调用方——own-PR 由 operator 守候（gh 实查 + default 板执行卡）；`l2_ledger.sh check` 子命令保留供巡检调用 |
| `e2e-smoke.sh` / `detect/`（5 类捕获自证） | 覆盖并入 `run.sh` 四维度（unit / contract / e2e / static）；全链黑盒由 `e2e/` 承载 |
| `quota_circuit.sh` / `state_brief.sh` / `duty_card.sh` / `coder_upstream_gate.sh` | operator 班次（同 `run-watch.sh` 行） |

**引用面清单（删件提交同批自检）**：`git rm` 一个被引用的脚本时，同一提交必须扫这四个面，并把「现在时」引用改成替代面或直接删句——
① `CLAUDE.md` ② `scripts/**/*.md` ③ `scripts/**/*.sh` 的注释 ④ `scripts/contrib/tests/stubs/*` 头注释。
自检命令 `grep -rn "<已删脚本名>" CLAUDE.md scripts/`：命中只应剩两种合法形态——**本表**，或下方豁免面。

**豁免面（命中不修）**：`scripts/contrib/tests/acceptance/**`（冻结的存量验收脚本，不在 `run.sh` 四维度覆盖集内）+ `scripts/contrib/tests/lib/sandbox.sh`（seam 导出与注释）——这两面随退役整批处置，不在逐件修复卡里单独动。

**存量待办**：`CLAUDE.md` 两处（邮件检查段、快车道段）仍以现在时描述已退役编排，改写被人批闸拦下（写保护名单），未绕过。
