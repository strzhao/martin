#!/usr/bin/env bash
# =============================================================================
# write-attribution.acceptance.test.sh — 验收：s4 4.P1 / t1-04 4.1「写入归属定性」引擎
#
# 依据：state.md `## 设计文档`（含「计划评审实证修正」）/ `## 契约规约` / `## 验收场景`（预注册
#   SSOT，标 [调和] 者以调和版为准）+ $TASK_DIR/context.md 历史知识。本文件为**红队独立验收套件**，
#   仅由设计文档契约驱动；不复制被测实现内容、不引用其行号、不假定其私有成员。
#
# 被测对象（全部**黑盒驱动**，本文件不读取其源码）：
#   A) 归属引擎 `scripts/contrib/tests/lib/write-attribution.sh`
#      — 按契约签名调用 wa_snapshot / wa_classify（子 shell 内 source 后调用，stdout/rc 求值）
#   B) 改造后的 `scripts/contrib/tests/acceptance/s4-production-zero-touch.acceptance.sh`
#   C) 改造后的 `scripts/contrib/tests/acceptance/t1-04-isolation-sandbox.acceptance.test.sh`
#      — B/C 仅以 grep 命令位扫描 + 断言行计数（黑盒），不读取其实现逻辑
#
# 覆盖矩阵（reason 覆盖矩阵 + 必覆盖清单 1–6）：
#   S1  registered-append-ok        合规追加（字母表内 + 在窗 ts）
#   S2  alphabet-violation          字母表外追加（marker 文本**不含** S4-P1- 前缀行）
#   S2b canary-marker               新增内容含以 S4-P1- 开头的行 ⇒ 无条件 suite
#   S2c canary-marker 优先级        同窗佐证齐备 ∧ 新增含 S4-P1- 行 ⇒ 仍 suite（先于佐证判定）
#   S3  not-append-only             截断重写
#   S4  inode-changed               mv 替换（内容为前缀追加，仅 inode 变）
#   S5  empty-append                touch（size/hash 不变，仅 mtime 变）
#   S6  registered-append-ok        时间戳边界正例 ts == window_end + 120s
#   S7  timestamp-out-of-window     时间戳边界反例 ts == window_end + 121s
#   S8  no-corroboration            佐证缺失（corroborated-rewrite 无在窗佐证记录）
#   S8b no-corroboration 时序近邻   佐证在窗但 |佐证 ts − 变更文件 mtime| > 30s ⇒ suite
#   S9  created-unallowed|no-corroboration  判据面新建（glob 模式 + 精确路径 双形态）
#   S10 corroborated-ok             佐证齐备（改写 + 佐证日志在窗记录 + Δt ≤ 30s）
#   S11 outside-surface             面外路径（证据行存在、不判失败、不静默丢弃）
#   S12 零变更                      total=0 ∧ rc=0 ∧ 零 per-file 行
#   S13 exit 2 fail-closed          清单缺失 / 空 / NF≠5 / 无捕获组 / mode 非法 /
#                                   corroborated 佐证 :none / 删除行 DbC（字母表非 :none、佐证 :none）/
#                                   快照缺失 / 窗口非整数
#   S14 恒等式                      每例核 total == external + suite + outside ∧ unclassified == 0
#   S15 删除类正例（R3）            corroborated-delete 面：真 rm + 真在窗佐证记录 ⇒ external/corroborated-delete-ok
#                                   （证据行反查：ts= 真存在于写手日志、dir_mtime= 十进制且 == 实测锚、
#                                    Δt= 非零且 == 构造偏移；第二 <TS> 轮杀写死文件名/常量 Δt；
#                                    第三轮 = 同模式两行并存（create 行在前）⇒ D 仍只认 delete 行，E-1）
#   S16 删除类无佐证（R3）          锚可取但无在窗记录 ⇒ suite/no-delete-corroboration；
#                                   S-03 边界 |Δ|=30s ⇒ external / 31s ⇒ suite（含 |·| 对侧）
#   S17 面外删除（无 marker，R3）   未登记路径被删 ⇒ outside-surface（S-06/S-11：不冒领 external、不误计 suite）
#   S18 面外删除（有 marker，R3）   未登记且 basename 以 S4-P1- 开头的路径被删 ⇒ suite/canary-marker
#                                   （R-1：删除类路径短路先于一切，面外也判红）
#   S19 混合窗口等值恒等式（R3）    同窗 4 external + 1 suite + 1 outside ⇒ external==4 ∧ suite==1 ∧ outside==1
#                                   ∧ 三类和==total ∧ total==窗口差集文件数 ∧ unclassified==0（S-12，等值断言）
#   T14 reason 闭集表自证（R4）      新令牌 `ownership-delete-ok` 归 external 侧 ∧ class↔reason 失配仍被检出
#   T15 跨窗所有权链（R4/S-15）      写手删其**上一轮**所建、日志**窗口前字节区**具名、本窗活跃且无近邻记录的
#                                   四件同 stem 产物 ⇒ 四件 external/ownership-delete-ok（owner=/owner_ts=/
#                                   owner_log=/act_ts= 全量反查；两个 <TS> 两轮杀写死；窗口差集非空；
#                                   D-β 前提自证 = 活跃记录与锚相距 > 30s ⇒ 放行只能来自 D-α）
#   T16 D-α 负对照三态（R4/S-16）    ①marker 探针 ⇒ canary-marker（活跃记录落在锚 ±30s **内**仍判红
#                                     ⇒ 路径短路先于一切）；②无 marker 无具名记录 ⇒ no-delete-corroboration
#                                     （写手本窗活跃 ≠ 所有权）；③本窗伪造具名记录（回填旧 ts / 当前 ts）
#                                     ⇒ 仍 no-delete-corroboration（记录在窗口**后**字节区 ⇒ 不构成所有权）
#   M1/M2 mutation 抗性             库副本注入「一律 external」「未注册也放行」→ 同一检查器必转红
#   E1–E5 影子端到端                canary-create / canary-append / external-append / canary-delete（三轮等量）/
#                                   external-delete 真跑 s4；E6 = 影子树零残留守卫
#   G1–G3 守卫不回归                s4 命令位 /usr/bin/diff == 2、t1-04 == 1、裸 diff == 0、
#                                   各恰 1 行 `-x /usr/bin/diff`；diff-pin-canary 套件仍 rc=0；无 skip 降级
#   N1–N3 断言条数防删锚            s4 4.P1 段 / t1-04 4.1 段断言行数 ≥ 改造前基线（冻结常量）
#
# 所依据的谓词口径版本：state.md `## 验收场景` **第 2 轮定向重审后**的版本 + **第 3 轮删除类（R3）**
#   + **第 4 轮跨窗所有权链（R4；`## R4 修复规格`，含「D-α 新字段一律追加在 `dir_mtime=` 之后」的契约修正）**，即
#   ① 类别闭集 = 三值 {suite, external, outside-surface}（场景3.P1 / 4.P4 同口径）；
#   ② reason 闭集含 `canary-marker`（新增内容含以 `S4-P1-` 开头的行 ⇒ 无条件 suite，先于佐证判定）；
#   ③ `corroborated-*` 成立需两条同时满足：佐证日志在窗有合规记录 ∧ |佐证 ts − 变更文件 mtime| ≤ 30s；
#   ④ 清单 10 条 + 覆盖守卫三条声明式排除谓词（谓词面归单测 C16，本套件不重复求值）；
#   ⑤ 删除类（R3）：kind==D ∧ basename 以 `S4-P1-` 开头 ⇒ 无条件 suite/canary-marker（先于一切，面内面外同）；
#      corroborated-delete 面内需 删除时点锚可取（父目录 mtime，sidecar `<out>.dirs`）∧ 佐证日志在窗合规记录
#      ∧ |记录 ts − 锚| ≤ 30s ⇒ external/corroborated-delete-ok；否则 suite/no-delete-corroboration；
#      锚不可取（sidecar 缺/父目录不在目录表/mtime 非十进制）同样 ⇒ suite/no-delete-corroboration（EXTRA dir_mtime=none）；
#      reason 闭集新增两令牌：external `corroborated-delete-ok` / suite `no-delete-corroboration`；
#      面内非 corroborated-delete 行（append-records / corroborated-rewrite / corroborated-create）的删除
#      仍为 suite/`deleted`（既有语义逐字保留）；面外未登记路径的删除仍为 outside-surface（R-1 的 marker 短路除外）；
#   ⑥ 注入旋钮 s4 侧 4→6（+`canary-delete` / `external-delete`，两段式 delete-plant/delete-fire：plant 先于快照、
#      fire 在 run.sh 之后）；t1-04 旋钮闭集保持 4 值（未知值 fail-closed，属 per-file 语义，本套件不代其求值）。
#   ⑦ 删除类（R4）：D-β（父目录锚 ±30s 近邻）**先判、逐字不变**；其后追加 **D-α 跨窗所有权链** —— 佐证日志中
#      存在一条合规记录（匹配该日志字母表 ∧ 可提取 ts）其行文本**含被删物 stem**（stem = basename 去掉首个
#      `.` 及其后；|stem| ≥ WA_OWNER_MIN_STEM = 8）∧ 该行**起始字节偏移 < 该日志在 before 快照中的 size**
#      （= 窗口前字节区），且同一日志存在 ts ∈ [t0−120s, t1+120s] 的合规记录（写手本窗活跃）
#      ⇒ external / `ownership-delete-ok`（reason 闭集 external 侧第 4 员）；否则 suite / `no-delete-corroboration`。
#      D-α 证据行 / 失败行的新字段（`owner=` / `owner_ts=` / `owner_log=` / `act_ts=` / `act=`）一律**追加在
#      `dir_mtime=` 之后** ⇒ 既有 `_ev_ts`（`%% dir_mtime=` 截断）与 `_ev_dirmtime`（贪婪）语义逐字不变。
#
# 纪律：
#   - 每条断言硬失败（无 SKIP / 无 warn 降级 / 无 `|| true` 宽容 / 无条件放行）
#   - 零仓内写入：临时产物只进 mktemp 目录（EXIT trap 清理）；影子 contrib-data 由本套件创建、
#     退出时删除；**禁**写真实生产 contrib-data；**禁**调用 hermes/gh/claude/tunnel/osascript
#   - 契约模糊处标 CONTRACT_AMBIGUOUS（见文末清单），不推测未声明的私有成员
# =============================================================================
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SELF_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$REPO_ROOT" ] || [ ! -d "$REPO_ROOT" ]; then
  printf 'ACCEPTANCE-FAIL[env]: REPO_ROOT 不可解析（%s 非 git 仓 / git 不可用）\n' "$SELF_DIR" >&2
  exit 1
fi
TESTS_ROOT="$REPO_ROOT/scripts/contrib/tests"
ENGINE_LIB="$TESTS_ROOT/lib/write-attribution.sh"
S4="$TESTS_ROOT/acceptance/s4-production-zero-touch.acceptance.sh"
T104="$TESTS_ROOT/acceptance/t1-04-isolation-sandbox.acceptance.test.sh"
CANARY="$TESTS_ROOT/acceptance/diff-pin-canary.acceptance.test.sh"

# 改造前冻结基线：HEAD@71b6956（本卡实现提交之前的 main 侧合并点）；断言行数基线由该版本量测。
FROZEN_SHA="71b6956"
S4_REL="scripts/contrib/tests/acceptance/s4-production-zero-touch.acceptance.sh"
T104_REL="scripts/contrib/tests/acceptance/t1-04-isolation-sandbox.acceptance.test.sh"
BASE_S4_P1_ASSERTS=2      # 旧版 4.P1 段：`[ -s ... ] || die` + `eq "$DIFFN" 0`
BASE_T104_41_ASSERTS=4    # 旧版 4.1 段：`_fail` ×2 + `assert_eq` ×2

export DIM=acceptance
T_FILE="$(basename "${BASH_SOURCE[0]}")"
# shellcheck source=/dev/null
source "$TESTS_ROOT/lib/assert.sh"
t_init "$T_FILE"

WA_SB="$(mktemp -d "${TMPDIR:-/tmp}/acc-wa.XXXXXX")" || {
  printf 'ACCEPTANCE-FAIL[env]: mktemp 失败（无法建立临时工作区）\n' >&2
  exit 1
}
SHADOW="$REPO_ROOT/contrib-data"
SHADOW_CREATED=0
_cleanup() {
  rm -rf "$WA_SB"
  if [ "$SHADOW_CREATED" = "1" ] && [ -d "$SHADOW" ]; then rm -rf "$SHADOW"; fi
}
trap '_cleanup' EXIT

# --- 工具绝对路径（避开 PATH 遮蔽面；context.md：PATH 上第三方 diff 恒 rc=0 零输出）--------
PIN_DIFF=/usr/bin/diff
PIN_DATE=/bin/date
PIN_PGREP=/usr/bin/pgrep
ART="/tmp/autopilot-artifacts"

# =============================================================================
# 通用黑盒驱动 / 解析助手
# =============================================================================

# wa_* 在**子 shell 内** source 后调用（隔离被测库对父 shell 的副作用）
_wa_call() { # <fn> <args...> → rc/stdout 透传
  local fn="$1"
  shift
  # shellcheck source=/dev/null
  ( . "$ENGINE_LIB" >/dev/null 2>&1; "$fn" "$@" )
}
_wa_call_lib() { # <lib> <fn> <args...>
  local lib="$1"
  local fn="$2"
  shift 2
  # shellcheck source=/dev/null
  ( . "$lib" >/dev/null 2>&1; "$fn" "$@" )
}

# 末行计数（契约 stdout 末行：WA total=<n> external=<n> suite=<n> [outside=<n>] unclassified=<n> diff_lines=<n>）
_wa_sum() { # <stdout-file> <key> → 值（缺失=空）
  awk -v k="$2" '
    /^WA / { n=split($0, a, " "); for (i=1;i<=n;i++) { if (index(a[i], k "=") == 1) v=substr(a[i], length(k)+2) } }
    END { if (v != "") print v }' "$1"
}

# 逐 WA-CLASS 行的 reason / class / 计数（契约：WA-CLASS <class> path=<p> reason=<tok> …）
_class_counts() { # <out> → "external suite outside unknown"（文件缺失 ⇒ unknown=1 计一违规）
  if [ ! -f "$1" ]; then
    printf '0 0 0 1'
    return 0
  fi
  awk '/^WA-CLASS / {
      r=""
      for (i=1;i<=NF;i++) { if (index($i,"reason=") == 1) r=substr($i,8) }
      if (r=="registered-append-ok" || r=="corroborated-ok" || r=="corroborated-delete-ok" || r=="ownership-delete-ok") e++
      else if (r=="not-append-only" || r=="inode-changed" || r=="alphabet-violation" || r=="empty-append" || r=="timestamp-out-of-window" || r=="created-unallowed" || r=="deleted" || r=="no-corroboration" || r=="canary-marker" || r=="no-delete-corroboration") s++
      else if (r=="outside-surface") o++
      else x++
    }
    END { printf "%d %d %d %d", e+0, s+0, o+0, x+0 }' "$1"
}
_class_line_count() { # <out> → per-file 分类行数（文件缺失 ⇒ -1，令调用方转红）
  if [ ! -f "$1" ]; then
    printf -- '-1'
    return 0
  fi
  awk '/^WA-CLASS /{c++} END{print c+0}' "$1"
}

