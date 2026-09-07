# contrib-watch 基建测试套件

为 `scripts/contrib/` 的 7 个生产脚本（notify.sh / rq.sh / scan_gate.sh / deep_check_gate.sh / deep-check.sh / run-deepcheck.sh / run-watch.sh）建立的多维回归测试。起因：2026-09-05 事故（notify.sh cfg() 用 jq `//` 把 `notify_dry_run:false` 读成默认 true、run-deepcheck.sh 缺 `cd` 导致 launchd 下 claude 找不到项目 skill），同类静默失效必须**在合入前被确定性捕获**。

零外部依赖：纯 bash 3.2 + jq + python3 + shellcheck（全部本机已有），拒绝 bats/pytest——launchd 极简 PATH 下必须自足。

## 怎么跑

```bash
# 一条命令：unit + contract + e2e + static 四维度 + 5 类 detect 捕获自证；末行 JSON 摘要
bash scripts/contrib/tests/run.sh

# e2e 冒烟独立入口（mktemp 沙箱 + 影子 stub 全链路）
bash scripts/contrib/tests/e2e-smoke.sh
E2E_STUB_FAIL=hermes bash scripts/contrib/tests/e2e-smoke.sh   # 注毒：必须非零退出且账本零新增成功记录
E2E_KEEP=1 bash scripts/contrib/tests/e2e-smoke.sh             # 保留沙箱并在 JSON 报 sandbox 路径

# 捕获自证（5 类缺陷注入，核心验收：pristine 绿 / mutated 红 / diff>=1）
bash scripts/contrib/tests/detect/run.sh bool-parse
bash scripts/contrib/tests/detect/run.sh            # 全 5 类
DETECT_KEEP=1 bash scripts/contrib/tests/detect/run.sh bookkeeping
# → 用保留的沙箱独立复现（不信任 harness 自述）：
CONTRIB_TEST_TARGET=<JSON 里的 sandbox 路径> bash scripts/contrib/tests/run.sh   # 必须非零退出

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

每个测试文件**末行**输出 `##SUMMARY {…}`，run.sh 据此聚合；`exit 0 当且仅当 failed==0 且全部 detect 类 exit 0`。

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
| `MARTIN_DIR` | `$HOME/workspace/martin` | 7 脚本的项目根（notify/rq 的 RQ/NOTIFY 路径跟随） |
| `CONTRIB_DATA_DIR` | `$MARTIN/contrib-data` | 数据目录（notify/rq/scan_gate/gate/deep-check/run-* 全部读写） |
| `NOTIFY_LOCK` | `/tmp/contrib-notify.lock` | notify flush/approve 锁 |
| `NOTIFY_SEND_LAST` | `/tmp/contrib-send-last.json` | hermes send 输出落点（success:true 判据读这里） |
| `RQ_LOCKDIR` | `/tmp/contrib-rq.lock` | rq 写锁 |
| `WATCH_LOCK` | `/tmp/contrib-watch.lock` | run-watch 防重入锁 |
| `DEEPCHECK_TARGET_FILE` | `/tmp/.deepcheck-target` | gate→deep-check 目标传递文件 |
| `DEEPCHECK_LOCK` | `/tmp/contrib-deepcheck.lock` | 深检防重入锁 |
| `HERMES_BIN` / `GH_BIN` / `TUNNEL_BIN` / `OSASCRIPT_BIN` / `GATEWAY_PROBE_BIN` | `hermes` / `gh` / `tunnel` / `osascript` / `pgrep` | 外部命令注入点（影子 stub 双通道之一） |
| `CLAUDE_BIN` | 空 → 现有两级探测（PATH → nvm 目录） | claude 注入点（notify/rq 之外的 3 个 LLM 调用方） |
| `NOTIFY_SOURCE_ONLY` / `RQ_SOURCE_ONLY` | unset | source guard：=1 时只加载函数不执行 dispatch（单测复用纯函数） |

run-watch.sh 的 radar 分支抽为 `maybe_radar [hour]`（缺省 `date +%H` = 现状），供时间窗测试注入。

沙箱把 `HOME` 指向沙箱内 home 并将 `$HOME/workspace/martin` 软链回沙箱根——**万一哪处 seam 漏配，默认值也落在沙箱里，生产零风险**。另外：notify.sh 的审批卡/回执临时文件（`/tmp/contrib-approval-<id>.txt`、`/tmp/contrib-receipt-<id>.txt`）与 AI 摘要 prompt（`/tmp/contrib-digest-prompt-<pid>.txt`）保持现状（按 id/pid 命名、用后即删，不在冻结 seam 名单内）。

## 豁免清单

- **zsh 脚本**（deep-check.sh / run-deepcheck.sh / run-watch.sh / quota_circuit.sh，按 shebang 动态识别）不做 shellcheck（SC1071 是工具对 zsh 的误报），以 `zsh -n` 语法门覆盖（static/syntax.sh 生产 3 个 + gate.sh 全部 zsh shebang）。
- **`scripts/approval/tests/*.bash`** 不在 gate.sh 覆盖集内（口径收窄到 `*.sh`），由 approval 套件自测覆盖（`bash scripts/approval/tests/run.sh`）。
- **`stat -f %m`**（macOS 专属）出现在 deep_check_gate.sh 与 run-watch.sh 的锁滞留检测——macOS-only 语义，不跨平台。
- **`jq -r '.success // false'`**（notify.sh `_send`）保留 `//` 运算符：这里语义正确（把非 true 输出一律当失败），与被修的 cfg 布尔塌缩不是同一形态。
- **e2e-smoke 的前缀锚点行**以 python3 `json.dumps` 默认分隔符格式播种：flush 的账本重写会以同格式重序列化全部行，前缀字节不变断言锚定的是「未入批行不被破坏/丢失」这一真实保证。
- **契约外观察项（现状固化，非缺陷断言）**：dry-run 演练轮会把批次事件标 `pushed=true`（演练消费语义）——契约规约只冻结「零传输调用 + stdout 含 [dry-run]」，是否应保留事件待后续拍板（tests/contract/notify-cli.sh 内有登记）。
- `notify_min_interval_min` 拦截轮与限额拒绝轮 exit 0（属正常跳过/拒绝，非失败）；发送失败/摘要失败轮 rc≠0（契约：事件保留重试，上游 run-watch `|| echo`、deep_check_gate `|| true` 均容错）。

## 与设计的对应

- 设计文档：`.autopilot/runtime/requirements/20260905-对这些关键基建做下单/state.md`
- 测试内容矩阵五类失效 → detect 五类：`bool-parse`（配置布尔误读）/ `cwd-dep`（launchd cwd 依赖）/ `ledger-vs-delivery`（账面成功≠送达）/ `state-machine`（非法迁移）/ `bookkeeping`（限额/幂等/重试/兜底）
- 验收谓词 SSOT：同文档 `## 验收场景`（场景 1-12）；本 README 即「豁免清单」登记处