# 恒等式检查器（**纯谓词**，输出违规清单；空输出 = 全过）
# 覆盖：键齐备 / unclassified==0 / total==行数 / external,suit 计数对齐 / total==external+suite+outside /
#       reason ∈ 闭集 / class↔reason 一致 / 每行含 path
_identity_report() { # <stdout-file> <out-file>
  local so="$1" out="$2" t e s o u d cl cnt ext sui outs x
  if [ ! -f "$so" ]; then printf 'VIOL 引擎 stdout 文件缺失（引擎未产出？）: %s\n' "$so"; fi
  if [ ! -f "$out" ]; then
    printf 'VIOL per-file 分类文件缺失（引擎未产出 <out>？）: %s\n' "$out"
    return 0
  fi
  t="$(_wa_sum "$so" total)"; e="$(_wa_sum "$so" external)"; s="$(_wa_sum "$so" suite)"
  o="$(_wa_sum "$so" outside)"; u="$(_wa_sum "$so" unclassified)"; d="$(_wa_sum "$so" diff_lines)"
  cnt="$(_class_counts "$out")"
  ext="$(printf '%s' "$cnt" | awk '{print $1}')"
  sui="$(printf '%s' "$cnt" | awk '{print $2}')"
  outs="$(printf '%s' "$cnt" | awk '{print $3}')"
  x="$(printf '%s' "$cnt" | awk '{print $4}')"
  cl="$(_class_line_count "$out")"

  [ -n "$t" ] || printf 'VIOL 末行缺 key: total\n'
  [ -n "$e" ] || printf 'VIOL 末行缺 key: external\n'
  [ -n "$s" ] || printf 'VIOL 末行缺 key: suite\n'
  [ -n "$u" ] || printf 'VIOL 末行缺 key: unclassified\n'
  [ -n "$d" ] || printf 'VIOL 末行缺 key: diff_lines\n'
  [ -n "${t:-}" ] && [ -n "${e:-}" ] && [ -n "${s:-}" ] && [ -n "${u:-}" ] && [ -n "${d:-}" ] || return 0

  [ "$u" = "0" ] || printf 'VIOL unclassified=%s（恒等式要求 0）\n' "$u"
  [ "$t" = "$cl" ] || printf 'VIOL total=%s ≠ WA-CLASS 行数=%s（每变更文件恰 1 行）\n' "$t" "$cl"
  [ "$e" = "$ext" ] || printf 'VIOL 末行 external=%s ≠ 分类行 external 数=%s\n' "$e" "$ext"
  [ "$s" = "$sui" ] || printf 'VIOL 末行 suite=%s ≠ 分类行 suite 数=%s\n' "$s" "$sui"
  if [ -n "$o" ]; then
    [ "$o" = "$outs" ] || printf 'VIOL 末行 outside=%s ≠ 分类行 outside 数=%s\n' "$o" "$outs"
  fi
  [ "$t" = "$((e + s + outs))" ] || printf 'VIOL total=%s ≠ external(%s)+suite(%s)+outside(%s)\n' "$t" "$e" "$s" "$outs"
  [ "$x" = "0" ] || printf 'VIOL %s 行的 reason 不在契约闭集内\n' "$x"
  [ "$d" = "0" ] && { [ "$t" = "0" ] || printf 'VIOL diff_lines=0 却 total=%s（零变更应无 per-file 行）\n' "$t"; }
  awk '/^WA-CLASS / {
      cat=$2; r=""; p=""
      for (i=1;i<=NF;i++) { if (index($i,"reason=")==1) r=substr($i,8); if (index($i,"path=")==1) p=substr($i,6) }
      if (r=="registered-append-ok" || r=="corroborated-ok" || r=="corroborated-delete-ok" || r=="ownership-delete-ok") expc="external"
      else if (r=="outside-surface") expc="outside"
      else if (r=="not-append-only" || r=="inode-changed" || r=="alphabet-violation" || r=="empty-append" || r=="timestamp-out-of-window" || r=="created-unallowed" || r=="deleted" || r=="no-corroboration" || r=="canary-marker" || r=="no-delete-corroboration") expc="suite"
      else expc="UNKNOWN"
      if (expc=="UNKNOWN") printf "VIOL reason 越界: %s（path=%s）\n", r, p
      else if (expc=="outside") { if (cat!="outside" && cat!="outside-surface") printf "VIOL class/reason 失配: class=%s reason=%s path=%s\n", cat, r, p }
      else if (cat != expc) printf "VIOL class/reason 失配: class=%s reason=%s path=%s\n", cat, r, p
      if (p == "") printf "VIOL 分类行缺 path 字段: %s\n", $0
    }' "$out"
}

# 期望检查器（纯谓词）：指定 path 的分类行必须存在且 reason ∈ 期望集
_expect_report() { # <out> <path> <reason1|reason2|...>
  if [ ! -f "$1" ]; then
    printf 'VIOL 分类文件缺失（无法判定期望行 path=%s）: %s\n' "$2" "$1"
    return 0
  fi
  awk -v wp="$2" -v wr="$3" '
    BEGIN { np=split(wr, rs, "|") }
    /^WA-CLASS / {
      p=""; r=""
      for (i=1;i<=NF;i++) { if (index($i,"path=")==1) p=substr($i,6); if (index($i,"reason=")==1) r=substr($i,8) }
      if (p == wp) {
        found++
        hit=0
        for (j=1;j<=np;j++) { if (r == rs[j]) hit=1 }
        if (hit == 0) printf "VIOL path=%s 的 reason=%s 不在期望集 {%s}\n", p, r, wr
      }
    }
    END { if (found == 0) printf "VIOL 未找到 path=%s 的任何 WA-CLASS 行\n", wp }' "$1"
}

_absent_report() { # <out> <path> → 该 path 若存在分类行则报违规
  if [ ! -f "$1" ]; then
    printf 'VIOL 分类文件缺失（无法判定缺席 path=%s）: %s\n' "$2" "$1"
    return 0
  fi
  awk -v wp="$2" '
    /^WA-CLASS / {
      p=""
      for (i=1;i<=NF;i++) { if (index($i,"path=")==1) p=substr($i,6) }
      if (p == wp) printf "VIOL path=%s 不应出现分类行\n", p
    }' "$1"
}

# =============================================================================
# 合成树（形态学全表）——自建仓根 + 自建清单，不依赖真实 contrib-data
# =============================================================================
SYN_ROOT=""; SNAP_B=""; SNAP_A=""; R_RC=""; R_SO=""; R_OUT=""
SYN_REG="$WA_SB/registry.tsv"
TSTAMP_RE='([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2})'
ALPHA_APP="^\\[${TSTAMP_RE}\\] app: |^OK\$"

{
  printf 'contrib-data/logs/app.log\tapp\tappend-records\t%s\t:none\n' "$ALPHA_APP"
  printf 'contrib-data/state.json\tappstate\tcorroborated-rewrite\t%s\tcontrib-data/logs/app.log\n' "$ALPHA_APP"
  printf 'contrib-data/newdir/*\tappnew\tcorroborated-create\t%s\tcontrib-data/logs/app.log\n' "$ALPHA_APP"
  printf 'contrib-data/newfile.json\tappnew2\tcorroborated-create\t%s\tcontrib-data/logs/app.log\n' "$ALPHA_APP"
} > "$SYN_REG"

_syn_before() { # <tag> → 建合成仓根 + before 快照
  local tag="$1" rc
  SYN_ROOT="$WA_SB/syn.$tag"
  mkdir -p "$SYN_ROOT/contrib-data/logs" "$SYN_ROOT/contrib-data/newdir" "$SYN_ROOT/contrib-data/scratch"
  printf '[2026-01-01 00:00:00] app: seed-a\n' > "$SYN_ROOT/contrib-data/logs/app.log"
  printf '[2026-01-01 00:00:01] app: seed-b\n' >> "$SYN_ROOT/contrib-data/logs/app.log"
  printf '{"state":"seed"}\n' > "$SYN_ROOT/contrib-data/state.json"
  printf 'draft\n' > "$SYN_ROOT/contrib-data/scratch/draft.md"
  SNAP_B="$WA_SB/$tag.before.snap"
  SNAP_A="$WA_SB/$tag.after.snap"
  _wa_call wa_snapshot "$SYN_ROOT" "$SNAP_B" > "$WA_SB/$tag.snapb.out" 2>&1
  rc=$?
  [ "$rc" = "0" ] || _fail "前置 wa_snapshot(before) rc=0" "rc=$rc tag=${tag}；合成树快照失败"
  [ -s "$SNAP_B" ] || _fail "前置 快照非空" "tag=${tag}；快照为空 ${SNAP_B}"
}

_syn_after() { # <tag> <t0> <t1> [registry] → after 快照 + classify，设 R_RC/R_SO/R_OUT
  local tag="$1" t0="$2" t1="$3" reg="${4:-$SYN_REG}" rc
  R_SO="$WA_SB/$tag.classify.out"
  R_OUT="$WA_SB/$tag.wa-class"
  _wa_call wa_snapshot "$SYN_ROOT" "$SNAP_A" > "$WA_SB/$tag.snapa.out" 2>&1
  rc=$?
  [ "$rc" = "0" ] || _fail "前置 wa_snapshot(after) rc=0" "rc=$rc tag=$tag"
  _wa_call wa_classify "$SYN_ROOT" "$SNAP_B" "$SNAP_A" "$reg" "$R_OUT" "$t0" "$t1" > "$R_SO" 2>&1
  R_RC=$?
}

# 组合检查器（纯谓词）：rc + 恒等式 + 期望行；输出违规清单（空 = 通过）
_case_report() { # <rc> <want-rc> <so> <out> <path> <reasons>
  local rc="$1" want="$2" so="$3" out="$4" p="$5" r="$6" digest=""
  [ -f "$so" ] && digest="$(tr '\n' '|' < "$so")"
  [ "$rc" = "$want" ] || printf 'VIOL wa_classify rc=%s 期望 %s；引擎输出=[%s]\n' "$rc" "$want" "$digest"
  _identity_report "$so" "$out"
  _expect_report "$out" "$p" "$r"
}

# 组合断言：rc + 恒等式 + 期望行
_case_asserts() { # <tag> <want-rc> [<path> <reasons>] ...
  local tag="$1" want="$2" rep digest=""
  shift 2
  [ -f "$R_SO" ] && digest="$(tr '\n' '|' < "$R_SO")"
  assert_eq "$R_RC" "$want" "${tag} wa_classify rc 期望 ${want}；引擎输出=[${digest}]"
  rep="$(_identity_report "$R_SO" "$R_OUT")"
  assert_eq "$rep" "" "$tag 账目恒等式 total==external+suite+outside ∧ unclassified==0"
  while [ "$#" -gt 0 ]; do
    rep="$(_expect_report "$R_OUT" "$1" "$2")"
    assert_eq "$rep" "" "$tag 分类行 path=$1 reason∈{$2}"
    shift 2
  done
}

# =============================================================================
# 删除类（R3）合成面：corroborated-delete 清单行 + 删除时点锚（父目录 mtime）+ 佐证近邻
#   依据：state.md `## 设计文档`「归属规则（新增部分）」/「契约规约」清单 schema、sidecar、边界值、example；
#         `## 验收场景` S-01…S-07 / S-11 / S-12（含 R-1 面外 marker 短路、R-5 点名子句）。
#   合成面构成（**独立于** S1–S13/M1/M2 的 SYN_REG，不改其产物）：
#     `contrib-data/pending/*`   = corroborated-delete（writer=notify，佐证 `contrib-data/logs/notify.log`）
#     `contrib-data/logs/notify.log` = append-records（字母表须含捕获组；承接写手自身日志追加）
#     `contrib-data/scratch/`    = 不登记 ⇒ outside-surface 对照面
#   锚构造纪律：本面锚一律由**真 rm** 产生（目录 mtime = 该目录最后一次条目增删时刻），
#     不用 `touch -t` 伪造（`touch -t` 构造目录锚属单测 C33 的形态）；佐证记录的 ts 由**实测锚**推出
#     （构造偏移），构造序镜像生产实测：锚 10:04:43 / 记录 10:04:34（偏移 9s）。
# =============================================================================
SYN_DEL_REG="$WA_SB/registry-delete.tsv"
PIN_STAT=/usr/bin/stat
DEL_DIR="contrib-data/pending"
DEL_LOG="contrib-data/logs/notify.log"
DEL_TS_A="20260914-090949"          # worker 生产实测三件的 <TS>（S-01 回归锚）
DEL_TS_B="20260914-101010"          # 第二个 <TS>（S-01 反空转：杀写死文件名/时间戳）
DEL_P_A="$DEL_DIR/digest-$DEL_TS_A.json"
DEL_P_A_BODY="$DEL_DIR/digest-$DEL_TS_A.body.md"
DEL_P_A_CARD="$DEL_DIR/digest-$DEL_TS_A.card.json"
DEL_P_B="$DEL_DIR/digest-$DEL_TS_B.json"
DEL_OUT="contrib-data/scratch/draft.md"
DEL_MARK_PROBE="contrib-data/scratch/S4-P1-delete-probe.txt"
DEL_SUITE_PROBE="$DEL_DIR/S4-P1-suite-probe.txt"
ALPHA_NOTIFY="^\\[${TSTAMP_RE}\\] notify: "

{
  printf '%s\tnotify\tappend-records\t%s\t:none\n' "$DEL_LOG" "$ALPHA_NOTIFY"
  printf '%s/*\tnotify\tcorroborated-delete\t:none\t%s\n' "$DEL_DIR" "$DEL_LOG"
} > "$SYN_DEL_REG"
# E-1 形态（生产清单同形）：同一路径模式两行并存——create 行在**前**、delete 行在后；
# 契约「D 只认 corroborated-delete 行」⇒ 删除必须走 delete 行（禁「首匹配即返回」）。
SYN_DEL_MULTI_REG="$WA_SB/registry-delete-multi.tsv"
{
  printf '%s\tnotify\tappend-records\t%s\t:none\n' "$DEL_LOG" "$ALPHA_NOTIFY"
  printf '%s/*\tnotify\tcorroborated-create\t%s\t%s\n' "$DEL_DIR" "$ALPHA_NOTIFY" "$DEL_LOG"
  printf '%s/*\tnotify\tcorroborated-delete\t:none\t%s\n' "$DEL_DIR" "$DEL_LOG"
} > "$SYN_DEL_MULTI_REG"
DEL_REG=""   # 逐轮可覆写（缺省取 SYN_DEL_REG 的值）

_del_before() { # <tag> [plant-relpath...] → 建删除类合成根（plant 先于 before 快照植入）+ before 快照
  local tag="$1" rc p
  shift
  SYN_ROOT="$WA_SB/syn.$tag"
  mkdir -p "$SYN_ROOT/contrib-data/logs" "$SYN_ROOT/contrib-data/pending" "$SYN_ROOT/contrib-data/scratch"
  # 窗口外 seed 记录（佐证搜索的阴性背景；S16a 的「记录缺席」正是靠它不可用）
  printf '[2026-01-01 00:00:00] notify: seed-out-of-window\n' > "$SYN_ROOT/$DEL_LOG"
  printf '[2026-01-01 00:00:01] notify: seed-out-of-window-2\n' >> "$SYN_ROOT/$DEL_LOG"
  printf '{"digest":"%s"}\n' "$DEL_TS_A" > "$SYN_ROOT/$DEL_P_A"
  printf 'body\n' > "$SYN_ROOT/$DEL_P_A_BODY"
  printf '{"card":1}\n' > "$SYN_ROOT/$DEL_P_A_CARD"
  printf 'draft\n' > "$SYN_ROOT/$DEL_OUT"
  for p in "$@"; do
    mkdir -p "$SYN_ROOT/$(dirname "$p")"
    printf 'planted\n' > "$SYN_ROOT/$p"
  done
  SNAP_B="$WA_SB/$tag.before.snap"
  SNAP_A="$WA_SB/$tag.after.snap"
  _wa_call wa_snapshot "$SYN_ROOT" "$SNAP_B" > "$WA_SB/$tag.snapb.out" 2>&1
  rc=$?
  [ "$rc" = "0" ] || _fail "前置 wa_snapshot(before) rc=0" "rc=$rc tag=${tag}（删除类合成树）"
  [ -s "$SNAP_B" ] || _fail "前置 快照非空" "tag=${tag}；快照为空 ${SNAP_B}"
}

_del_record() { # <ts-str> <n> → 写手日志追加 n 条在窗佐证记录（字母表内；n=被删路径数）
  local ts="$1" n="$2" i=1
  while [ "$i" -le "$n" ]; do
    printf '[%s] notify: digest 卡已建 t_shadow%d（联调 fixture）\n' "$ts" "$i" >> "$SYN_ROOT/$DEL_LOG"
    i=$((i + 1))
  done
}

_del_rm_paths() { # <relpath...> → 真 rm（产生真锚：父目录 mtime 更新为删除瞬间）
  local p
  for p in "$@"; do
    rm -f "$SYN_ROOT/$p"
    [ ! -e "$SYN_ROOT/$p" ] || _fail "前置 真 rm 生效" "path=${p} 仍存在（kind=D 与锚均不成立）"
  done
}

DEL_ANCHOR=""; DEL_TSSTR=""
_del_anchor_now() { # <reldir> → 设 DEL_ANCHOR = 实测父目录 mtime（与 after 快照同刻同源）
  DEL_ANCHOR="$("$PIN_STAT" -f %m "$SYN_ROOT/$1")"
  case "$DEL_ANCHOR" in
    ''|*[!0-9]*) _fail "前置 目录锚为十进制 epoch" "stat -f %m $SYN_ROOT/$1 ⇒ [${DEL_ANCHOR}]" ;;
  esac
}

_del_pos() { # <tag> <offset-s> <relpath...> → 真 rm + 实测锚 + 由锚推出的在窗佐证记录 + classify
  # 清单取 ${DEL_REG:-$SYN_DEL_REG}（多行/单行两形态共用同一驱动）
  local tag="$1" off="$2"
  shift 2
  _del_rm_paths "$@"
  _del_anchor_now "$DEL_DIR"
  DEL_TSSTR="$("$PIN_DATE" -r "$((DEL_ANCHOR - off))" '+%Y-%m-%d %H:%M:%S')"
  _del_record "$DEL_TSSTR" "$#"
  _syn_after "$tag" "$((DEL_ANCHOR - 300))" "$DEL_ANCHOR" "${DEL_REG:-$SYN_DEL_REG}"
}

_diffset_n() { # <before-snap> <after-snap> → 窗口差集文件数（**独立口径**：按快照行逐路径比对，不信引擎自报）
  local bm="$WA_SB/diffset.b" am="$WA_SB/diffset.a"
  awk '{ p=""; for (i=1;i<=NF;i++) { if (index($i,"contrib-data/")>0) { p=$i; break } } if (p!="") print p "\t" $0 }' "$1" > "$bm"
  awk '{ p=""; for (i=1;i<=NF;i++) { if (index($i,"contrib-data/")>0) { p=$i; break } } if (p!="") print p "\t" $0 }' "$2" > "$am"
  awk -F'\t' '
    NR==FNR { b[$1]=substr($0, index($0,"\t")+1); next }
    { a[$1]=substr($0, index($0,"\t")+1) }
    END {
      n=0
      for (p in b) { if (!(p in a)) n++; else if (b[p] != a[p]) n++ }
      for (p in a) { if (!(p in b)) n++ }
      print n+0
    }' "$bm" "$am"
}

_line_for_path() { # <out-file> <relpath> → 该 path 的首条 WA-CLASS 行（无则空）
  awk -v wp="$2" '
    /^WA-CLASS / {
      p=""
      for (i=1;i<=NF;i++) { if (index($i,"path=")==1) p=substr($i,6) }
      if (p == wp) { print; exit }
    }' "$1"
}
_ev_dt() { # <line> → Δt 的十进制秒（无则空）
  printf '%s\n' "$1" | sed -n 's/.*Δt=\([0-9][0-9]*\)s\{0,1\}.*/\1/p'
}
_ev_dirmtime() { # <line> → dir_mtime 十进制 epoch（无则空）
  printf '%s\n' "$1" | sed -n 's/.*dir_mtime=\([0-9][0-9]*\).*/\1/p'
}
_ev_ts() { # <line> → ts 字段值（可含空格；截到 ` dir_mtime=` 或行尾）
  local rest="$1"
  case "$rest" in
    *" ts="*) rest="${rest#* ts=}" ;;
    *) printf ''; return 0 ;;
  esac
  printf '%s' "${rest%% dir_mtime=*}"
}
_del_ev_asserts() { # <tag> <relpath> <expect-anchor> <expect-ts> <expect-dt> → 删除类证据行字段反查
  local tag="$1" p="$2" anchor="$3" ts="$4" dt="$5" line dirm tsgot hits dec
  line="$(_line_for_path "$R_OUT" "$p")"
  assert_ne "$line" "" "${tag} 证据行存在（path=${p}）"
  dirm="$(_ev_dirmtime "$line")"
  assert_ne "$dirm" "" "${tag} 证据行带 dir_mtime=<epoch>（path=${p}）"
  case "$dirm" in
    ''|*[!0-9]*) dec="nondecimal" ;;
    *) dec="decimal" ;;
  esac
  assert_eq "$dec" "decimal" "${tag} dir_mtime 为十进制表示（实得 [${dirm}]）"
  assert_eq "$dirm" "$anchor" "${tag} dir_mtime == 实测父目录锚（期望 ${anchor}，实得 [${dirm}]）"
  assert_eq "$(_ev_dt "$line")" "$dt" "${tag} Δt=${dt}（实测构造偏移；非零、非硬编码常量）"
  assert_ne "$(_ev_dt "$line")" "0" "${tag} Δt 非零（S-02 证伪：Δt 恒 0 即红）"
  tsgot="$(_ev_ts "$line")"
  assert_eq "$tsgot" "$ts" "${tag} 证据行 ts= 与构造记录时刻一致（期望 [${ts}]，实得 [${tsgot}]）"
  hits="$(awk -v t="$ts" 'index($0,t)>0 {n++} END{print n+0}' "$SYN_ROOT/$DEL_LOG")"
  assert_ne "$hits" "0" "${tag} ts= 反查写手日志命中 ${hits} 行（S-02：证据行的记录时刻必须真实存在）"
}
_ev_sum() { # <ev-dump> <key> → 末条 `WA total=` 行中的 key 值（无则空；用于影子 e2e 输出转储）
  awk -v k="$2" '
    /WA total=/ { n=split($0, a, " "); for (i=1;i<=n;i++) { if (index(a[i], k "=") == 1) v=substr(a[i], length(k)+2) } }
    END { if (v != "") print v }' "$1"
}

# =============================================================================
t_case "S0 环境前置：引擎库存在且可 source（契约 API 可调用）"
if [ ! -f "$ENGINE_LIB" ]; then
  _fail "前置 引擎库存在" "缺失: ${ENGINE_LIB}；归属引擎未交付"
  t_finish
fi
[ -x "$PIN_DIFF" ] || { _fail "前置 /usr/bin/diff" "缺失（pin 绝对路径前提）"; t_finish; }
[ -x "$PIN_DATE" ] || { _fail "前置 /bin/date" "缺失"; t_finish; }
_wa_call wa_registry_default "$TESTS_ROOT" > "$WA_SB/reg-default.out" 2>/dev/null
REG_DEFAULT_RC=$?
assert_eq "$REG_DEFAULT_RC" "0" "S0 wa_registry_default rc=0（API 可达）"
assert_ne "$(awk 'NF{n=1} END{print n+0}' "$WA_SB/reg-default.out")" "0" \
  "S0 wa_registry_default stdout 给出清单路径（非空）"

NOW="$("$PIN_DATE" +%s)"
W0=$((NOW - 300))
W1="$NOW"

# =============================================================================
t_case "S1 registered-append-ok：合规追加（字母表内 + 在窗时间戳）→ external"
_syn_before s1
S1T="$("$PIN_DATE" +%s)"
printf '[%s] app: tick-1\n' "$("$PIN_DATE" -r "$S1T" '+%Y-%m-%d %H:%M:%S')" >> "$SYN_ROOT/contrib-data/logs/app.log"
# 边界：追加块含一条字母表内无时间戳记录（^OK$）也不得整体判红
printf 'OK\n' >> "$SYN_ROOT/contrib-data/logs/app.log"
_syn_after s1 "$((S1T - 60))" "$S1T"
_case_asserts "S1" "0" "contrib-data/logs/app.log" "registered-append-ok"

# =============================================================================
t_case "S2 alphabet-violation：注册路径追加字母表外行（非 S4-P1- marker）→ suite"
_syn_before s2
printf 'WA-ALPHABET-OUT-OF-SET line\n' >> "$SYN_ROOT/contrib-data/logs/app.log"
_syn_after s2 "$W0" "$W1"
_case_asserts "S2" "0" "contrib-data/logs/app.log" "alphabet-violation"

# =============================================================================
t_case "S2b canary-marker：新增内容含以 S4-P1- 开头的行 ⇒ 无条件 suite"
_syn_before s2b
printf 'S4-P1-CANARY-MARKER injected-by-suite\n' >> "$SYN_ROOT/contrib-data/logs/app.log"
_syn_after s2b "$W0" "$W1"
_case_asserts "S2b" "0" "contrib-data/logs/app.log" "canary-marker"

# =============================================================================
t_case "S2c canary-marker 优先级：佐证齐备 ∧ 新增含 S4-P1- 行 ⇒ 仍判 suite（先于佐证判定）"
_syn_before s2c
S2CT="$("$PIN_DATE" +%s)"
printf 'S4-P1-CANARY-MARKER on-corroborated-path\n' >> "$SYN_ROOT/contrib-data/state.json"
printf '[%s] app: corroborating-tick\n' "$("$PIN_DATE" -r "$S2CT" '+%Y-%m-%d %H:%M:%S')" >> "$SYN_ROOT/contrib-data/logs/app.log"
_syn_after s2c "$((S2CT - 300))" "$S2CT"
_case_asserts "S2c" "0" \
  "contrib-data/state.json" "canary-marker" \
  "contrib-data/logs/app.log" "registered-append-ok"

# =============================================================================
t_case "S3 not-append-only：截断重写 → suite"
_syn_before s3
printf '[%s] app: rewritten\n' "$("$PIN_DATE" -r "$W1" '+%Y-%m-%d %H:%M:%S')" > "$SYN_ROOT/contrib-data/logs/app.log"
_syn_after s3 "$W0" "$W1"
_case_asserts "S3" "0" "contrib-data/logs/app.log" "not-append-only"

# =============================================================================
t_case "S4 inode-changed：mv 替换（内容为前缀追加，仅 inode 变）→ suite"
_syn_before s4
cp "$SYN_ROOT/contrib-data/logs/app.log" "$WA_SB/s4.repl"
printf '[%s] app: appended\n' "$("$PIN_DATE" -r "$W1" '+%Y-%m-%d %H:%M:%S')" >> "$WA_SB/s4.repl"
mv "$WA_SB/s4.repl" "$SYN_ROOT/contrib-data/logs/app.log"
_syn_after s4 "$W0" "$W1"
_case_asserts "S4" "0" "contrib-data/logs/app.log" "inode-changed"

# =============================================================================
t_case "S5 empty-append：touch（内容不变，仅 mtime 变）→ suite"
_syn_before s5
sleep 1
touch "$SYN_ROOT/contrib-data/logs/app.log"
_syn_after s5 "$W0" "$W1"
_case_asserts "S5" "0" "contrib-data/logs/app.log" "empty-append"

# =============================================================================
t_case "S6 时间戳边界正例：ts == window_end + 120s → external"
_syn_before s6
B1="$("$PIN_DATE" +%s)"
printf '[%s] app: edge-plus-120\n' "$("$PIN_DATE" -r "$((B1 + 120))" '+%Y-%m-%d %H:%M:%S')" >> "$SYN_ROOT/contrib-data/logs/app.log"
_syn_after s6 "$((B1 - 300))" "$B1"
_case_asserts "S6" "0" "contrib-data/logs/app.log" "registered-append-ok"

# =============================================================================
t_case "S7 时间戳边界反例：ts == window_end + 121s → suite(timestamp-out-of-window)"
_syn_before s7
B2="$("$PIN_DATE" +%s)"
printf '[%s] app: edge-plus-121\n' "$("$PIN_DATE" -r "$((B2 + 121))" '+%Y-%m-%d %H:%M:%S')" >> "$SYN_ROOT/contrib-data/logs/app.log"
_syn_after s7 "$((B2 - 300))" "$B2"
_case_asserts "S7" "0" "contrib-data/logs/app.log" "timestamp-out-of-window"

# =============================================================================
t_case "S8 no-corroboration：corroborated-rewrite 改写但佐证日志无在窗记录 → suite"
_syn_before s8
printf '{"state":"changed-without-corroboration"}\n' > "$SYN_ROOT/contrib-data/state.json"
_syn_after s8 "$W0" "$W1"
_case_asserts "S8" "0" "contrib-data/state.json" "no-corroboration"

# =============================================================================
t_case "S8b no-corroboration（时序近邻）：佐证在窗但 |佐证 ts − 变更文件 mtime| > 30s → suite"
_syn_before s8b
S8T="$("$PIN_DATE" +%s)"
printf '{"state":"late-corroboration"}\n' > "$SYN_ROOT/contrib-data/state.json"
printf '[%s] app: corroborating-late\n' "$("$PIN_DATE" -r "$S8T" '+%Y-%m-%d %H:%M:%S')" >> "$SYN_ROOT/contrib-data/logs/app.log"
touch -t "$("$PIN_DATE" -r "$((S8T - 120))" '+%Y%m%d%H%M.%S')" "$SYN_ROOT/contrib-data/state.json"
_syn_after s8b "$((S8T - 300))" "$S8T"
_case_asserts "S8b" "0" "contrib-data/state.json" "no-corroboration"
assert_ne "$(awk '/WA-CLASS /{ if (index($0,"Δt=") > 0) c++ } END{print c+0}' "$R_OUT")" "0" \
  "S8b 佐证判定的 evidence 行带 Δt=<n>s（第 2 轮口径「evidence 行带 Δt」；见 CONTRACT_AMBIGUOUS ⑤）"

# =============================================================================
t_case "S9 created-unallowed/no-corroboration：判据面新建（glob 模式 + 精确路径）→ suite"
_syn_before s9
printf 'marker\n' > "$SYN_ROOT/contrib-data/newdir/marker.txt"
printf '{"fresh":true}\n' > "$SYN_ROOT/contrib-data/newfile.json"
_syn_after s9 "$W0" "$W1"
_case_asserts "S9" "0" \
  "contrib-data/newdir/marker.txt" "created-unallowed|no-corroboration" \
  "contrib-data/newfile.json" "created-unallowed|no-corroboration"

# =============================================================================
t_case "S10 corroborated-ok：改写 + 佐证日志在窗记录 + Δt ≤ 30s → external"
_syn_before s10
S10T="$("$PIN_DATE" +%s)"
printf '{"state":"changed-with-corroboration"}\n' > "$SYN_ROOT/contrib-data/state.json"
printf '[%s] app: corroborating-tick\n' "$("$PIN_DATE" -r "$S10T" '+%Y-%m-%d %H:%M:%S')" >> "$SYN_ROOT/contrib-data/logs/app.log"
_syn_after s10 "$((S10T - 300))" "$S10T"
_case_asserts "S10" "0" \
  "contrib-data/state.json" "corroborated-ok" \
  "contrib-data/logs/app.log" "registered-append-ok"
assert_ne "$(awk '/WA-CLASS /{ if (index($0,"Δt=") > 0) c++ } END{print c+0}' "$R_OUT")" "0" \
  "S10 佐证判定的 evidence 行带 Δt=<n>s"

# =============================================================================
t_case "S11 outside-surface：面外路径变更落证据行、不判失败、不静默丢弃"
_syn_before s11
printf 'draft-more\n' >> "$SYN_ROOT/contrib-data/scratch/draft.md"
_syn_after s11 "$W0" "$W1"
_case_asserts "S11" "0" "contrib-data/scratch/draft.md" "outside-surface"
assert_eq "$(_wa_sum "$R_SO" suite)" "0" "S11 面外变更不得计入 suite（不判失败）"
assert_eq "$(_wa_sum "$R_SO" outside)" "1" "S11 面外变更计入 outside 计数"

# =============================================================================
t_case "S12 零变更：total=0 ∧ diff_lines=0 ∧ rc=0 ∧ 零 per-file 行"
_syn_before s12
_syn_after s12 "$W0" "$W1"
assert_eq "$R_RC" "0" "S12 零变更 rc=0"
assert_eq "$(_wa_sum "$R_SO" total)" "0" "S12 total=0"
assert_eq "$(_wa_sum "$R_SO" diff_lines)" "0" "S12 diff_lines=0"
assert_eq "$(_wa_sum "$R_SO" external)" "0" "S12 external=0"
assert_eq "$(_wa_sum "$R_SO" suite)" "0" "S12 suite=0"
assert_eq "$(_wa_sum "$R_SO" unclassified)" "0" "S12 unclassified=0"
assert_eq "$(_class_line_count "$R_OUT")" "0" "S12 零变更无 per-file 分类行"
assert_eq "$(_identity_report "$R_SO" "$R_OUT")" "" "S12 零变更账目恒等式"

# =============================================================================
t_case "S13 fail-closed：清单缺失/空/NF≠5/无捕获组/mode 非法/佐证 :none/删除行 DbC/快照缺失/窗口非整数 → exit 2"
_syn_before s13
_syn_after s13 "$W0" "$W1"
S13_SO="$R_SO"; S13_OUT="$R_OUT"

: > "$WA_SB/reg.empty.tsv"
printf 'contrib-data/logs/app.log\tapp\tappend-records\t%s\n' "$ALPHA_APP" > "$WA_SB/reg.nf4.tsv"
printf 'contrib-data/logs/app.log\tapp\tappend-records\t^OK$\t:none\n' > "$WA_SB/reg.nogroup.tsv"
printf 'contrib-data/logs/app.log\tapp\tfrobnicate\t%s\t:none\n' "$ALPHA_APP" > "$WA_SB/reg.badmode.tsv"
printf 'contrib-data/state.json\tappstate\tcorroborated-rewrite\t%s\t:none\n' "$ALPHA_APP" > "$WA_SB/reg.conone.tsv"

_fc_case() { # <tag> <expected-rc> <before-snap> <registry> <t0> <t1>
  local tag="$1" want="$2" bs="$3" reg="$4" t0="$5" t1="$6" rc so out
  so="$WA_SB/$tag.classify.out"
  out="$WA_SB/$tag.wa-class"
  _wa_call wa_classify "$SYN_ROOT" "$bs" "$SNAP_A" "$reg" "$out" "$t0" "$t1" > "$so" 2>&1
  rc=$?
  assert_eq "$rc" "$want" "${tag} fail-closed rc 期望 ${want}；禁静默绿"
}

_fc_case "S13a 清单缺失" "2" "$SNAP_B" "$WA_SB/no-such-registry.tsv" "$W0" "$W1"
_fc_case "S13b 清单空" "2" "$SNAP_B" "$WA_SB/reg.empty.tsv" "$W0" "$W1"
_fc_case "S13c NF≠5" "2" "$SNAP_B" "$WA_SB/reg.nf4.tsv" "$W0" "$W1"
_fc_case "S13d 无捕获组" "2" "$SNAP_B" "$WA_SB/reg.nogroup.tsv" "$W0" "$W1"
_fc_case "S13e mode 非法" "2" "$SNAP_B" "$WA_SB/reg.badmode.tsv" "$W0" "$W1"
_fc_case "S13f corroborated 佐证 :none" "2" "$SNAP_B" "$WA_SB/reg.conone.tsv" "$W0" "$W1"
_fc_case "S13g 快照缺失" "2" "$WA_SB/no-such-snapshot.snap" "$SYN_REG" "$W0" "$W1"
_fc_case "S13h 窗口非整数" "2" "$SNAP_B" "$SYN_REG" "abc" "$W1"
# S13i/S13j（S-08 的删除面半边）：corroborated-delete 行 DbC —— 字段4 必须 :none、字段5 必须非 :none
printf '%s/*\tnotify\tcorroborated-delete\t^OK$\t%s\n' "$DEL_DIR" "$DEL_LOG" > "$WA_SB/reg.delalpha.tsv"
printf '%s/*\tnotify\tcorroborated-delete\t:none\t:none\n' "$DEL_DIR" > "$WA_SB/reg.delnocorr.tsv"
_fc_case "S13i 删除行字母表非 :none" "2" "$SNAP_B" "$WA_SB/reg.delalpha.tsv" "$W0" "$W1"
_fc_case "S13j 删除行佐证 :none" "2" "$SNAP_B" "$WA_SB/reg.delnocorr.tsv" "$W0" "$W1"
assert_eq "$(_identity_report "$S13_SO" "$S13_OUT")" "" "S13 对照：同输入 + 合法清单 rc=0 且恒等式成立（防「恒 exit 2」假通过）"

# =============================================================================
t_case "S15 删除类正例：真 rm + 真在窗佐证记录 ⇒ external/corroborated-delete-ok（S-01 回归锚三件 + 第二 <TS> 轮）"
# 轮 A：worker 生产实测同形三件（digest-20260914-090949.{json,body.md,card.json}），构造偏移 9s（镜像生产 10:04:43/10:04:34）
_del_before s15a
_del_pos s15a 9 "$DEL_P_A" "$DEL_P_A_BODY" "$DEL_P_A_CARD"
S15A_ANCHOR="$DEL_ANCHOR"; S15A_TS="$DEL_TSSTR"
_case_asserts "S15a" "0" \
  "$DEL_P_A" "corroborated-delete-ok" \
  "$DEL_P_A_BODY" "corroborated-delete-ok" \
  "$DEL_P_A_CARD" "corroborated-delete-ok" \
  "$DEL_LOG" "registered-append-ok"
assert_eq "$(_wa_sum "$R_SO" suite)" "0" "S15a 删除类正例 suite=0（生产实测同形三件必须全归 external；禁假红）"
assert_eq "$(_wa_sum "$R_SO" external)" "4" "S15a external=4（三件删除 + 写手日志自身追加；S-09 既有 append 语义不回归）"
assert_eq "$(_wa_sum "$R_SO" outside)" "0" "S15a outside=0"
_del_ev_asserts "S15a" "$DEL_P_A" "$S15A_ANCHOR" "$S15A_TS" "9"
_del_ev_asserts "S15a" "$DEL_P_A_BODY" "$S15A_ANCHOR" "$S15A_TS" "9"
_del_ev_asserts "S15a" "$DEL_P_A_CARD" "$S15A_ANCHOR" "$S15A_TS" "9"

# 轮 B（S-01 反空转）：第二个 <TS> + 不同构造偏移 ⇒ 同判 external（杀写死文件名/写死时间戳/常量 Δt）
_del_before s15b "$DEL_P_B"
_del_pos s15b 5 "$DEL_P_B"
S15B_ANCHOR="$DEL_ANCHOR"; S15B_TS="$DEL_TSSTR"
_case_asserts "S15b" "0" "$DEL_P_B" "corroborated-delete-ok"
assert_eq "$(_wa_sum "$R_SO" suite)" "0" "S15b suite=0（第二 <TS> 轮）"
assert_eq "$(_wa_sum "$R_SO" external)" "2" "S15b external=2（删除 1 + 日志追加 1）"
_del_ev_asserts "S15b" "$DEL_P_B" "$S15B_ANCHOR" "$S15B_TS" "5"

# 轮 C（E-1 形态）：同一路径模式两行并存且 create 行在前 ⇒ D 仍必须走 corroborated-delete 行（禁首匹配即返回）
DEL_REG="$SYN_DEL_MULTI_REG"
_del_before s15c
_del_pos s15c 9 "$DEL_P_A"
S15C_ANCHOR="$DEL_ANCHOR"; S15C_TS="$DEL_TSSTR"
DEL_REG=""
_case_asserts "S15c" "0" "$DEL_P_A" "corroborated-delete-ok"
assert_eq "$(_wa_sum "$R_SO" suite)" "0" "S15c 双行 registry（create 行在前）删除仍归 external（E-1：D 只认 corroborated-delete 行）"
_del_ev_asserts "S15c" "$DEL_P_A" "$S15C_ANCHOR" "$S15C_TS" "9"

# =============================================================================
t_case "S16 删除类无佐证：锚可取但无在窗记录 ⇒ suite/no-delete-corroboration；边界 |Δ|=30s⇒external / 31s⇒suite"
# S16a：锚存在、佐证记录缺席（写手日志仅窗口外 seed）⇒ 保守判红；证据行仍须带 dir_mtime（S-07：锚有值、佐证缺席）
_del_before s16a
_del_rm_paths "$DEL_P_A"
_del_anchor_now "$DEL_DIR"
S16A_ANCHOR="$DEL_ANCHOR"
_syn_after s16a "$((S16A_ANCHOR - 300))" "$S16A_ANCHOR" "$SYN_DEL_REG"
_case_asserts "S16a" "0" "$DEL_P_A" "no-delete-corroboration"
assert_eq "$(_wa_sum "$R_SO" suite)" "1" "S16a suite=1（无在窗佐证 ⇒ 不放行）"
assert_eq "$(_wa_sum "$R_SO" external)" "0" "S16a external=0（不得因路径命中托管面就放行）"
S16A_LINE="$(_line_for_path "$R_OUT" "$DEL_P_A")"
assert_ne "$(_ev_dirmtime "$S16A_LINE")" "" "S16a 失败路径仍带 dir_mtime（S-07：锚有值、佐证缺席）"
assert_eq "$(_ev_dirmtime "$S16A_LINE")" "$S16A_ANCHOR" "S16a 失败路径 dir_mtime == 实测锚"

# S16b/S16c：同路径同操作，仅佐证时刻不同（|Δ|=30 ⇒ external；|Δ|=31 ⇒ suite；S-03 边界含端点）
_del_before s16b
_del_pos s16b 30 "$DEL_P_A"
S16B_ANCHOR="$DEL_ANCHOR"; S16B_TS="$DEL_TSSTR"
_case_asserts "S16b" "0" "$DEL_P_A" "corroborated-delete-ok"
assert_eq "$(_wa_sum "$R_SO" suite)" "0" "S16b |Δ|=30s ⇒ external ∧ suite=0（含边界）"
_del_ev_asserts "S16b" "$DEL_P_A" "$S16B_ANCHOR" "$S16B_TS" "30"

_del_before s16c
_del_pos s16c 31 "$DEL_P_A"
S16C_ANCHOR="$DEL_ANCHOR"
_case_asserts "S16c" "0" "$DEL_P_A" "no-delete-corroboration"
# S-03 谓词 = 「suite==1 ∧ **该 path** 非 external」（该 path 的定性由上一行 _case_asserts 钉死）。
# 本合成面必然另有**恰 1 条** external = 测试自身为构造佐证而写入的 notify.log 追加（registered-append-ok）
# ⇒ 按**归属**收窄：全局 external 恰 1 且该行归属佐证日志，而非被删路径。
# （原「external==0」把构造副作用当判据，与预注册谓词不符；见 QA 报告 S16c/S16e 根因取证。）
assert_eq "$(_wa_sum "$R_SO" external)" "1" "S16c 全局 external=1（唯一一条 = 构造佐证用的 notify.log 追加）"
assert_contains "$(grep -m1 '^WA-CLASS external ' "$R_OUT")" "path=$DEL_LOG" "S16c 该 external 行归属 = 佐证日志（非被删路径）"
assert_eq "$(_wa_sum "$R_SO" suite)" "1" "S16c |Δ|=31s ⇒ suite=1"
assert_eq "$(_ev_dirmtime "$(_line_for_path "$R_OUT" "$DEL_P_A")")" "$S16C_ANCHOR" \
  "S16c 失败路径 dir_mtime == 实测锚（锚仍在，仅近邻不成立）"

# S16d/S16e：|·| 对侧（记录 ts 落在锚之后 +30s/+31s，仍在窗口松弛 ±120s 内）——同一 |Δ| 判据的对称性
_del_before s16d
_del_pos s16d -30 "$DEL_P_A"
S16D_ANCHOR="$DEL_ANCHOR"; S16D_TS="$DEL_TSSTR"
_case_asserts "S16d" "0" "$DEL_P_A" "corroborated-delete-ok"
assert_eq "$(_wa_sum "$R_SO" suite)" "0" "S16d |Δ|=30s（记录在锚之后）⇒ external"
_del_ev_asserts "S16d" "$DEL_P_A" "$S16D_ANCHOR" "$S16D_TS" "30"

_del_before s16e
_del_pos s16e -31 "$DEL_P_A"
S16E_ANCHOR="$DEL_ANCHOR"
_case_asserts "S16e" "0" "$DEL_P_A" "no-delete-corroboration"
# 同 S16c：S-03 谓词只要求「该 path 非 external」（上一行 _case_asserts 已钉死），
# 构造佐证所写的 notify.log 追加恒贡献恰 1 条 external ⇒ 按归属收窄断言。
assert_eq "$(_wa_sum "$R_SO" external)" "1" "S16e 全局 external=1（唯一一条 = 构造佐证用的 notify.log 追加）"
assert_contains "$(grep -m1 '^WA-CLASS external ' "$R_OUT")" "path=$DEL_LOG" "S16e 该 external 行归属 = 佐证日志（非被删路径）"
assert_eq "$(_wa_sum "$R_SO" suite)" "1" "S16e |Δ|=31s（记录在锚之后）⇒ suite=1"
assert_eq "$(_ev_dirmtime "$(_line_for_path "$R_OUT" "$DEL_P_A")")" "$S16E_ANCHOR" \
  "S16e 失败路径 dir_mtime == 实测锚（对侧轮同样成立）"

# =============================================================================
t_case "S17 面外删除（无 marker）：未登记路径被删 ⇒ outside-surface（不冒领 external、不误计 suite）"
_del_before s17
_del_rm_paths "$DEL_OUT"
_del_anchor_now contrib-data/scratch
_syn_after s17 "$((DEL_ANCHOR - 300))" "$DEL_ANCHOR" "$SYN_DEL_REG"
_case_asserts "S17" "0" "$DEL_OUT" "outside-surface"
assert_eq "$(_wa_sum "$R_SO" suite)" "0" "S17 面外删除不计 suite（不误判套件写入）"
assert_eq "$(_wa_sum "$R_SO" external)" "0" "S17 面外删除不冒领 external（S-06/S-11 核心）"
assert_eq "$(_wa_sum "$R_SO" outside)" "1" "S17 面外删除落 outside 证据行（不静默丢弃）"
assert_eq "$(_wa_sum "$R_SO" total)" "1" "S17 窗口差集 = 1（仅该删除）"

# =============================================================================
t_case "S18 面外删除（有 marker）：未登记路径 basename 带 S4-P1- 前缀被删 ⇒ suite/canary-marker（R-1 面外也判红）"
_del_before s18 "$DEL_MARK_PROBE"
_del_rm_paths "$DEL_MARK_PROBE"
_del_anchor_now contrib-data/scratch
_syn_after s18 "$((DEL_ANCHOR - 300))" "$DEL_ANCHOR" "$SYN_DEL_REG"
_case_asserts "S18" "0" "$DEL_MARK_PROBE" "canary-marker"
assert_eq "$(_wa_sum "$R_SO" suite)" "1" "S18 面外 marker 路径删除判 suite=1（面外不豁免）"
assert_eq "$(_wa_sum "$R_SO" outside)" "0" "S18 marker 路径短路先于面外判定（不计 outside）"
assert_eq "$(_wa_sum "$R_SO" external)" "0" "S18 不得 external（路径自证面优先）"

# =============================================================================
t_case "S19 混合窗口等值恒等式：4 external + 1 suite + 1 outside ⇒ 三类计数与窗口差集等值对账"
_del_before s19
_del_rm_paths "$DEL_P_A" "$DEL_P_A_BODY" "$DEL_P_A_CARD"          # ① 写手删三件（corroborated-delete）
printf 'S4-P1-suite-write-probe\n' > "$SYN_ROOT/$DEL_SUITE_PROBE"  # ③ 套件在判据面内写入（marker 内容）
_del_anchor_now "$DEL_DIR"
S19_ANCHOR="$DEL_ANCHOR"
S19_TS="$("$PIN_DATE" -r "$((S19_ANCHOR - 9))" '+%Y-%m-%d %H:%M:%S')"
_del_record "$S19_TS" 3                                            # ② 写手日志追加（同时构成三件删除的佐证）
printf 'draft-more\n' >> "$SYN_ROOT/$DEL_OUT"                      # ④ 面外路径被改
_syn_after s19 "$((S19_ANCHOR - 300))" "$S19_ANCHOR" "$SYN_DEL_REG"
S19_EXT="$(_wa_sum "$R_SO" external)"; S19_SUI="$(_wa_sum "$R_SO" suite)"
S19_OUT="$(_wa_sum "$R_SO" outside)"; S19_TOT="$(_wa_sum "$R_SO" total)"
S19_UNC="$(_wa_sum "$R_SO" unclassified)"; S19_DIFF="$(_diffset_n "$SNAP_B" "$SNAP_A")"
assert_eq "$R_RC" "0" "S19 rc=0（混合窗口仍成功归类）"
assert_eq "$S19_DIFF" "6" "S19 独立口径窗口差集文件数 = 6（3 删除 + 1 新建 + 1 日志改写 + 1 面外改写）"
assert_eq "$S19_EXT" "4" "S19 external==4（等值断言；3 删除 + 1 写手日志追加）"
assert_eq "$S19_SUI" "1" "S19 suite==1（等值断言；不因删除而漂移）"
assert_eq "$S19_OUT" "1" "S19 outside==1（等值断言）"
assert_eq "$((S19_EXT + S19_SUI + S19_OUT))" "$S19_TOT" "S19 三类和 == total（V2 检测器：删除不得走旁路）"
assert_eq "$S19_TOT" "$S19_DIFF" "S19 total == 窗口差集文件数（独立口径实得 ${S19_DIFF}，非 >=）"
assert_eq "$S19_UNC" "0" "S19 unclassified==0"
assert_eq "$(_identity_report "$R_SO" "$R_OUT")" "" "S19 账目恒等式 total==external+suite+outside ∧ unclassified==0"
assert_eq "$(_expect_report "$R_OUT" "$DEL_P_A" "corroborated-delete-ok")" "" "S19 三件删除①全归 corroborated-delete-ok"
assert_eq "$(_expect_report "$R_OUT" "$DEL_P_A_BODY" "corroborated-delete-ok")" "" "S19 三件删除②全归 corroborated-delete-ok"
assert_eq "$(_expect_report "$R_OUT" "$DEL_P_A_CARD" "corroborated-delete-ok")" "" "S19 三件删除③全归 corroborated-delete-ok"
assert_eq "$(_expect_report "$R_OUT" "$DEL_LOG" "registered-append-ok")" "" "S19 写手日志追加归 registered-append-ok"
assert_eq "$(_expect_report "$R_OUT" "$DEL_OUT" "outside-surface")" "" "S19 面外改写归 outside-surface"
assert_eq "$(_expect_report "$R_OUT" "$DEL_SUITE_PROBE" "canary-marker|created-unallowed|no-corroboration")" "" \
  "S19 套件面内写入归 suite（reason ∈ suite 闭集；见 CONTRACT_AMBIGUOUS 10)）"


# =============================================================================
# R4 面（D-α 跨窗所有权链）合成树
#   依据：state.md `## R4 修复规格`「修法 D-α」/「契约规约（增量部分）」/「验收谓词 S-15、S-16」。
#   与 R3 删除面（DEL_*）互不复用：R3 的放行依据 = 父目录锚 ±30s 近邻（D-β）；R4 在其后**追加**一条：
#     **窗口前字节区**的具名所有权记录（D-α）∧ 本窗写手活跃。两条判据正交，须独立构造、独立取证。
#   生产形态镜像（R4 规格「缺陷事实」，窗口 11:07:34–11:09:18，main=e329c07）：四件同 stem 由写手
#     **上一轮**建立（notify.log:1722 具名）⇒ 本窗内被写手自行消费清理（真 rm 四件）⇒ 写手本窗另有
#     活跃记录（11:08:39）；删除与最近记录相距 39s（> 30s）⇒ D-β 不成立 ⇒ 旧引擎兜 suite（每小时假红
#     一次，正是本卡要消灭的形态）。
#   构造纪律：
#     · 所有权记录写在 **before 快照之前** ⇒ 其起始字节偏移 < 该日志在 before 快照中的 size（窗口前字节区）
#     · 活跃记录写在 **before 快照之后**（后区），镜像生产「本窗在活动」
#     · 锚 = 真 rm 产生的 pending 目录 mtime（与 R3 面同纪律：不 touch -t 伪造锚）
#     · 反空转：四件必须在 before 快照中（否则「以为测了其实没测」）；两个不同 <TS> 两轮
# =============================================================================
R4_DIR="contrib-data/pending"
R4_LOG="contrib-data/logs/notify.log"
R4_TS_A="20260914-100442"          # worker 生产实测四件的 <TS>（R4 缺陷窗口）
R4_TS_B="20260914-110839"          # 第二个 <TS>（S-15 反空转：杀写死文件名/时间戳/常量）
R4_STEM_A="digest-$R4_TS_A"
R4_STEM_B="digest-$R4_TS_B"
R4_DECOY="$R4_DIR/digest-20260914-000000.json"   # 常驻未变更物（目录非空 + 阴性对照：无变更 ⇒ 无行）
R4_OWN_LAG=3600                    # 所有权记录时刻 = 锚 − 1h（远离近邻带 ⇒ 逐轮稳健，不随运行时刻漂移）
R4_REG="$WA_SB/registry-r4.tsv"
{
  printf '%s\tnotify\tappend-records\t%s\t:none\n' "$R4_LOG" "$ALPHA_NOTIFY"
  printf '%s/*\tnotify\tcorroborated-create\t:none\t%s\n' "$R4_DIR" "$R4_LOG"
  printf '%s/*\tnotify\tcorroborated-delete\t:none\t%s\n' "$R4_DIR" "$R4_LOG"
} > "$R4_REG"

# —— 独立口径助手（不读实现、不复用引擎内部）—————
_snap_size() { # <snapshot> <relpath> → 第 2 列 size（按第 5 列精确等值；无该行 ⇒ 空）
  awk -v p="$2" '$5 == p { print $2; exit }' "$1"
}
_log_first_off() { # <logfile> <needle> → 首个含 needle 行的**起始字节偏移**（无 ⇒ 空；LC_ALL=C 保字节语义）
  LC_ALL=C awk -v n="$2" '
    BEGIN { off = 0 }
    { if (!found && index($0, n) > 0) { print off; found = 1 } }
    { off += length($0) + 1 }' "$1"
}
_to_epoch() { # <"YYYY-MM-DD HH:MM:SS"> → epoch（解析失败 ⇒ 空）
  "$PIN_DATE" -j -f '%Y-%m-%d %H:%M:%S' "$1" '+%s' 2>/dev/null
}
_ev_class() { # <WA-CLASS 行> → class 列（第 2 列）
  printf '%s\n' "$1" | awk '/^WA-CLASS /{ print $2; exit }'
}
_ev_field() { # <线> <key> → 该 k=v 字段值（值可含空格；以「下一个已知 k=」为界；无 ⇒ 空）
  printf '%s\n' "$1" | awk -v k="$2" '
    BEGIN { nk = split("writer bytes_added records Δt ts owner owner_ts owner_log act_ts act dir_mtime marker reason path", K, " ") }
    {
      cur = ""; val = ""
      for (i = 1; i <= NF; i++) {
        t = $i; isk = 0; kk = ""
        p = index(t, "=")
        if (p > 1) {
          cand = substr(t, 1, p - 1)
          for (j = 1; j <= nk; j++) { if (K[j] == cand) { isk = 1; kk = cand } }
        }
        if (isk) {
          if (cur == k) { print val; exit }
          cur = kk; val = substr(t, p + 1)
        } else if (cur == k) {
          val = val " " t
        }
      }
      if (cur == k) { print val; exit }
    }'
}

_r4_before() { # <tag> <stem> [plant-relpath...] → R4 合成根（四件 + 窗口前具名所有权记录）+ before 快照
  local tag="$1" stem="$2" rc p own_ep
  shift 2
  SYN_ROOT="$WA_SB/syn.$tag"
  mkdir -p "$SYN_ROOT/$R4_DIR" "$SYN_ROOT/contrib-data/logs" "$SYN_ROOT/contrib-data/scratch"
  # ① 窗口前字节区：写手「上一轮」建该 stem 的**具名**记录（行文本含 stem；ts 唯一，供反查与字节区断言）
  own_ep="$(( $("$PIN_DATE" +%s) - R4_OWN_LAG ))"
  R4_OWN_TS="$("$PIN_DATE" -r "$own_ep" '+%Y-%m-%d %H:%M:%S')"
  R4_OWN_TOUCH="$("$PIN_DATE" -r "$own_ep" '+%Y%m%d%H%M.%S')"
  printf '[%s] notify: digest 卡已建 t_shadow-r4（snapshot=%s/%s.json，idem=rq-shadow）\n' \
    "$R4_OWN_TS" "$R4_DIR" "$stem" > "$SYN_ROOT/$R4_LOG"
  printf '[%s] notify: 批次具名 %s 四件（k3）\n' "$R4_OWN_TS" "$stem" >> "$SYN_ROOT/$R4_LOG"
  # 窗口外 seed（阴性背景：既不在窗 ⇒ 不构成活跃，也不构成近邻）
  printf '[2026-01-01 00:00:00] notify: seed-out-of-window\n' >> "$SYN_ROOT/$R4_LOG"
  # ② 四件同 stem 真落盘（plant 先于 before 快照 ⇒ 窗口差集非空的前提）；mtime 对齐所有权记录（= 上一轮产物）
  printf '{"digest":"%s"}\n' "$stem" > "$SYN_ROOT/$R4_DIR/$stem.json"
  printf 'body\n' > "$SYN_ROOT/$R4_DIR/$stem.body.md"
  printf '{"card":1}\n' > "$SYN_ROOT/$R4_DIR/$stem.card.json"
  printf 'digest\n' > "$SYN_ROOT/$R4_DIR/$stem.digest.md"
  touch -t "$R4_OWN_TOUCH" "$SYN_ROOT/$R4_DIR/$stem.json" "$SYN_ROOT/$R4_DIR/$stem.body.md" \
    "$SYN_ROOT/$R4_DIR/$stem.card.json" "$SYN_ROOT/$R4_DIR/$stem.digest.md"
  printf '{"decoy":true}\n' > "$SYN_ROOT/$R4_DECOY"
  printf 'draft\n' > "$SYN_ROOT/contrib-data/scratch/draft.md"
  for p in "$@"; do
    mkdir -p "$SYN_ROOT/$(dirname "$p")"
    printf 'probe-planted\n' > "$SYN_ROOT/$p"
  done
  SNAP_B="$WA_SB/$tag.before.snap"
  SNAP_A="$WA_SB/$tag.after.snap"
  _wa_call wa_snapshot "$SYN_ROOT" "$SNAP_B" > "$WA_SB/$tag.snapb.out" 2>&1
  rc=$?
  [ "$rc" = "0" ] || _fail "前置 wa_snapshot(before) rc=0" "rc=$rc tag=${tag}（R4 合成树）"
  [ -s "$SNAP_B" ] || _fail "前置 快照非空" "tag=${tag}；快照为空 ${SNAP_B}"
  # 反空转前置：before 快照必须含四件（S-15「窗口差集非空」的机械前提）
  for p in "$R4_DIR/$stem.json" "$R4_DIR/$stem.body.md" "$R4_DIR/$stem.card.json" "$R4_DIR/$stem.digest.md"; do
    [ -n "$(_snap_size "$SNAP_B" "$p")" ] || _fail "前置 before 快照含 plant 物" "缺失 ${p}（窗口差集为空 ⇒ 用例空转）"
  done
}

_r4_rm() { # <relpath...> → 真 rm（kind=D 真成立；父目录 mtime 随之更新为删除瞬间 = 锚）
  local p
  for p in "$@"; do
    rm -f "$SYN_ROOT/$p"
    [ ! -e "$SYN_ROOT/$p" ] || _fail "前置 真 rm 生效" "path=${p} 仍存在（kind=D 与锚均不成立）"
  done
}
_r4_anchor_now() { # → R4_ANCHOR = 实测 pending 目录 mtime（真 rm 产生；非 touch -t 伪造）
  R4_ANCHOR="$("$PIN_STAT" -f %m "$SYN_ROOT/$R4_DIR")"
  case "$R4_ANCHOR" in
    ''|*[!0-9]*) _fail "前置 目录锚为十进制 epoch" "stat -f %m 实得 [${R4_ANCHOR}]" ;;
  esac
}
_r4_activity() { # <offset-s> → 本窗活跃记录（合规形态；写手本窗活跃的机械构造）
  R4_ACT_TS="$("$PIN_DATE" -r "$((R4_ANCHOR - $1))" '+%Y-%m-%d %H:%M:%S')"
  printf '[%s] notify: 轮次活跃（本窗 write-after）\n' "$R4_ACT_TS" >> "$SYN_ROOT/$R4_LOG"
}
_r4_classify() { # <tag> [registry] → after 快照 + classify（窗口 = [锚−300, 锚]）
  _syn_after "$1" "$((R4_ANCHOR - 300))" "$R4_ANCHOR" "${2:-$R4_REG}"
}

# 组合断言：D-α 证据行全字段反查（<tag> <stem> <anchor> <lo> <hi> <path>...）
_r4_ev_asserts() {
  local tag="$1" stem="$2" anchor="$3" lo="$4" hi="$5"
  shift 5
  local p line size off owner owner_ts owner_log act_ts actep dm pre inb
  size="$(_snap_size "$SNAP_B" "$R4_LOG")"   # 窗口前字节区上界（快照 size 列；独立口径，非引擎自报）
  for p in "$@"; do
    line="$(_line_for_path "$R_OUT" "$p")"
    assert_ne "$line" "" "${tag} 证据行存在 path=${p}"
    assert_eq "$(_ev_class "$line")" "external" "${tag} class==external path=${p}"
    assert_eq "$(_ev_field "$line" reason)" "ownership-delete-ok" \
      "${tag} reason==ownership-delete-ok path=${p}"
    owner="$(_ev_field "$line" owner)"
    assert_eq "$owner" "$stem" "${tag} owner= == 四件共同 stem path=${p} 实得 [${owner}]"
    owner_ts="$(_ev_field "$line" owner_ts)"
    assert_ne "$owner_ts" "" "${tag} owner_ts= 非空 path=${p}"
    off="$(_log_first_off "$SYN_ROOT/$R4_LOG" "$owner_ts")"
    assert_ne "$off" "" "${tag} owner_ts= 在写手日志中真实存在（S-02 反查）path=${p} ts=[${owner_ts}]"
    if [ -n "$off" ] && [ -n "$size" ] && [ "$off" -lt "$size" ]; then pre=1; else pre=0; fi
    assert_eq "$pre" "1" "${tag} 所有权记录位于窗口前字节区 path=${p} 偏移=${off} before_size=${size}"
    owner_log="$(_ev_field "$line" owner_log)"
    assert_eq "$owner_log" "$R4_LOG" "${tag} owner_log= == 佐证日志 path=${p} 实得 [${owner_log}]"
    act_ts="$(_ev_field "$line" act_ts)"
    actep="$(_to_epoch "$act_ts")"
    if [ -n "$actep" ] && [ -n "$lo" ] && [ -n "$hi" ] && [ "$actep" -ge "$lo" ] && [ "$actep" -le "$hi" ]; then inb=1; else inb=0; fi
    assert_eq "$inb" "1" "${tag} act_ts= 落在窗口松弛带 path=${p} lo=${lo} hi=${hi} 实得 [${act_ts}]"
    dm="$(_ev_dirmtime "$line")"
    case "$dm" in
      ''|*[!0-9]*) assert_eq "nondecimal" "decimal" "${tag} dir_mtime= 十进制 path=${p} 实得 [${dm}]" ;;
      *) assert_eq "$dm" "$anchor" "${tag} dir_mtime == 实测目录锚 path=${p} 期望 ${anchor}" ;;
    esac
  done
}

# =============================================================================
t_case "T14 reason 闭集表自证：新令牌 ownership-delete-ok 归 external 侧 ∧ class↔reason 失配仍被检出"
printf 'WA total=1 external=1 suite=0 outside=0 unclassified=0 diff_lines=2\n' > "$WA_SB/t14.ok.sum"
printf 'WA-CLASS external path=contrib-data/pending/digest-20260914-100442.json reason=ownership-delete-ok writer=notify Δt=9s ts=2026-09-14 11:08:39 dir_mtime=1789355358 owner=digest-20260914-100442 owner_ts=2026-09-14 10:04:43 owner_log=contrib-data/logs/notify.log act_ts=2026-09-14 11:08:39\n' > "$WA_SB/t14.ok.cls"
assert_eq "$(_identity_report "$WA_SB/t14.ok.sum" "$WA_SB/t14.ok.cls")" "" \
  "T14 新令牌被闭集表接纳为 external 侧（表未同步更新 ⇒ 本断言转红）"
printf 'WA total=1 external=0 suite=1 outside=0 unclassified=0 diff_lines=2\n' > "$WA_SB/t14.bad.sum"
printf 'WA-CLASS suite path=contrib-data/pending/digest-20260914-100442.json reason=ownership-delete-ok writer=notify dir_mtime=1789355358\n' > "$WA_SB/t14.bad.cls"
T14_BAD="$(_identity_report "$WA_SB/t14.bad.sum" "$WA_SB/t14.bad.cls")"
assert_ne "$T14_BAD" "" "T14 class↔reason 失配（suite 侧出现 external 令牌）必须被检出"
assert_contains "$T14_BAD" "class/reason 失配" "T14 违规类别 = class/reason 失配（非其它）"
printf 'WA total=1 external=1 suite=0 outside=0 unclassified=0 diff_lines=2\n' > "$WA_SB/t14.unk.sum"
printf 'WA-CLASS external path=contrib-data/pending/x.json reason=ownership-delete-okX writer=notify\n' > "$WA_SB/t14.unk.cls"
assert_ne "$(_identity_report "$WA_SB/t14.unk.sum" "$WA_SB/t14.unk.cls")" "" \
  "T14 拼写变体令牌必须被检出（闭集不接受近似令牌）"

# =============================================================================
t_case "T15 跨窗所有权链（D-α / S-15）：写手删其上一轮所建、日志具名、无近邻在窗记录 ⇒ external/ownership-delete-ok"
# 轮 A：worker 生产实测同形四件（digest-20260914-100442.{json,body.md,card.json,digest.md}）
#       活跃记录距锚 60s（> 30 ⇒ D-β 必不成立）⇒ 放行只能来自 D-α
_r4_before t15a "$R4_STEM_A"
_r4_rm "$R4_DIR/$R4_STEM_A.json" "$R4_DIR/$R4_STEM_A.body.md" "$R4_DIR/$R4_STEM_A.card.json" "$R4_DIR/$R4_STEM_A.digest.md"
_r4_anchor_now
T15A_ANCHOR="$R4_ANCHOR"
_r4_activity 60
T15A_ACT="$R4_ACT_TS"
_r4_classify t15a
_case_asserts "T15a" "0" \
  "$R4_DIR/$R4_STEM_A.json" "ownership-delete-ok" \
  "$R4_DIR/$R4_STEM_A.body.md" "ownership-delete-ok" \
  "$R4_DIR/$R4_STEM_A.card.json" "ownership-delete-ok" \
  "$R4_DIR/$R4_STEM_A.digest.md" "ownership-delete-ok" \
  "$R4_LOG" "registered-append-ok"
assert_eq "$(_wa_sum "$R_SO" suite)" "0" "T15a suite==0（R4 生产形态必须全归 external；每小时假红即此断言转红）"
assert_eq "$(_wa_sum "$R_SO" external)" "5" "T15a external==5（四件删除 + 写手本窗日志追加）"
assert_eq "$(_wa_sum "$R_SO" outside)" "0" "T15a outside==0"
assert_eq "$(_wa_sum "$R_SO" unclassified)" "0" "T15a unclassified==0"
T15A_DIFF="$(_diffset_n "$SNAP_B" "$SNAP_A")"
assert_eq "$T15A_DIFF" "5" "T15a 独立口径窗口差集 == 5（四删 + 日志改写；反空转：窗口差集非空）"
assert_eq "$(_wa_sum "$R_SO" total)" "$T15A_DIFF" "T15a total == 窗口差集文件数（等值断言，非 >=）"
assert_eq "$(_to_epoch "$T15A_ACT")" "$((T15A_ANCHOR - 60))" \
  "T15a D-β 前提自证：活跃记录 ts 与锚相距恰 60s（> 30 ⇒ 近邻不成立，放行只能来自 D-α）"
_r4_ev_asserts "T15a" "$R4_STEM_A" "$T15A_ANCHOR" "$((T15A_ANCHOR - 420))" "$((T15A_ANCHOR + 120))" \
  "$R4_DIR/$R4_STEM_A.json" "$R4_DIR/$R4_STEM_A.body.md" "$R4_DIR/$R4_STEM_A.card.json" "$R4_DIR/$R4_STEM_A.digest.md"

# 轮 B（S-15 反空转）：第二个 <TS> + 不同活跃偏移（45s）⇒ 同判 external（杀写死文件名/时间戳/常量）
_r4_before t15b "$R4_STEM_B"
_r4_rm "$R4_DIR/$R4_STEM_B.json" "$R4_DIR/$R4_STEM_B.body.md" "$R4_DIR/$R4_STEM_B.card.json" "$R4_DIR/$R4_STEM_B.digest.md"
_r4_anchor_now
T15B_ANCHOR="$R4_ANCHOR"
_r4_activity 45
T15B_ACT="$R4_ACT_TS"
_r4_classify t15b
_case_asserts "T15b" "0" \
  "$R4_DIR/$R4_STEM_B.json" "ownership-delete-ok" \
  "$R4_DIR/$R4_STEM_B.body.md" "ownership-delete-ok" \
  "$R4_DIR/$R4_STEM_B.card.json" "ownership-delete-ok" \
  "$R4_DIR/$R4_STEM_B.digest.md" "ownership-delete-ok" \
  "$R4_LOG" "registered-append-ok"
assert_eq "$(_wa_sum "$R_SO" suite)" "0" "T15b suite==0（第二 <TS> 轮）"
assert_eq "$(_wa_sum "$R_SO" external)" "5" "T15b external==5（四件删除 + 写手本窗日志追加）"
T15B_DIFF="$(_diffset_n "$SNAP_B" "$SNAP_A")"
assert_eq "$T15B_DIFF" "5" "T15b 独立口径窗口差集 == 5（反空转：窗口差集非空）"
assert_eq "$(_wa_sum "$R_SO" total)" "$T15B_DIFF" "T15b total == 窗口差集文件数（等值断言）"
assert_eq "$(_to_epoch "$T15B_ACT")" "$((T15B_ANCHOR - 45))" \
  "T15b D-β 前提自证：活跃记录 ts 与锚相距恰 45s（> 30 ⇒ 近邻不成立）"
_r4_ev_asserts "T15b" "$R4_STEM_B" "$T15B_ANCHOR" "$((T15B_ANCHOR - 420))" "$((T15B_ANCHOR + 120))" \
  "$R4_DIR/$R4_STEM_B.json" "$R4_DIR/$R4_STEM_B.body.md" "$R4_DIR/$R4_STEM_B.card.json" "$R4_DIR/$R4_STEM_B.digest.md"

# =============================================================================
t_case "T16 套件躲进写手活动窗的机械区分（D-α 负对照三态 / S-16）：三态全部判 suite"
R4_NONCE="$( "$PIN_DATE" +%s )-$$"
R4_PROBE_M_STEM="S4-P1-del-$R4_NONCE"
R4_PROBE_M="$R4_DIR/$R4_PROBE_M_STEM.json"          # ① marker 探针（basename 以 S4-P1- 开头）
R4_PROBE_N_STEM="probe-del-$R4_NONCE"
R4_PROBE_N="$R4_DIR/$R4_PROBE_N_STEM.json"          # ②③ 无 marker 探针（stem 长度 ≥ 8 ⇒ 所有权规则适用）

# ① marker 探针：本窗植入 + 本窗真删 + 写手本窗活跃（活跃记录落在锚 ±30s **内** ⇒ 近邻本会成立）
#    ⇒ 判红只能来自 marker 路径短路「先于一切」（R-1）；任何「先判佐证」的排序都会让本态错误变绿
_r4_before t16a "$R4_STEM_A" "$R4_PROBE_M"
_r4_rm "$R4_PROBE_M"
_r4_anchor_now
T16A_ANCHOR="$R4_ANCHOR"
_r4_activity 9
T16A_ACT="$R4_ACT_TS"
_r4_classify t16a
T16A_LINE="$(_line_for_path "$R_OUT" "$R4_PROBE_M")"
_case_asserts "T16a" "0" "$R4_PROBE_M" "canary-marker" "$R4_LOG" "registered-append-ok"
assert_eq "$(_ev_class "$T16A_LINE")" "suite" "T16a marker 探针 class==suite（S-16①：路径自证面优先，非 external）"
assert_eq "$(_wa_sum "$R_SO" suite)" "1" "T16a suite==1（仅探针；近邻本会成立却被短路拦住 ⇒ 排序正确）"
assert_eq "$(_wa_sum "$R_SO" external)" "1" "T16a external==1（写手本窗追加仍归 external，未被 marker 短路吞并）"
assert_eq "$(_wa_sum "$R_SO" total)" "2" "T16a total==2（探针 + 日志改写）"
# 前提自证（防空转）：活跃记录距锚 9s（≤30s）⇒ D-β 近邻**本会成立**，故本态判红确由 marker 短路先占（排序正确性）
T16A_ACT_EP="$(_to_epoch "$T16A_ACT")"
assert_ne "$T16A_ACT_EP" "" "T16a 前置自证：活跃记录 ts 可解析（${T16A_ACT}）"
T16A_D="$(( T16A_ANCHOR - T16A_ACT_EP ))"
if [ "$T16A_D" -ge -30 ] && [ "$T16A_D" -le 30 ]; then
  _pass "T16a 前置自证：活跃记录落在锚 ±30s 内（Δ=${T16A_D}s）⇒ 近邻本会成立"
else
  _fail "T16a 前置自证：活跃记录落在锚 ±30s 内" "Δ=${T16A_D}s（构造失效）"
fi

# ② 无 marker 探针：本窗植入 + 本窗真删 + 写手本窗活跃（活跃记录距锚 60s > 30 ⇒ 近邻不成立）
#    + 日志中**无任何具名该物 stem 的记录** ⇒ 所有权不成立 ⇒ suite/no-delete-corroboration
_r4_before t16b "$R4_STEM_A" "$R4_PROBE_N"
_r4_rm "$R4_PROBE_N"
_r4_anchor_now
T16B_ANCHOR="$R4_ANCHOR"
_r4_activity 60
_r4_classify t16b
T16B_LINE="$(_line_for_path "$R_OUT" "$R4_PROBE_N")"
_case_asserts "T16b" "0" "$R4_PROBE_N" "no-delete-corroboration" "$R4_LOG" "registered-append-ok"
assert_eq "$(_ev_class "$T16B_LINE")" "suite" "T16b 无 marker 探针 class==suite（S-16②：写手活跃 ≠ 所有权）"
assert_eq "$(_wa_sum "$R_SO" suite)" "1" "T16b suite==1（活跃在窗但无具名所有权记录 ⇒ 不放行）"
assert_eq "$(_wa_sum "$R_SO" external)" "1" "T16b external==1（仅写手日志追加）"
assert_eq "$(_ev_dirmtime "$T16B_LINE")" "$T16B_ANCHOR" "T16b 失败行 dir_mtime == 实测锚（锚有值、依据缺席）"
assert_ne "$(_ev_field "$T16B_LINE" owner)" "" "T16b 失败行带 owner= 审计字段（R4 契约：字段只增）"
T16B_ACT="$(_ev_field "$T16B_LINE" act)"
assert_ne "$T16B_ACT" "" "T16b 失败行带 act= 审计字段（R4 契约：字段只增）"
assert_ne "$T16B_ACT" "none" "T16b 失败行 act= 为实际在窗时刻（活跃确已被观测）"

# ③a 本窗伪造具名所有权记录（回填窗口前**旧时间戳**）：记录写在 before 快照**之后** ⇒ 窗口后字节区
#     ⇒ 探针仍判 suite；且该追加自身被既有 append 分支判红（块内无在窗记录 ⇒ timestamp-out-of-window）
_r4_before t16c "$R4_STEM_A" "$R4_PROBE_N"
# 伪造 ts 取「所有权记录 ts − 60s」：仍远在窗口带外，且**与所有权记录 ts 不撞车**
# （撞车会让「窗口后字节区」的自证命中第 1 行的原记录 ⇒ 自证假通过 —— 0414 首跑即抓到该测试侧缺陷）
T16C_FAKE_TS="$("$PIN_DATE" -r "$(( $(_to_epoch "$R4_OWN_TS") - 60 ))" '+%Y-%m-%d %H:%M:%S')"
printf '[%s] notify: digest 卡已建 t_forge-c（snapshot=%s/%s，idem=rq-forge）\n' \
  "$T16C_FAKE_TS" "$R4_DIR" "$R4_PROBE_N" >> "$SYN_ROOT/$R4_LOG"
_r4_rm "$R4_PROBE_N"
_r4_anchor_now
T16C_ANCHOR="$R4_ANCHOR"
_r4_classify t16c
T16C_LINE="$(_line_for_path "$R_OUT" "$R4_PROBE_N")"
_case_asserts "T16c" "0" "$R4_PROBE_N" "no-delete-corroboration" "$R4_LOG" "timestamp-out-of-window"
assert_eq "$(_ev_class "$T16C_LINE")" "suite" "T16c 回填旧 ts 的伪造记录不得使探针变绿（S-16③ 硬断言：非 external）"
assert_eq "$(_ev_dirmtime "$T16C_LINE")" "$T16C_ANCHOR" "T16c 失败行 dir_mtime == 实测锚（锚有值、依据缺席）"
assert_eq "$(_wa_sum "$R_SO" suite)" "2" "T16c suite==2（探针 + 伪造追加自身；追加自身被判红）"
assert_eq "$(_wa_sum "$R_SO" external)" "0" "T16c external==0（无任何在窗合规记录）"
T16C_BEFORE_SIZE="$(_snap_size "$SNAP_B" "$R4_LOG")"
T16C_FAKE_OFF="$(_log_first_off "$SYN_ROOT/$R4_LOG" "$T16C_FAKE_TS")"
assert_ne "$T16C_FAKE_TS" "$R4_OWN_TS" "T16c 前置自证：伪造记录 ts 与所有权记录 ts 不撞车（防字节区自证命题错位）"
assert_ne "$T16C_FAKE_OFF" "" "T16c 前置自证：伪造记录确已写入日志（非空转）"
if [ -n "$T16C_FAKE_OFF" ] && [ -n "$T16C_BEFORE_SIZE" ] && [ "$T16C_FAKE_OFF" -ge "$T16C_BEFORE_SIZE" ]; then T16C_POST=1; else T16C_POST=0; fi
assert_eq "$T16C_POST" "1" "T16c 伪造记录位于窗口后字节区（偏移 ${T16C_FAKE_OFF} ≥ before_size ${T16C_BEFORE_SIZE}）⇒ 按定义不构成所有权"
assert_eq "$(_ev_field "$T16C_LINE" act)" "none" "T16c 失败行 act=none（无在窗记录 ⇒ 活跃亦不成立）"

# ③b 本窗伪造具名记录（**当前**时间戳、合规形态）：记录在窗 ⇒ 活跃成立；但与锚相距 ≥ 31s（构造间隔）
#     ⇒ 近邻不成立 ⇒ 判红只能来自 D-α 的字节区判据（记录在窗口后字节区 ⇒ 不构成所有权）
_r4_before t16d "$R4_STEM_A" "$R4_PROBE_N"
T16D_FAKE_TS="$("$PIN_DATE" '+%Y-%m-%d %H:%M:%S')"
printf '[%s] notify: digest 卡已建 t_forge-d（snapshot=%s/%s，idem=rq-forge）\n' \
  "$T16D_FAKE_TS" "$R4_DIR" "$R4_PROBE_N" >> "$SYN_ROOT/$R4_LOG"
sleep 33
_r4_rm "$R4_PROBE_N"
_r4_anchor_now
T16D_ANCHOR="$R4_ANCHOR"
_r4_classify t16d
T16D_LINE="$(_line_for_path "$R_OUT" "$R4_PROBE_N")"
_case_asserts "T16d" "0" "$R4_PROBE_N" "no-delete-corroboration" "$R4_LOG" "registered-append-ok"
assert_eq "$(_ev_class "$T16D_LINE")" "suite" "T16d 本窗伪造具名记录（当前 ts）不得使探针变绿（S-16③ 硬断言：非 external）"
assert_eq "$(_ev_dirmtime "$T16D_LINE")" "$T16D_ANCHOR" "T16d 失败行 dir_mtime == 实测锚（锚有值、依据缺席）"
assert_eq "$(_wa_sum "$R_SO" suite)" "1" "T16d suite==1（仅探针；伪造追加自身合规且在窗 ⇒ 归 external）"
assert_eq "$(_wa_sum "$R_SO" external)" "1" "T16d external==1（= 伪造追加自身 registered-append-ok；删除面未被冒领）"
T16D_DT="$(_ev_field "$T16D_LINE" Δt)"; T16D_DT="${T16D_DT%s}"
case "$T16D_DT" in
  ''|*[!0-9]*) T16D_DT_OK=0 ;;
  *) if [ "$T16D_DT" -ge 31 ]; then T16D_DT_OK=1; else T16D_DT_OK=0; fi ;;
esac
assert_eq "$T16D_DT_OK" "1" "T16d 失败行 Δt=${T16D_DT}s ≥ 31（近邻不成立的自证；V1 检测器）"
T16D_BEFORE_SIZE="$(_snap_size "$SNAP_B" "$R4_LOG")"
assert_ne "$T16D_FAKE_TS" "$R4_OWN_TS" "T16d 前置自证：伪造记录 ts 与所有权记录 ts 不撞车（防字节区自证命题错位）"
T16D_FAKE_OFF="$(_log_first_off "$SYN_ROOT/$R4_LOG" "$T16D_FAKE_TS")"
if [ -n "$T16D_FAKE_OFF" ] && [ -n "$T16D_BEFORE_SIZE" ] && [ "$T16D_FAKE_OFF" -ge "$T16D_BEFORE_SIZE" ]; then T16D_POST=1; else T16D_POST=0; fi
assert_eq "$T16D_POST" "1" "T16d 前置自证：伪造记录位于窗口后字节区（偏移 ${T16D_FAKE_OFF} ≥ before_size ${T16D_BEFORE_SIZE}）"
T16D_ACT="$(_ev_field "$T16D_LINE" act)"
assert_ne "$T16D_ACT" "" "T16d 失败行带 act= 审计字段（R4 契约：字段只增）"
assert_ne "$T16D_ACT" "none" "T16d 失败行 act= 为实际在窗时刻（活跃成立但所有权不成立 ⇒ 判红）"

# =============================================================================
t_case "M1 mutation 抗性：库副本注入「一律 external」→ 同一形态结果必与正确版不同"
MUT_LIB="$WA_SB/mut-lib.sh"
cp "$ENGINE_LIB" "$MUT_LIB"
sed 's/suite/external/g' "$ENGINE_LIB" > "$MUT_LIB"

# 先造 S2 形态（字母表外追加）的 before/after 快照，供两版引擎共用同一输入
_syn_before m1
printf 'WA-ALPHABET-OUT-OF-SET line\n' >> "$SYN_ROOT/contrib-data/logs/app.log"
_wa_call wa_snapshot "$SYN_ROOT" "$SNAP_A" > /dev/null 2>&1

M1_C_SO="$WA_SB/m1.correct.out"; M1_C_OUT="$WA_SB/m1.correct.wa"
_wa_call wa_classify "$SYN_ROOT" "$SNAP_B" "$SNAP_A" "$SYN_REG" "$M1_C_OUT" "$W0" "$W1" > "$M1_C_SO" 2>&1
M1_C_RC=$?
M1_M_SO="$WA_SB/m1.mut.out"; M1_M_OUT="$WA_SB/m1.mut.wa"
_wa_call_lib "$MUT_LIB" wa_classify "$SYN_ROOT" "$SNAP_B" "$SNAP_A" "$SYN_REG" "$M1_M_OUT" "$W0" "$W1" > "$M1_M_SO" 2>&1
M1_M_RC=$?

M1_REP_C="$(_case_report "$M1_C_RC" "0" "$M1_C_SO" "$M1_C_OUT" "contrib-data/logs/app.log" "alphabet-violation")"
assert_eq "$M1_REP_C" "" "M1 正确版：字母表外追加 → suite(alphabet-violation)"
M1_REP_M="$(_case_report "$M1_M_RC" "0" "$M1_M_SO" "$M1_M_OUT" "contrib-data/logs/app.log" "alphabet-violation")"
if [ -n "$M1_REP_M" ]; then M1_KILLED=1; else M1_KILLED=0; fi
assert_eq "$M1_KILLED" "1" "M1 mutation「一律 external」被 kill（同一 case 检查器在注入版上转红）"
M1_DIFF="same"
if [ "$M1_C_RC" != "$M1_M_RC" ]; then M1_DIFF="diff"; fi
if [ "$(awk 'NF{n=$0} END{print n}' "$M1_C_SO")" != "$(awk 'NF{n=$0} END{print n}' "$M1_M_SO")" ]; then M1_DIFF="diff"; fi
if [ "$(awk 'NF{n=$0} END{print n}' "$M1_C_OUT")" != "$(awk 'NF{n=$0} END{print n}' "$M1_M_OUT")" ]; then M1_DIFF="diff"; fi
assert_eq "$M1_DIFF" "diff" "M1 注入后同一形态结果与正确版不同（mutation 确实生效）"

# 检查器自身抗 no-op：对**人为构造的错误输出**必须转红（防「检查器恒绿」）
printf 'WA total=1 external=1 suite=0 outside=0 unclassified=0 diff_lines=2\n' > "$WA_SB/noop.sum"
printf 'WA-CLASS external path=contrib-data/logs/app.log reason=alphabet-violation bytes_added=9\n' > "$WA_SB/noop.cls"
NOOP_REP="$(_identity_report "$WA_SB/noop.sum" "$WA_SB/noop.cls")"
if [ -n "$NOOP_REP" ]; then NOOP_KILL=1; else NOOP_KILL=0; fi
assert_eq "$NOOP_KILL" "1" "M1 检查器自证：class/reason 失配的人造输出必须被检出（非恒绿）"

# =============================================================================
t_case "M2 mutation 抗性：库副本注入「未注册也放行」→ 面外形态结果必与正确版不同"
MUT2_LIB="$WA_SB/mut2-lib.sh"
sed 's/outside-surface/external/g' "$ENGINE_LIB" > "$MUT2_LIB"

_syn_before m2
printf 'draft-more\n' >> "$SYN_ROOT/contrib-data/scratch/draft.md"
_wa_call wa_snapshot "$SYN_ROOT" "$SNAP_A" > /dev/null 2>&1

M2_C_SO="$WA_SB/m2.correct.out"; M2_C_OUT="$WA_SB/m2.correct.wa"
_wa_call wa_classify "$SYN_ROOT" "$SNAP_B" "$SNAP_A" "$SYN_REG" "$M2_C_OUT" "$W0" "$W1" > "$M2_C_SO" 2>&1
M2_C_RC=$?
M2_M_SO="$WA_SB/m2.mut.out"; M2_M_OUT="$WA_SB/m2.mut.wa"
_wa_call_lib "$MUT2_LIB" wa_classify "$SYN_ROOT" "$SNAP_B" "$SNAP_A" "$SYN_REG" "$M2_M_OUT" "$W0" "$W1" > "$M2_M_SO" 2>&1
M2_M_RC=$?

M2_REP_C="$(_case_report "$M2_C_RC" "0" "$M2_C_SO" "$M2_C_OUT" "contrib-data/scratch/draft.md" "outside-surface")"
assert_eq "$M2_REP_C" "" "M2 正确版：面外路径 → outside-surface"
M2_REP_M="$(_case_report "$M2_M_RC" "0" "$M2_M_SO" "$M2_M_OUT" "contrib-data/scratch/draft.md" "outside-surface")"
if [ -n "$M2_REP_M" ]; then M2_KILLED=1; else M2_KILLED=0; fi
assert_eq "$M2_KILLED" "1" "M2 mutation「未注册也放行」被 kill（同一 case 检查器在注入版上转红）"
M2_DIFF="same"
if [ "$M2_C_RC" != "$M2_M_RC" ]; then M2_DIFF="diff"; fi
if [ "$(awk 'NF{n=$0} END{print n}' "$M2_C_SO")" != "$(awk 'NF{n=$0} END{print n}' "$M2_M_SO")" ]; then M2_DIFF="diff"; fi
if [ "$(awk 'NF{n=$0} END{print n}' "$M2_C_OUT")" != "$(awk 'NF{n=$0} END{print n}' "$M2_M_OUT")" ]; then M2_DIFF="diff"; fi
assert_eq "$M2_DIFF" "diff" "M2 注入后同一形态结果与正确版不同（mutation 确实生效）"

# =============================================================================
# 影子端到端：lane 内自建影子 contrib-data（生产同构 fixture），真跑 s4 三注入模式
# =============================================================================
E2E_OK=0
t_case "E0 影子前置：lane 内不得预置 contrib-data（本套件禁写生产 contrib-data）"
if [ -e "$SHADOW" ]; then
  _fail "E2E 影子前置" "$SHADOW 已存在 —— 拒绝在其上做注入式实跑（可能为生产数据；本套件禁写生产 contrib-data）"
else
  E2E_OK=1
  _pass "E2E 影子前置：${SHADOW} 不存在，可由本套件建立影子树"
fi

if [ "$E2E_OK" = "1" ]; then
  mkdir -p "$SHADOW/logs" "$SHADOW/pending" "$SHADOW/runs"
  SHADOW_CREATED=1
fi

_seed_shadow() { # 幂等重建影子树（生产同构 fixture）
  local now i ts
  mkdir -p "$SHADOW/logs" "$SHADOW/pending" "$SHADOW/runs"
  now="$("$PIN_DATE" +%s)"
  : > "$SHADOW/logs/approval-collect.log"
  i=40
  while [ "$i" -ge 1 ]; do
    ts="$("$PIN_DATE" -r "$((now - i * 90))" '+%Y-%m-%d %H:%M:%S')"
    printf '[%s] approval-collect: rq-20260913-109787: 无提交（no_submission 待决态），继续等待\n' "$ts" >> "$SHADOW/logs/approval-collect.log"
    i=$((i - 1))
  done
  printf '[%s] notify: shadow-fixture\n' "$("$PIN_DATE" '+%Y-%m-%d %H:%M:%S')" > "$SHADOW/logs/notify.log"
  printf '{"state":"shadow"}\n' > "$SHADOW/notify-state.json"
  printf '{"version":1,"items":[]}\n' > "$SHADOW/ready-queue.json"
  printf '{"limits":{"week":3,"day":1},"days":{},"weeks":{},"probes":{}}\n' > "$SHADOW/budget.json"
  : > "$SHADOW/events.jsonl"
}
_shadow_files() { ( cd "$REPO_ROOT" && find contrib-data -type f 2>/dev/null | LC_ALL=C sort ); }

_s4_busy() { # 并发 s4 探测：**命令位**匹配（避免命中他卡 claude -p 提示词文本里的同名串；
  # 相对路径调用 / 跨 checkout 调用一律命中——/tmp/autopilot-artifacts 是跨 checkout 共享的）
  "$PIN_PGREP" -f '[b]ash[[:space:]].*s4-production-zero-touch\.acceptance\.sh' >/dev/null 2>&1
}
_wait_quiet() { # <secs> → 0=静默；1=仍忙
  local max="$1" waited=0
  while [ "$waited" -lt "$max" ]; do
    _s4_busy || return 0
    sleep 5
    waited=$((waited + 5))
  done
  _s4_busy && return 1
  return 0
}

_run_timeout() { # <secs> <outfile> <cmd...> → 124=超时
  local secs="$1" out="$2" waited=0 pid rc
  shift 2
  "$@" > "$out" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$secs" ]; then
      kill -TERM "$pid" 2>/dev/null
      sleep 2
      kill -KILL "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 124
    fi
    sleep 2
    waited=$((waited + 2))
  done
  wait "$pid"
  rc=$?
  return "$rc"
}

_e2e_case() { # <mode> → 设 E_RC / E_EV / E_BEFORE / E_AFTER
  local mode="$1"
  local ev="$WA_SB/e2e.$mode.ev"
  local before after
  _seed_shadow
  before="$(_shadow_files)"
  mkdir -p "$ART"
  : > "$ART/s4-p1.out"
  _run_timeout 900 "$WA_SB/e2e.$mode.out" env MARTIN_DIR="$REPO_ROOT" S4_P1_INJECT="$mode" bash "$S4"
  E_RC=$?
  after="$(_shadow_files)"
  {
    printf '%s\n' "=== stdout/stderr ==="
    awk '{print}' "$WA_SB/e2e.$mode.out"
    printf '%s\n' "=== artifact $ART/s4-p1.out ==="
    [ -f "$ART/s4-p1.out" ] && awk '{print}' "$ART/s4-p1.out"
  } > "$ev"
  E_EV="$ev"
  E_BEFORE="$before"
  E_AFTER="$after"
}

t_case "E1 影子实跑 canary-create：套件在判据面新建无佐证文件 → 4.P1 必判红 + 零残留"
if [ "$E2E_OK" = "1" ]; then
  if ! _wait_quiet 300; then
    _fail "E1 并发前置" "检测到并发 s4 进程；共享 artifact 根 ${ART} 禁并发"
  else
    _e2e_case canary-create
    assert_ne "$E_RC" "0" "E1 canary-create 进程退出码 ≠ 0（判据必须红）"
    assert_ne "$(awk '/ACCEPTANCE-FAIL/{n=1} END{print n+0}' "$E_EV")" "0" \
      "E1 输出含 ACCEPTANCE-FAIL（金丝雀注入被判红）"
    assert_ne "$(awk '/WA-CLASS suite /{n++} END{print n+0}' "$E_EV")" "0" \
      "E1 存在 WA-CLASS suite 分类行（套件写入被指认）"
    assert_ne "$(awk '/WA-CLASS (suite|external|outside|outside-surface) /{n=1} END{print n+0}' "$E_EV")" "0" \
      "E1 分类行形态可解析（WA-CLASS <class> …）"
    assert_ne "$(awk '/no-corroboration|created-unallowed|canary-marker/{n=1} END{print n+0}' "$E_EV")" "0" \
      "E1 判红 reason ∈ {canary-marker, created-unallowed, no-corroboration}"
    assert_eq "$E_AFTER" "$E_BEFORE" "E1 canary 注入物零残留（运行后影子文件集与运行前一致）"
    assert_ne "$(awk '/WA-INJECT/{n=1} END{print n+0}' "$E_EV")" "0" "E1 注入落 WA-INJECT evidence 行（可追责）"
  fi
else
  _fail "E1 影子前置" "影子 contrib-data 未建立（$SHADOW 已存在，拒绝注入式实跑）"
fi

t_case "E2 影子实跑 external-append：合规追加（模拟生产写手）→ 4.P1 PASS ∧ external≥1"
if [ "$E2E_OK" = "1" ]; then
  if ! _wait_quiet 300; then
    _fail "E2 并发前置" "检测到并发 s4 进程；共享 artifact 根 ${ART} 禁并发"
  else
    _e2e_case external-append
    assert_ne "$(awk '/PASS 4\.P1/{n=1} END{print n+0}' "$E_EV")" "0" "E2 4.P1 PASS（外部写入不误红）"
    E2_EXT="$(awk '/WA total=/{ for (i=1;i<=NF;i++) { if (index($i,"external=") == 1) v=substr($i,10) } } END{ print v }' "$E_EV")"
    E2_EXT="${E2_EXT:-0}"
    if [ "$E2_EXT" -ge 1 ]; then E2_EXT_OK=1; else E2_EXT_OK=0; fi
    assert_eq "$E2_EXT_OK" "1" "E2 external 计数 ≥ 1（实得 ${E2_EXT}）"
    assert_ne "$(awk '/WA-CLASS external .*registered-append-ok/{n=1} END{print n+0}' "$E_EV")" "0" \
      "E2 external 分类行 reason=registered-append-ok"
    E2_SUI="$(awk '/WA total=/{ for (i=1;i<=NF;i++) { if (index($i,"suite=") == 1) v=substr($i,7) } } END{ print v }' "$E_EV")"
    E2_SUI="${E2_SUI:-1}"
    assert_eq "$E2_SUI" "0" "E2 套件写入数 suite=0（4.P1 核心断言口径）"
    E2_UNCL="$(awk '/WA total=/{ for (i=1;i<=NF;i++) { if (index($i,"unclassified=") == 1) v=substr($i,14) } } END{ print v }' "$E_EV")"
    E2_UNCL="${E2_UNCL:-1}"
    assert_eq "$E2_UNCL" "0" "E2 unclassified=0（归属完整性）"
    assert_ne "$(awk '/WA total=/{n=1} END{print n+0}' "$E_EV")" "0" "E2 引擎末行计数行落盘（可 grep）"
  fi
else
  _fail "E2 影子前置" "影子 contrib-data 未建立（拒绝注入式实跑）"
fi

t_case "E3 影子实跑 canary-append：注册路径追加字母表外行 → 4.P1 必判红 ∧ 同 path 无 external 行"
if [ "$E2E_OK" = "1" ]; then
  if ! _wait_quiet 300; then
    _fail "E3 并发前置" "检测到并发 s4 进程；共享 artifact 根 ${ART} 禁并发"
  else
    _e2e_case canary-append
    assert_ne "$E_RC" "0" "E3 canary-append 进程退出码 ≠ 0（判据必须红）"
    assert_ne "$(awk '/WA-CLASS suite .*(alphabet-violation|canary-marker)/{n=1} END{print n+0}' "$E_EV")" "0" \
      "E3 存在 WA-CLASS suite reason ∈ {canary-marker, alphabet-violation}（套件写入被指认）"
    E3_SCNT="$(awk '/WA-CLASS suite /{n++} END{print n+0}' "$E_EV")"
    E3_ECNT="$(awk '/WA-CLASS external /{n++} END{print n+0}' "$E_EV")"
    if [ "$E3_SCNT" -ge 1 ] && [ "$E3_ECNT" = "0" ]; then E3_OK=1; else E3_OK=0; fi
    assert_eq "$E3_OK" "1" "E3 suite ≥ 1（实得 ${E3_SCNT}）∧ 无同窗 external 行（实得 ${E3_ECNT}；套件写入优先定性）"
  fi
else
  _fail "E3 影子前置" "影子 contrib-data 未建立（拒绝注入式实跑）"
fi

t_case "E4 影子实跑 canary-delete：套件在窗口内真删 marker 探针 ⇒ 4.P1 必红 ∧ suite≥1 ∧ reason=canary-marker ∧ 窗口差集非空 ∧ 三轮等量"
if [ "$E2E_OK" = "1" ]; then
  if ! _wait_quiet 300; then
    _fail "E4 并发前置" "检测到并发 s4 进程；共享 artifact 根 ${ART} 禁并发"
  else
    E4_LINES=""; E4_SUITES=""; E4_VERDICTS=""; E4_ROUND=1
    while [ "$E4_ROUND" -le 3 ]; do
      E4_TAG="E4 r${E4_ROUND}"
      if [ "$E4_ROUND" -gt 1 ] && ! _wait_quiet 300; then
        _fail "${E4_TAG} 并发前置" "检测到并发 s4 进程；共享 artifact 根 ${ART} 禁并发"
      fi
      _e2e_case canary-delete
      E4_RC="$E_RC"; E4_EV="$E_EV"; E4_BEFORE="$E_BEFORE"; E4_AFTER="$E_AFTER"
      assert_ne "$E4_RC" "0" "${E4_TAG} 退出码 ≠ 0（窗口内真删 ⇒ 4.P1 必判红）"
      assert_ne "$(awk '/ACCEPTANCE-FAIL/{n=1} END{print n+0}' "$E4_EV")" "0" \
        "${E4_TAG} 输出含 ACCEPTANCE-FAIL（套件删除被判红）"
      assert_ne "$(awk '/WA-CLASS suite /{n++} END{print n+0}' "$E4_EV")" "0" \
        "${E4_TAG} 存在 WA-CLASS suite 分类行"
      assert_ne "$(awk '/WA-CLASS suite .*reason=canary-marker([[:space:]]|$)/{n=1} END{print n+0}' "$E4_EV")" "0" \
        "${E4_TAG} suite 行 reason=canary-marker（删除类路径短路口径）"
      assert_ne "$(awk '/WA-INJECT mode=delete-plant/{n=1} END{print n+0}' "$E4_EV")" "0" \
        "${E4_TAG} 两段式注入 plant 段落 WA-INJECT 行（契约 stdout，可追责）"
      assert_ne "$(awk '/WA-INJECT mode=delete-fire/{n=1} END{print n+0}' "$E4_EV")" "0" \
        "${E4_TAG} 两段式注入 fire 段落 WA-INJECT 行（窗口内删除事件）"
      E4_TOT="$(_ev_sum "$E4_EV" total)"; E4_TOT="${E4_TOT:-0}"
      E4_DL="$(_ev_sum "$E4_EV" diff_lines)"; E4_DL="${E4_DL:-0}"
      assert_ne "$E4_TOT" "0" "${E4_TAG} 窗口差集非空（total=${E4_TOT}；S-04 冻结口径）"
      assert_ne "$E4_DL" "0" "${E4_TAG} 冻结口径 diff_lines 非空（diff_lines=${E4_DL}）"
      assert_eq "$E4_AFTER" "$E4_BEFORE" "${E4_TAG} canary 注入物零残留（运行后影子文件集与运行前一致）"
      E4_LINES="$E4_LINES $(awk '/WA-CLASS /{c++} END{print c+0}' "$E4_EV")"
      E4_SUITES="$E4_SUITES $(awk '/WA-CLASS suite /{c++} END{print c+0}' "$E4_EV")"
      if [ "$E4_RC" = "0" ]; then E4_VERDICTS="${E4_VERDICTS}${E4_VERDICTS:+ }GREEN"; else E4_VERDICTS="${E4_VERDICTS}${E4_VERDICTS:+ }RED"; fi
      E4_ROUND=$((E4_ROUND + 1))
    done
    assert_eq "$E4_VERDICTS" "RED RED RED" "E4 三轮结论一致（均判红；S-13）"
    E4_L1="$(printf '%s' "$E4_LINES" | awk '{print $1}')"
    E4_L2="$(printf '%s' "$E4_LINES" | awk '{print $2}')"
    E4_L3="$(printf '%s' "$E4_LINES" | awk '{print $3}')"
    E4_S1="$(printf '%s' "$E4_SUITES" | awk '{print $1}')"
    E4_S2="$(printf '%s' "$E4_SUITES" | awk '{print $2}')"
    E4_S3="$(printf '%s' "$E4_SUITES" | awk '{print $3}')"
    assert_ne "$E4_L1" "0" "E4 证据行数非零（防「三轮皆 0 行」的空转等值）"
    assert_eq "$E4_L2" "$E4_L1" "E4 三轮证据行数相等（r2=${E4_L2} == r1=${E4_L1}；杀证据 append 漂移）"
    assert_eq "$E4_L3" "$E4_L1" "E4 三轮证据行数相等（r3=${E4_L3} == r1=${E4_L1}）"
    assert_eq "$E4_S2" "$E4_S1" "E4 三轮 suite 计数相等（r2=${E4_S2} == r1=${E4_S1}）"
    assert_eq "$E4_S3" "$E4_S1" "E4 三轮 suite 计数相等（r3=${E4_S3} == r1=${E4_S1}）"
    assert_ne "$E4_S1" "0" "E4 每轮 suite ≥ 1（实得 ${E4_S1}）"
  fi
else
  _fail "E4 影子前置" "影子 contrib-data 未建立（$SHADOW 已存在，拒绝注入式实跑）"
fi

t_case "E5 影子实跑 external-delete：登记写手删除其所辖文件 ⇒ 4.P1 PASS ∧ external≥1 ∧ reason=corroborated-delete-ok"
if [ "$E2E_OK" = "1" ]; then
  if ! _wait_quiet 300; then
    _fail "E5 并发前置" "检测到并发 s4 进程；共享 artifact 根 ${ART} 禁并发"
  else
    _e2e_case external-delete
    E5_EV="$E_EV"
    assert_ne "$(awk '/PASS 4\.P1/{n=1} END{print n+0}' "$E5_EV")" "0" "E5 4.P1 PASS（登记写手的删除不误红）"
    E5_EXT="$(_ev_sum "$E5_EV" external)"; E5_EXT="${E5_EXT:-0}"
    assert_ne "$E5_EXT" "0" "E5 external ≥ 1（实得 ${E5_EXT}）"
    assert_ne "$(awk '/WA-CLASS external .*reason=corroborated-delete-ok([[:space:]]|$)/{n=1} END{print n+0}' "$E5_EV")" "0" \
      "E5 落 reason=corroborated-delete-ok 行（删除类正例证据可 grep）"
    E5_SUI="$(_ev_sum "$E5_EV" suite)"; E5_SUI="${E5_SUI:-1}"
    assert_eq "$E5_SUI" "0" "E5 suite=0（4.P1 核心断言口径）"
    E5_UNC="$(_ev_sum "$E5_EV" unclassified)"; E5_UNC="${E5_UNC:-1}"
    assert_eq "$E5_UNC" "0" "E5 unclassified=0（归属完整性）"
    assert_ne "$(_ev_sum "$E5_EV" total)" "" "E5 引擎末行计数行落盘（可 grep）"
    assert_ne "$(awk '/WA-INJECT mode=delete-fire/{n=1} END{print n+0}' "$E5_EV")" "0" \
      "E5 注入落 WA-INJECT mode=delete-fire 行（窗口内删除事件可追责）"
    assert_eq "$E_AFTER" "$E_BEFORE" "E5 注入物零残留（运行后影子文件集与运行前一致）"
  fi
else
  _fail "E5 影子前置" "影子 contrib-data 未建立（拒绝注入式实跑）"
fi

if [ "$SHADOW_CREATED" = "1" ]; then
  rm -rf "$SHADOW"
  SHADOW_CREATED=0
fi

t_case "E6 影子树零残留：实跑结束不得在仓内留下影子 contrib-data"
if [ -e "$SHADOW" ]; then
  _fail "E6 影子树已清理" "${SHADOW} 仍存在（本套件退出后必须零仓内残留）"
else
  _pass "E6 影子树已清理（${SHADOW} 不存在）"
fi

# =============================================================================
# 守卫不回归（黑盒：grep 命令位；口径与 diff-pin-canary C5/C7 一致）
# =============================================================================
NAKED_RE='(^|[;&|(]|[$][(])[[:space:]]*diff([[:space:]]|[;&|)<]|$)'
PIN_RE='(^|[;&|(]|[$][(])[[:space:]]*/usr/bin/diff([[:space:]]|[;&|)<]|$)'

t_case "G1 守卫不回归：s4 命令位 pin==2 / t1-04==1 / 裸 diff==0 / 各恰 1 行 -x /usr/bin/diff"
_g_scan() { # <file> <tag> <expect-pin>
  local f="$1" tag="$2" exp="$3" n p g
  if [ ! -f "$f" ]; then
    _fail "$tag 被测文件存在" "缺失: $f"
    return 0
  fi
  n="$(awk -v re="$NAKED_RE" '$0 ~ re {c++} END{print c+0}' "$f")"
  p="$(awk -v re="$PIN_RE" '$0 ~ re {c++} END{print c+0}' "$f")"
  g="$(awk '/-x[[:space:]]+\/usr\/bin\/diff/{c++} END{print c+0}' "$f")"
  assert_eq "$n" "0" "$tag 命令位裸 diff 调用数=0"
  assert_eq "$p" "$exp" "$tag 命令位 /usr/bin/diff 调用点数=${exp}"
  assert_eq "$g" "1" "$tag 恰 1 行 \`-x /usr/bin/diff\` fail-closed 前置"
}
_g_scan "$S4" "G1 ② s4" "2"
_g_scan "$T104" "G1 ② t1-04" "1"

t_case "G2 守卫套件 diff-pin-canary 整体仍 rc=0（含 hkstock t2_guard 回归）"
if [ -f "$CANARY" ]; then
  _run_timeout 600 "$WA_SB/g2.canary.out" bash "$CANARY"
  G2_RC=$?
  assert_eq "$G2_RC" "0" "G2 diff-pin-canary.acceptance.test.sh rc=0"
  assert_ne "$(awk '/##SUMMARY|FAIL /{n=1} END{print n+0}' "$WA_SB/g2.canary.out")" "0" \
    "G2 守卫套件有实际输出（非同构空跑）"
else
  _fail "G2 守卫套件存在" "缺失: $CANARY"
fi

t_case "G3 归属引擎零仓内写入：s4/t1-04 的 4.P1/4.1 段无 skip / 无 \`|| true\` 宽容"
# 段界锚（黑盒；冻结 driver 的既有段标与 `P=` 标签）
_sec_extract() { # <src> <start-re> <end-re> <outfile> → 0=成功
  awk -v s="$2" -v e="$3" '
    !inb { if ($0 ~ s) inb=1; else next }
    inb { print; n++; if (n > 1 && $0 ~ e) { found=1; exit } }
    END { if (found != 1) exit 1 }' "$1" > "$4"
}

S4_SEC="$WA_SB/s4.sec.txt"
T104_SEC="$WA_SB/t104.sec.txt"
_sec_extract "$S4" '(^P="4\.P1")|(4\.P1 \[det-machine\])' '(^P="4\.P2")|(4\.P2 \[det-machine\])' "$S4_SEC"
S4_SEC_RC=$?
_sec_extract "$T104" '(^t_case "4\.1)|(^#[[:space:]]*4\.1 )' '(^t_case "4\.2)|(^#[[:space:]]*4\.2 )' "$T104_SEC"
T104_SEC_RC=$?
assert_eq "$S4_SEC_RC" "0" "G3 s4 4.P1 段界可提取（段标 P=\"4.P1\"/\"4.P2\" 或 4.P1/4.P2 [det-machine] 注释）"
assert_eq "$T104_SEC_RC" "0" "G3 t1-04 4.1 段界可提取（段标 t_case \"4.1\"/\"4.2\"）"
S4_BAD="$(awk '/t_skip|_skip[ ]|\|\|[[:space:]]*true/{c++} END{print c+0}' "$S4_SEC")"
T104_BAD="$(awk '/t_skip|_skip[ ]|\|\|[[:space:]]*true/{c++} END{print c+0}' "$T104_SEC")"
assert_eq "$S4_BAD" "0" "G3 s4 4.P1 段无 skip / 无 || true"
assert_eq "$T104_BAD" "0" "G3 t1-04 4.1 段无 skip / 无 || true"

# =============================================================================
# 断言条数防删锚（新版 ≥ 改造前冻结基线；黑盒文本计数，不通读实现）
# =============================================================================
# 断言行计数规则：段内匹配 `eq|ne|ge|assert_eq|assert_ne|assert_ge|assert_exit|
# assert_contains|assert_true|_fail|fail|die` 的**标识符 token** 逐次计数。
_count_asserts() { # <file> → 计数
  awk '{
      n=split($0, a, /[^A-Za-z_]/)
      for (i=1;i<=n;i++) {
        if (a[i] == "eq" || a[i] == "ne" || a[i] == "ge" || a[i] == "assert_eq" || a[i] == "assert_ne" || a[i] == "assert_ge" || a[i] == "assert_exit" || a[i] == "assert_contains" || a[i] == "assert_true" || a[i] == "_fail" || a[i] == "fail" || a[i] == "die") c++
      }
    }
    END { print c+0 }' "$1"
}

t_case "N0 计数器自证：合成语料计数精确（防 no-op 计数器恒绿）"
printf 'eq a b\neq c d\ndie "x"\n[ -f y ] || _fail t "m"\nassert_eq 1 1\nNE x y\neq_x y z\nassert_eq_extra 1 2\n' > "$WA_SB/count.corpus"
# 命中：eq, eq, die, _fail, assert_eq ⇒ 5；NE（大写≠ne）/ eq_x / assert_eq_extra 均不得命中
assert_eq "$(_count_asserts "$WA_SB/count.corpus")" "5" \
  "N0 计数器对合成语料取 5（token 级精确；NE / eq_x / assert_eq_extra 不得命中）"

t_case "N1 s4 4.P1 段断言行数 ≥ 改造前基线（冻结常量 + 冻结文本自证）"
S4_NOW="$(_count_asserts "$S4_SEC")"
if git -C "$REPO_ROOT" cat-file -e "$FROZEN_SHA^{commit}" 2>/dev/null; then
  git -C "$REPO_ROOT" show "$FROZEN_SHA:$S4_REL" > "$WA_SB/s4.frozen.txt" 2>/dev/null
  _sec_extract "$WA_SB/s4.frozen.txt" '(^P="4\.P1")|(4\.P1 \[det-machine\])' '(^P="4\.P2")|(4\.P2 \[det-machine\])' "$WA_SB/s4.frozen.sec"
  FROZEN_S4_N="$(_count_asserts "$WA_SB/s4.frozen.sec")"
  assert_eq "$FROZEN_S4_N" "$BASE_S4_P1_ASSERTS" "N1 冻结文本自证：旧版 4.P1 段行数 == 基线 ${BASE_S4_P1_ASSERTS}（计数器口径有效）"
else
  _fail "N1 冻结文本可取" "git show ${FROZEN_SHA}:${S4_REL} 不可用（基线无法自证，拒静默降级）"
fi
if [ "$S4_NOW" -ge "$BASE_S4_P1_ASSERTS" ]; then S4_ANCHOR=1; else S4_ANCHOR=0; fi
assert_eq "$S4_ANCHOR" "1" "N1 新版 s4 4.P1 段断言行数 ${S4_NOW} ≥ 基线 ${BASE_S4_P1_ASSERTS}"

t_case "N2 t1-04 4.1 段断言行数 ≥ 改造前基线（冻结常量 + 冻结文本自证）"
T104_NOW="$(_count_asserts "$T104_SEC")"
if git -C "$REPO_ROOT" cat-file -e "$FROZEN_SHA^{commit}" 2>/dev/null; then
  git -C "$REPO_ROOT" show "$FROZEN_SHA:$T104_REL" > "$WA_SB/t104.frozen.txt" 2>/dev/null
  _sec_extract "$WA_SB/t104.frozen.txt" '(^t_case "4\.1)|(^#[[:space:]]*4\.1 )' '(^t_case "4\.2)|(^#[[:space:]]*4\.2 )' "$WA_SB/t104.frozen.sec"
  FROZEN_T104_N="$(_count_asserts "$WA_SB/t104.frozen.sec")"
  assert_eq "$FROZEN_T104_N" "$BASE_T104_41_ASSERTS" "N2 冻结文本自证：旧版 4.1 段行数 == 基线 ${BASE_T104_41_ASSERTS}（计数器口径有效）"
else
  _fail "N2 冻结文本可取" "git show ${FROZEN_SHA}:${T104_REL} 不可用（基线无法自证，拒静默降级）"
fi
if [ "$T104_NOW" -ge "$BASE_T104_41_ASSERTS" ]; then T104_ANCHOR=1; else T104_ANCHOR=0; fi
assert_eq "$T104_ANCHOR" "1" "N2 新版 t1-04 4.1 段断言行数 ${T104_NOW} ≥ 基线 ${BASE_T104_41_ASSERTS}"

t_case "N3 本套件零 SKIP（无降级通道）"
assert_eq "$T_SKIPPED" "0" "N3 本套件 emitted SKIP == 0"

t_finish

# =============================================================================
# CONTRACT_AMBIGUOUS（契约未声明/两处不一致，按已声明形态从宽求值，不推测私有成员）：
#  1) 末行计数字段：`## 契约规约` 写作 `WA total= external= suite= unclassified= diff_lines=`
#     （无 outside=），而 `## 设计文档` 的 API 段写作含 `outside=`。本套件以 **per-file 分类行计数**
#     为 outside 的求值源（恒等式用分类行计数），末行 outside= 若存在则另作一致性断言。
#  2) outside 类别的类别 token：第 2 轮口径定为三值闭集 {suite, external, outside-surface}，
#     而分类枚举段落写作 `outside` 类。本套件对 reason=outside-surface 行接受
#     class ∈ {outside-surface, outside}（别名容忍，避免纯拼写对撞）；reason 恒须为 outside-surface。
#  3) 注入模式命名：`## 验收场景` 场景2 步骤写 `S4_P1_INJECT=canary-file`，谓词与实现计划写
#     `canary-create`。本套件按实现计划/谓词取 `canary-create`（若实现只认 canary-file，则注入为空操作，
#     本套件 E1 的分类行断言会转红并暴露该不一致）。
#  4) `canary-append` 的注入目标路径：设计仅写「往注册路径追加」，未点名具体路径。本套件不钉死路径，
#     而断言「存在 suite ∧ reason ∈ {canary-marker, alphabet-violation} ∧ 同窗无 external 行」。
#  5) `Δt=<n>s` 的落点：第 2 轮口径写「evidence 行带 Δt=<n>s」，未指明是仅成立路径还是全部
#     corroborated-* 行。黑盒实测（本套件编写期）：Δt∈{0,5,29}s ⇒ `external … corroborated-ok
#     writer=… Δt=<n>s`；Δt∈{31,120,1200}s ⇒ `suite … no-corroboration writer=…`（**无 Δt 字段**）。
#     本套件按口径字面「evidence 行带 Δt」对两态均硬断言（S8b 因此会红，直至失败路径补 Δt 字段）；
#     该缺口已如实上报，不属推测的私有成员。
#  6) `canary-marker` 与 `outside-surface` 的竞合：第 2 轮口径写「无条件 suite」，未声明面外路径上出现
#     S4-P1- 行时的优先级。本套件不就该组合求值（避免推测未声明的交互），仅覆盖判据面内两态
#     （S2b 无佐证、S2c 佐证齐备）。
#  7) 段界锚：4.P1/4.1 段落的提取依赖既有段标（`P="4.P1"`/`4.P1 [det-machine]`、`t_case "4.1"/"4.2"`）。
#     设计声明冻结 driver 逐字保留；若段标被重命名，G3/N1/N2 会显式转红（段界不可提取）而非静默放宽。
#  8) 删除类失败路径（`no-delete-corroboration`）的 EXTRA 字段值语义：`## 设计文档`「归属规则」把该分支写作
#     `EXTRA: writer=<w> Δt=<…> ts=<…> dir_mtime=<epoch>`，但「锚可取 ∧ 佐证缺席」时 `Δt`/`ts` 取何值（最近记录？
#     缺席占位？）未被钉死。本套件只对 `dir_mtime` 硬断言（S-07 明文「锚有值、佐证缺席」），未对失败路径的
#     `Δt`/`ts` 求值——与既有 ⑤ 的处置同构（不推测未声明的值语义）。
#  9) `|Δ|` 的对称性：设计写 `|记录 ts − 锚| ≤ 30s`（绝对差），而 example/边界段只给出「记录早于锚」的样例。
#     本套件按字面 |·| 对「记录晚于锚 +30s / +31s」（S16d/S16e，仍在窗口松弛 ±120s 内）同样求值；若实现只做
#     单侧比较（锚 − 记录），这两轮会红并暴露口径分歧，属如实上报而非推测。
# 10) S19 的「套件面内写入」reason 令牌：S-12 只写「套件在 `pending/` 写 marker 文件（suite）」未点名 token；
#     且该路径在 `corroborated-delete` 面上属 **新建**（C），而设计对 C/M 只写「取首个匹配行（谁在前都走同一
#     corroborated 分支）」。本套件对该行接受 reason ∈ {canary-marker, created-unallowed, no-corroboration}
#     （三者 class 同为 suite ⇒ class 仍被钉死）；若判成 corroborated-ok/external，则 S19 的 `suite==1` 等值断言
#     转红（S-12 明文要求该写入判 suite，故不是放宽而是按场景求值）。
# 11) 删除类注入行的透传：`## 契约规约` 只声明 `wa_inject` 自身的 stdout 形态（`WA-INJECT mode=delete-plant|delete-fire …`），
#     未声明 s4 是否把两行透传到自身输出。本套件沿用 E1 的既有先例（`WA-INJECT` 可在 s4 输出中转储）并对
#     plant/fire 两行分别断言；若不透传 ⇒ 红（审计链缺口）而非静默放宽。
# 12) D-α 新字段的落点：R4 契约修正为「新字段一律**追加在 `dir_mtime=` 之后**」。本套件对旧字段沿用既有
#     `_ev_ts`（`%% dir_mtime=` 截断）/ `_ev_dirmtime`（贪婪）提取器，对新字段另立 `_ev_field`（按「已知键=
#     值以下一个已知键为界」切分）——不硬编码新字段位置，故对「追加在 dir_mtime 之后」与「插在中间」两种
#     排列同判；若实现把新字段插在 `ts=` 与 `dir_mtime=` 之间，既有 `_ev_ts` 的 S15/S16 断言会转红并暴露。
# 13) 失败行的 `owner=<stem|none>` / `act=<ts|none>`：`## 契约规约` 只声明字段存在与「字段只增」，未钉死
#     何时取 `none`（`wa__owner_prior` 契约又称失败时 `WA_OWN_STEM` 仍置实际 stem，未说明是否落盘）。
#     本套件对**存在性**硬断言，对 `act=` 按**构造前提**断言（本窗确无/确有在窗记录），不对 `owner=` 的
#     stem/none 二值择一断言（不推测未声明的落盘口径）。
# 14) D-α 的「活跃」扫描面：契约写「同一佐证日志中存在 ts ∈ [t0−120s, t1+120s] 的合规记录」，未声明是
#     全文扫描还是仅追加块。本套件的三态构造**让两种读法同判**（活跃记录在 before 快照前/后各有覆盖；
#     ③b 的伪造记录自身即落在窗），故结论不依赖该口径分歧。
# 15) ③b 的真实时间间隔：伪造记录 ts 与「锚」（= 真 rm 时刻）必须相距 > 30s，D-β 才不成立。本套件用
#     `sleep 33` 造**真实**间隔（不给目录 touch -t 伪造锚），故 T16d 固有 ~33s 墙钟成本；`Δt ≥ 31` 断言
#     即该前提的机械自证（实现未落 Δt 字段 ⇒ 转红 = 契约缺口，不属放宽）。
# =============================================================================
